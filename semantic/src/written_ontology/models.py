from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from enum import StrEnum
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from .healthkit import (
        FitnessHabitCandidate,
        HealthKitCoverage,
        HealthKitRecord,
    )


class InferencePolicyName(StrEnum):
    INFERABLE = "inferable"
    REVIEW_REQUIRED = "review_required"
    EXPLICIT_ONLY = "explicit_only"
    PROHIBITED = "prohibited"


class MappingState(StrEnum):
    CANDIDATE = "candidate"
    ACCEPTED = "accepted"
    REJECTED = "rejected"


class CoverageState(StrEnum):
    USABLE = "usable"
    OBSERVED_EMPTY = "observed_empty"
    PERMISSION_DENIED = "permission_denied"
    NOT_CONNECTED = "not_connected"
    UNSUPPORTED = "unsupported"
    ERROR = "error"
    STALE = "stale"
    REVOKED = "revoked"


@dataclass(frozen=True, slots=True)
class Term:
    text: str
    normalized: str
    role: str
    source_field: str
    type_hint: str | None = None
    locale: str = "und"
    safe_for_online: bool = False
    safe_for_global_mining: bool = False
    # A source row can support several typed meanings with different force.
    # For example, a liked YouTube video strongly supports its content topic
    # but only weakly supports affinity to the uploader. This multiplier is a
    # ranking weight, not a calibrated probability.
    evidence_weight: float = 1.0


@dataclass(frozen=True, slots=True)
class Observation:
    id: str
    source: str
    data_type: str
    action: str
    evidence_channel: str
    independence_group: str
    occurred_at: datetime | None
    collected_at: datetime | None
    terms: tuple[Term, ...]
    record_fingerprint: str
    content_lineage: str
    session_key: str | None = None
    field_quality: float = 1.0
    action_weight: float = 1.0
    privacy_class: str = "public_catalog"
    allow_external_resolution: bool = False
    metadata: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True, slots=True)
class Concept:
    key: str
    label: str
    kind: str
    sensitivity: str
    inference_policy: InferencePolicyName
    status: str = "active"
    definition: str | None = None


@dataclass(frozen=True, slots=True)
class ConceptEdge:
    subject_key: str
    predicate_key: str
    object_key: str
    confidence: float
    provenance_type: str
    status: str = "active"


@dataclass(frozen=True, slots=True)
class MappingCandidate:
    observation_id: str
    term: Term
    concept_key: str
    confidence: float
    method: str
    state: MappingState
    rank: int = 1
    score_margin: float | None = None
    evidence_path: tuple[dict[str, Any], ...] = ()


@dataclass(frozen=True, slots=True)
class Evidence:
    observation_id: str
    concept_key: str
    source: str
    evidence_channel: str
    independence_group: str
    content_lineage: str
    mapping_confidence: float
    action_weight: float
    source_quality: float
    field_quality: float = 1.0
    recency_weight: float = 1.0
    # Temporal relevance and timestamp quality are separate. Production
    # mapper output pins these to an auditable policy/rule; defaults preserve
    # compatibility for already-materialized or test evidence.
    recency_quality: float = 1.0
    recency_policy_version: str = "legacy-unversioned"
    recency_rule_id: str = "legacy.static"
    recency_status: str = "not_recorded"
    path_weight: float = 1.0
    # Some provider policies permit source-local ranking but not combination
    # with other providers. This is an authorization boundary, not a weight.
    cross_source_fusion_allowed: bool = True
    evidence_path: tuple[dict[str, Any], ...] = ()

    @property
    def raw_contribution(self) -> float:
        value = (
            self.mapping_confidence
            * self.action_weight
            * self.source_quality
            * self.field_quality
            * self.recency_weight
            * self.recency_quality
            * self.path_weight
        )
        return min(1.0, max(0.0, value))


@dataclass(frozen=True, slots=True)
class SourceBreakdown:
    independence_group: str
    strength: float
    mapping_agreement: float
    evidence_quality: float
    unique_lineages: int
    evidence_count: int

    @property
    def confidence(self) -> float:
        """Compatibility alias; this value is not a calibrated probability."""
        return self.mapping_agreement


@dataclass(frozen=True, slots=True)
class ConceptScore:
    concept_key: str
    strength: float
    mapping_agreement: float
    evidence_quality: float
    breadth: int
    stability: float
    source_breakdown: tuple[SourceBreakdown, ...]
    usable_source_count: int = 0
    missing_source_count: int = 0

    @property
    def confidence(self) -> float:
        """Compatibility alias; this value is not a calibrated probability."""
        return self.mapping_agreement


@dataclass(frozen=True, slots=True)
class AssertionCandidate:
    key: str
    predicate: str
    concept_key: str
    label: str
    state: str
    score: ConceptScore
    explanation_paths: tuple[tuple[dict[str, Any], ...], ...]


@dataclass(frozen=True, slots=True)
class ExternalCandidate:
    provider: str
    external_id: str
    label: str
    description: str | None
    entity_kind: str | None
    aliases: tuple[str, ...]
    proposed_edges: tuple[dict[str, Any], ...]
    retrieval_score: float
    provenance: dict[str, Any]

    @property
    def confidence(self) -> float:
        """Compatibility alias; retrieval rank is not calibrated confidence."""
        return self.retrieval_score


@dataclass(frozen=True, slots=True)
class AdapterResult:
    observations: tuple[Observation, ...]
    raw_retained_counts: dict[str, int]
    excluded_counts: dict[str, int]
    routed_profile_counts: dict[str, int]
    routed_location_counts: dict[str, int]
    routed_connection_counts: dict[str, int]
    policy_quarantined_counts: dict[str, int]
    input_counts: dict[str, int]
    fitness_records: tuple[HealthKitRecord, ...] = ()
    fitness_coverage: HealthKitCoverage | None = None
    fitness_habit_candidates: tuple[FitnessHabitCandidate, ...] = ()
