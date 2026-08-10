from __future__ import annotations

from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path

from .feedback import FeedbackAction, FeedbackEvent, FeedbackLearner
from .graph import OntologyGraph
from .mapping import ObservationMapper
from .models import Observation, Term
from .normalize import normalize_text, stable_hash
from .scoring import ConvergenceEngine, FusionEngine
from .safety import InferenceSafetyPolicy


FIXED_TIME = datetime(2026, 8, 10, tzinfo=timezone.utc)


def _observation(
    identifier: str,
    *,
    source: str,
    data_type: str,
    action: str,
    group: str,
    term: str,
    role: str,
    lineage: str,
    action_weight: float,
    privacy_class: str = "public_catalog",
    allow_external: bool = True,
) -> Observation:
    normalized = normalize_text(term)
    return Observation(
        id=identifier,
        source=source,
        data_type=data_type,
        action=action,
        evidence_channel=group,
        independence_group=group,
        occurred_at=datetime(2026, 7, 15, tzinfo=timezone.utc),
        collected_at=FIXED_TIME,
        terms=(
            Term(
                text=term,
                normalized=normalized,
                role=role,
                source_field="fixture",
                type_hint="topic",
                safe_for_online=allow_external,
                safe_for_global_mining=privacy_class == "public_catalog",
            ),
        ),
        record_fingerprint=stable_hash(identifier),
        content_lineage=lineage,
        action_weight=action_weight,
        privacy_class=privacy_class,
        allow_external_resolution=allow_external,
        metadata=(
            {
                "has_verified_catalog_id": True,
                "catalog_namespace": "synthetic_fixture",
            }
            if privacy_class == "public_catalog" and allow_external
            else {}
        ),
    )


def fixture_observations() -> tuple[Observation, ...]:
    observations: list[Observation] = []
    # Many plays of one recording are deliberately the same lineage.
    for index in range(50):
        observations.append(
            _observation(
                f"music-{index:02d}",
                source="apple_music",
                data_type="recently_played",
                action="recently_played",
                group="music",
                term="Italian music",
                role="genre_or_culture",
                lineage="recording:fixture-italian-song",
                action_weight=0.78,
            )
        )
    observations.append(
        _observation(
            "video-01",
            source="youtube",
            data_type="video",
            action="video",
            group="video",
            term="Italian cinema",
            role="provider_topic",
            lineage="film:fixture-italian-film",
            action_weight=0.75,
        )
    )
    observations.append(
        _observation(
            "calendar-01",
            source="apple_calendar",
            data_type="event",
            action="scheduled",
            group="calendar",
            term="Italian cuisine",
            role="structured_booking_category",
            lineage="booking:fixture-italian-restaurant",
            action_weight=0.60,
            privacy_class="private_text",
            allow_external=False,
        )
    )
    return tuple(observations)


def run_demo(seed_dir: str | Path | None = None) -> dict[str, object]:
    root = Path(__file__).resolve().parents[2]
    graph = OntologyGraph.from_seed_dir(seed_dir or root / "ontology")
    safety = InferenceSafetyPolicy()
    mapper = ObservationMapper(graph, safety)
    fusion = FusionEngine()
    convergence = ConvergenceEngine(graph, fusion, safety)

    evidence = []
    mapping_count = 0
    for observation in fixture_observations():
        mappings = mapper.map_observation(observation)
        mapping_count += len(mappings)
        evidence.extend(mapper.accepted_evidence(observation, mappings, as_of=FIXED_TIME))

    repeated_music_score = fusion.score("concept:italian_music", evidence)
    assertions = convergence.infer_shared_target_affinities(evidence)
    music_only_assertions = convergence.infer_shared_target_affinities(
        [item for item in evidence if item.independence_group == "music"]
    )

    # In production the link validator is a server-side ownership + explicit-
    # correction check. The fixture has one known synthetic observation.
    learner = FeedbackLearner(
        link_validator=lambda event: (
            tuple(identifier for identifier in event.linked_observation_ids if identifier == "video-01")
        )
    )
    assertion_key = assertions[0].key if assertions else "affinity_to::affinity:culture:italy"
    removal_effect = learner.apply(
        FeedbackEvent(
            user_id="synthetic-user",
            client_event_id="event-remove-1",
            action=FeedbackAction.SUPPRESS,
            assertion_key=assertion_key,
            rule_signature="shared_target_convergence:v0.1",
        )
    )
    addition_effect = learner.apply(
        FeedbackEvent(
            user_id="synthetic-user",
            client_event_id="event-add-1",
            action=FeedbackAction.EXPLICIT_ADD,
            assertion_key="affinity_to::concept:italian_cinema",
            rule_signature="manual_addition:v0.1",
            linked_observation_ids=("video-01",),
        )
    )
    recomputed_assertions = convergence.infer_shared_target_affinities(evidence)
    visible_after_recompute = learner.visible_assertions(
        "synthetic-user", recomputed_assertions
    )

    ancestry = graph.concepts["identity:italian_ancestry"]
    output_assertions = []
    for assertion in assertions:
        output_assertions.append(
            {
                "concept_key": assertion.concept_key,
                "label": assertion.label,
                "state": assertion.state,
                "strength": assertion.score.strength,
                "mapping_agreement": assertion.score.mapping_agreement,
                "evidence_quality": assertion.score.evidence_quality,
                "breadth": assertion.score.breadth,
                "stability": assertion.score.stability,
            }
        )

    return {
        "fixture_observations": len(fixture_observations()),
        "mapping_candidates": mapping_count,
        "accepted_evidence": len(evidence),
        "repeated_music": {
            "strength": repeated_music_score.strength,
            "breadth": repeated_music_score.breadth,
            "unique_lineages": sum(
                item.unique_lineages for item in repeated_music_score.source_breakdown
            ),
        },
        "cross_source_assertions": output_assertions,
        "music_only_cross_source_assertions": len(music_only_assertions),
        "identity_firewall": {
            "italian_ancestry_inferable": safety.concept_is_inferable(ancestry).allowed,
        },
        "one_tap_removal": {
            "suppressed_for_user": removal_effect.suppress_for_user,
            "semantic_global_negative": removal_effect.semantic_global_negative,
            "underlying_evidence_preserved": len(evidence),
            "suppression_survives_recompute": len(visible_after_recompute) == 0,
        },
        "explicit_addition": {
            "semantic_positive_observation_ids": list(
                addition_effect.semantic_positive_observation_ids
            ),
            "semantic_global_negative": addition_effect.semantic_global_negative,
        },
    }
