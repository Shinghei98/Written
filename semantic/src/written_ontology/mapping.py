from __future__ import annotations

import math
import re
from collections.abc import Iterable
from datetime import datetime

from .graph import OntologyGraph
from .healthkit import HEALTHKIT_POLICY_VERSION
from .models import ExternalCandidate, Evidence, MappingCandidate, MappingState, Observation, Term
from .normalize import normalize_text
from .providers.base import KnowledgeProvider, external_candidate_is_type_compatible
from .recency import (
    DEFAULT_RECENCY_POLICY,
    RecencyPolicy,
    RecencyPolicyError,
    TemporalStatus,
)
from .safety import InferenceSafetyPolicy
from .source_policy import (
    DEFAULT_SOURCE_QUALITY,
    SOURCE_ACTION_PAIRS,
    SOURCE_LAYOUT,
)

TRUSTED_ACCEPTED_MAPPING_METHODS = {"curated_alias"}


class ObservationMapper:
    def __init__(
        self,
        graph: OntologyGraph,
        safety: InferenceSafetyPolicy | None = None,
        providers: Iterable[KnowledgeProvider] | None = None,
        recency_policy: RecencyPolicy | None = None,
    ) -> None:
        self.graph = graph
        self.safety = safety or InferenceSafetyPolicy()
        self.providers = tuple(providers or ())
        self.recency_policy = recency_policy or DEFAULT_RECENCY_POLICY
        if not isinstance(self.recency_policy, RecencyPolicy):
            raise TypeError("recency_policy must be a RecencyPolicy")

    @staticmethod
    def _term_is_valid(term: Term) -> bool:
        if not all(
            isinstance(value, str)
            for value in (
                term.text,
                term.normalized,
                term.role,
                term.source_field,
                term.locale,
            )
        ):
            return False
        if (
            not term.text.strip()
            or len(term.text) > 512
            or not term.normalized
            or len(term.normalized) > 512
            or term.normalized != normalize_text(term.text)
        ):
            return False
        if (
            not isinstance(term.evidence_weight, (int, float))
            or isinstance(term.evidence_weight, bool)
            or not math.isfinite(term.evidence_weight)
            or not 0.0 <= term.evidence_weight <= 1.0
        ):
            return False
        return term.type_hint is None or (
            isinstance(term.type_hint, str) and bool(term.type_hint.strip())
        )

    @staticmethod
    def _source_projection_is_valid(observation: Observation) -> bool:
        # Calendar semantics use typed travel/booking candidate tables. They
        # never enter the generic alias mapper, even when the adapter has
        # produced a sanitized observation for private persistence.
        if observation.source in {"apple_calendar", "google_calendar"}:
            return False
        if observation.source != "healthkit":
            return True

        # HealthKit is admitted only through the exact controlled projection
        # emitted from a thresholded fitness candidate. A caller cannot turn a
        # hand-built Health observation into general ontology evidence merely
        # by selecting a known alias.
        metadata = observation.metadata
        if not isinstance(metadata, dict) or len(observation.terms) != 1:
            return False
        term = observation.terms[0]
        candidate_id = metadata.get("candidate_id")
        policy_version = metadata.get("policy_version")
        expected_metadata_keys = {
            "candidate_id",
            "candidate_kind",
            "controlled_label",
            "predicate",
            "purpose_scope",
            "policy_version",
            "requires_user_review",
            "cross_source_fusion_approved",
        }
        candidate_kind = metadata.get("candidate_kind")
        expected_type_hint = "activity"
        return (
            observation.data_type == "fitness_habit"
            and observation.action == "routine"
            and observation.privacy_class == "private_fitness_sanitized"
            and observation.allow_external_resolution is False
            and math.isclose(observation.action_weight, 0.85, rel_tol=0.0, abs_tol=1e-12)
            and isinstance(candidate_id, str)
            and re.fullmatch(r"[0-9a-f]{24}", candidate_id) is not None
            and set(metadata) == expected_metadata_keys
            and policy_version == HEALTHKIT_POLICY_VERSION
            and candidate_kind
            in {"activity_routine", "workout_daypart"}
            and metadata.get("predicate") == "routine"
            and metadata.get("purpose_scope") == "fitness_connection"
            and metadata.get("requires_user_review") is True
            and metadata.get("cross_source_fusion_approved") is False
            and metadata.get("controlled_label") == term.text
            and term.role == "validated_fitness_habit"
            and term.source_field == "fitness_habit_candidate.controlled_label"
            and term.type_hint == expected_type_hint
            and term.safe_for_online is False
            and term.safe_for_global_mining is False
        )

    def map_observation(self, observation: Observation) -> tuple[MappingCandidate, ...]:
        if not isinstance(observation, Observation) or not isinstance(observation.terms, tuple):
            return ()
        if not self._source_projection_is_valid(observation):
            return ()
        candidates: list[MappingCandidate] = []
        seen: set[tuple[str, str]] = set()
        for term in observation.terms:
            if not self._term_is_valid(term):
                continue
            for rank, resolution in enumerate(self.graph.resolve_alias(term), start=1):
                dedupe_key = (term.normalized, resolution.concept_key)
                if dedupe_key in seen:
                    continue
                seen.add(dedupe_key)
                concept = self.graph.concepts[resolution.concept_key]
                if (
                    concept.status != "active"
                    or not self.safety.concept_is_inferable(concept).allowed
                ):
                    state = MappingState.REJECTED
                else:
                    state = resolution.state
                candidates.append(
                    MappingCandidate(
                        observation_id=observation.id,
                        term=term,
                        concept_key=resolution.concept_key,
                        confidence=resolution.confidence,
                        method=resolution.method,
                        state=state,
                        rank=rank,
                        score_margin=resolution.margin,
                        evidence_path=(
                            {
                                "step": "observation_term",
                                "role": term.role,
                                "source_field": term.source_field,
                            },
                            {
                                "step": "concept_mapping",
                                "method": resolution.method,
                                "concept_key": resolution.concept_key,
                                "confidence": round(resolution.confidence, 6),
                            },
                        ),
                    )
                )
            if not self.safety.term_may_leave_device_boundary(observation, term):
                continue
            for rank, external in enumerate(
                self._resolve_external(observation, term),
                start=1,
            ):
                external_key = f"external:{external.provider}:{external.external_id}"
                dedupe_key = (term.normalized, external_key)
                if dedupe_key in seen:
                    continue
                seen.add(dedupe_key)
                candidates.append(
                    MappingCandidate(
                        observation_id=observation.id,
                        term=term,
                        concept_key=external_key,
                        confidence=external.retrieval_score,
                        method="external_candidate",
                        # Online retrieval can propose a node for curation, but
                        # can never accept it as semantic evidence.
                        state=MappingState.CANDIDATE,
                        rank=rank,
                        score_margin=None,
                        evidence_path=(
                            {
                                "step": "observation_term",
                                "role": term.role,
                                "source_field": term.source_field,
                            },
                            {
                                "step": "external_candidate",
                                "provider": external.provider,
                                "external_id": external.external_id,
                                "label": external.label,
                                "entity_kind": external.entity_kind,
                                "retrieval_score": external.retrieval_score,
                                "proposed_edges": external.proposed_edges,
                                "provenance": dict(external.provenance),
                            },
                        ),
                    )
                )
        return tuple(candidates)

    def _resolve_external(
        self,
        observation: Observation,
        term: Term,
    ) -> tuple[ExternalCandidate, ...]:
        results: list[ExternalCandidate] = []
        for provider in self.providers:
            try:
                resolved = tuple(provider.resolve(observation, term))
            except Exception:  # noqa: BLE001 - fail closed at the network/provider boundary
                continue
            for candidate in resolved:
                try:
                    provider_name = provider.provider_name
                    raw_score = candidate.retrieval_score
                    score = float(raw_score)
                    valid = (
                        isinstance(raw_score, (int, float))
                        and not isinstance(raw_score, bool)
                        and candidate.provider == provider_name
                        and bool(candidate.external_id.strip())
                        and len(candidate.external_id) <= 256
                        and math.isfinite(score)
                        and 0.0 <= score <= 1.0
                        and candidate.provenance.get("provider") == candidate.provider
                        and candidate.provenance.get("external_id") == candidate.external_id
                        and bool(candidate.provenance.get("retrieved_at"))
                        and external_candidate_is_type_compatible(term, candidate)
                    )
                except (AttributeError, TypeError, ValueError):
                    valid = False
                if valid:
                    results.append(candidate)
        return tuple(
            sorted(
                results,
                key=lambda item: (-item.retrieval_score, item.provider, item.external_id),
            )
        )

    def accepted_evidence(
        self,
        observation: Observation,
        candidates: Iterable[MappingCandidate],
        *,
        as_of: datetime | None = None,
    ) -> tuple[Evidence, ...]:
        if not isinstance(observation, Observation) or not isinstance(observation.terms, tuple):
            return ()
        if not self._source_projection_is_valid(observation):
            return ()
        quality = DEFAULT_SOURCE_QUALITY.get(observation.source)
        expected_layout = SOURCE_LAYOUT.get(observation.source)
        allowed_actions = SOURCE_ACTION_PAIRS.get(observation.source, set())
        if (
            quality is None
            or expected_layout is None
            or (observation.evidence_channel, observation.independence_group)
            != expected_layout
            or (observation.data_type, observation.action) not in allowed_actions
            or not isinstance(observation.action_weight, (int, float))
            or isinstance(observation.action_weight, bool)
            or not math.isfinite(observation.action_weight)
            or not 0.0 <= observation.action_weight <= 1.0
            or not isinstance(observation.field_quality, (int, float))
            or isinstance(observation.field_quality, bool)
            or not math.isfinite(observation.field_quality)
            or not 0.0 <= observation.field_quality <= 1.0
        ):
            return ()
        # The semantic-run timestamp is part of reproducibility. Never consult
        # the process wall clock: callers that omit the pinned value fail
        # closed instead of producing a score that changes between retries.
        if as_of is None:
            return ()
        try:
            recency = self.recency_policy.evaluate(
                domain=observation.evidence_channel,
                source=observation.source,
                action=observation.action,
                occurred_at=observation.occurred_at,
                as_of=as_of,
            )
        except RecencyPolicyError:
            return ()
        if (
            observation.source == "healthkit"
            and recency.temporal_status is TemporalStatus.EXPIRED
        ):
            # Unlike ordinary historical consumption, a purpose-limited
            # current routine must be rebuilt from a qualifying live window.
            return ()
        result: list[Evidence] = []
        for candidate in candidates:
            if (
                candidate.state != MappingState.ACCEPTED
                or candidate.observation_id != observation.id
                or candidate.method not in TRUSTED_ACCEPTED_MAPPING_METHODS
                or candidate.term not in observation.terms
                or not self._term_is_valid(candidate.term)
                or not isinstance(candidate.confidence, (int, float))
                or isinstance(candidate.confidence, bool)
                or not math.isfinite(candidate.confidence)
                or not 0.0 <= candidate.confidence <= 1.0
            ):
                continue
            trusted_resolution = next(
                (
                    resolution
                    for resolution in self.graph.resolve_alias(candidate.term)
                    if resolution.concept_key == candidate.concept_key
                    and resolution.state == MappingState.ACCEPTED
                    and resolution.method == candidate.method
                    and math.isclose(
                        resolution.confidence,
                        candidate.confidence,
                        rel_tol=0.0,
                        abs_tol=1e-12,
                    )
                ),
                None,
            )
            if trusted_resolution is None:
                continue
            concept = self.graph.concepts.get(candidate.concept_key)
            if (
                concept is None
                or concept.status != "active"
                or not self.safety.concept_is_inferable(concept).allowed
                or not self.graph._type_compatible(candidate.term, concept)
            ):
                continue
            result.append(
                Evidence(
                    observation_id=observation.id,
                    concept_key=candidate.concept_key,
                    source=observation.source,
                    evidence_channel=observation.evidence_channel,
                    independence_group=observation.independence_group,
                    content_lineage=observation.content_lineage,
                    mapping_confidence=trusted_resolution.confidence,
                    action_weight=observation.action_weight * candidate.term.evidence_weight,
                    source_quality=quality,
                    field_quality=observation.field_quality,
                    recency_weight=recency.weight,
                    recency_quality=recency.timestamp_quality_weight,
                    recency_policy_version=recency.policy_version,
                    recency_rule_id=recency.rule_id,
                    recency_status=recency.temporal_status.value,
                    cross_source_fusion_allowed=(
                        observation.metadata.get(
                            "cross_source_fusion_approved", True
                        )
                        is True
                    ),
                    evidence_path=(
                        {
                            "step": "observation_term",
                            "role": candidate.term.role,
                            "source_field": candidate.term.source_field,
                            "term_evidence_weight": candidate.term.evidence_weight,
                        },
                        recency.evidence_step(),
                        {
                            "step": "concept_mapping",
                            "method": trusted_resolution.method,
                            "concept_key": trusted_resolution.concept_key,
                            "confidence": round(trusted_resolution.confidence, 6),
                        },
                    ),
                )
            )
        return tuple(result)
