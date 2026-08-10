from __future__ import annotations

import unittest
from dataclasses import replace
from datetime import datetime, timezone

from written_ontology.graph import OntologyGraph
from written_ontology.mapping import ObservationMapper
from written_ontology.models import (
    Concept,
    ConceptEdge,
    InferencePolicyName,
    MappingCandidate,
    MappingState,
    Observation,
    Term,
)


NOW = datetime(2026, 8, 10, tzinfo=timezone.utc)


def concept(
    key: str,
    *,
    kind: str = "topic",
    status: str = "active",
    policy: InferencePolicyName = InferencePolicyName.INFERABLE,
    sensitivity: str = "ordinary",
) -> Concept:
    return Concept(
        key=key,
        label=key,
        kind=kind,
        sensitivity=sensitivity,
        inference_policy=policy,
        status=status,
    )


def term(text: str, *, type_hint: str | None = "topic") -> Term:
    return Term(
        text=text,
        normalized=text.casefold(),
        role="fixture",
        source_field="fixture",
        type_hint=type_hint,
    )


def observation(
    *terms: Term,
    source: str = "apple_music",
    identifier: str = "obs-1",
) -> Observation:
    return Observation(
        id=identifier,
        source=source,
        data_type="fixture",
        action="played",
        evidence_channel="music",
        independence_group="music",
        occurred_at=NOW,
        collected_at=NOW,
        terms=tuple(terms),
        record_fingerprint=f"fingerprint:{identifier}",
        content_lineage=f"lineage:{identifier}",
    )


def edge(subject: str, predicate: str, target: str, *, status: str = "active") -> ConceptEdge:
    return ConceptEdge(
        subject_key=subject,
        predicate_key=predicate,
        object_key=target,
        confidence=1.0,
        provenance_type="curated",
        status=status,
    )


class AliasResolutionTests(unittest.TestCase):
    def test_unique_active_preferred_and_alternate_aliases_are_accepted(self) -> None:
        graph = OntologyGraph(
            concepts={
                "topic:preferred": concept("topic:preferred"),
                "topic:alternate": concept("topic:alternate"),
            },
            edges=(),
            aliases={
                "preferred": [("topic:preferred", 1.0, "preferred")],
                "alternate": [("topic:alternate", 0.95, "alternate")],
            },
        )

        self.assertEqual(
            graph.resolve_alias(term("preferred"))[0].state,
            MappingState.ACCEPTED,
        )
        self.assertEqual(
            graph.resolve_alias(term("alternate"))[0].state,
            MappingState.ACCEPTED,
        )

    def test_related_source_and_folded_aliases_remain_candidates(self) -> None:
        graph = OntologyGraph(
            concepts={"topic:x": concept("topic:x")},
            edges=(),
            aliases={
                "related": [("topic:x", 0.9, "related_label")],
                "source": [("topic:x", 0.9, "source_term")],
                "cafe": [("topic:x", 0.99, "preferred_folded")],
            },
        )

        for label in ("related", "source", "cafe"):
            with self.subTest(label=label):
                self.assertEqual(
                    graph.resolve_alias(term(label))[0].state,
                    MappingState.CANDIDATE,
                )

    def test_exact_collision_never_auto_resolves(self) -> None:
        graph = OntologyGraph(
            concepts={
                "topic:animal": concept("topic:animal"),
                "topic:vehicle": concept("topic:vehicle"),
            },
            edges=(),
            aliases={
                "jaguar": [
                    ("topic:animal", 1.0, "preferred"),
                    ("topic:vehicle", 1.0, "preferred"),
                ]
            },
        )

        resolutions = graph.resolve_alias(term("jaguar"))
        self.assertEqual(len(resolutions), 2)
        self.assertEqual(
            {item.state for item in resolutions},
            {MappingState.CANDIDATE},
        )

    def test_type_incompatible_exact_alias_is_rejected(self) -> None:
        graph = OntologyGraph(
            concepts={"creator:apple": concept("creator:apple", kind="creator")},
            edges=(),
            aliases={"apple": [("creator:apple", 1.0, "preferred")]},
        )

        resolution = graph.resolve_alias(term("apple", type_hint="work"))[0]
        self.assertEqual(resolution.state, MappingState.REJECTED)


class MappingSafetyTests(unittest.TestCase):
    def test_mapper_rejects_draft_and_prohibited_concepts(self) -> None:
        graph = OntologyGraph(
            concepts={
                "topic:draft": concept("topic:draft", status="draft"),
                "topic:prohibited": concept(
                    "topic:prohibited",
                    policy=InferencePolicyName.PROHIBITED,
                ),
            },
            edges=(),
            aliases={
                "draft": [("topic:draft", 1.0, "preferred")],
                "prohibited": [("topic:prohibited", 1.0, "preferred")],
            },
        )

        candidates = ObservationMapper(graph).map_observation(
            observation(term("draft"), term("prohibited"))
        )
        self.assertEqual(len(candidates), 2)
        self.assertEqual(
            {item.state for item in candidates},
            {MappingState.REJECTED},
        )

    def test_accepted_evidence_rechecks_concept_safety(self) -> None:
        unsafe = concept(
            "topic:unsafe",
            policy=InferencePolicyName.PROHIBITED,
        )
        graph = OntologyGraph(
            concepts={unsafe.key: unsafe},
            edges=(),
            aliases={"unsafe": [(unsafe.key, 1.0, "preferred")]},
        )
        item_term = term("unsafe")
        item = observation(item_term)
        forged_accepted = MappingCandidate(
            observation_id=item.id,
            term=item_term,
            concept_key=unsafe.key,
            confidence=1.0,
            method="curated_alias",
            state=MappingState.ACCEPTED,
        )

        self.assertEqual(
            ObservationMapper(graph).accepted_evidence(item, [forged_accepted]),
            (),
        )

    def test_unknown_source_yields_no_evidence(self) -> None:
        safe = concept("topic:safe")
        graph = OntologyGraph(
            concepts={safe.key: safe},
            edges=(),
            aliases={"safe": [(safe.key, 1.0, "preferred")]},
        )
        mapper = ObservationMapper(graph)
        item = observation(term("safe"), source="unknown_connector")
        candidates = mapper.map_observation(item)
        self.assertEqual(candidates[0].state, MappingState.ACCEPTED)
        self.assertEqual(mapper.accepted_evidence(item, candidates), ())

    def test_source_cannot_claim_a_different_independence_group(self) -> None:
        safe = concept("topic:safe")
        graph = OntologyGraph(
            concepts={safe.key: safe},
            edges=(),
            aliases={"safe": [(safe.key, 1.0, "preferred")]},
        )
        mapper = ObservationMapper(graph)
        item = observation(term("safe"))
        candidates = mapper.map_observation(item)
        forged = replace(item, evidence_channel="video", independence_group="video")
        self.assertEqual(mapper.accepted_evidence(forged, candidates), ())

    def test_excluded_source_action_cannot_bypass_adapter(self) -> None:
        safe = concept("topic:safe")
        graph = OntologyGraph(
            concepts={safe.key: safe},
            edges=(),
            aliases={"safe": [(safe.key, 1.0, "preferred")]},
        )
        mapper = ObservationMapper(graph)
        recommendation = replace(
            observation(term("safe")),
            data_type="recommendation",
            action="recommendation",
        )
        candidates = mapper.map_observation(recommendation)
        self.assertEqual(mapper.accepted_evidence(recommendation, candidates), ())

        forged_calendar = replace(
            observation(term("safe")),
            source="apple_calendar",
            data_type="event",
            action="scheduled",
            evidence_channel="calendar",
            independence_group="calendar",
            privacy_class="private_calendar_sanitized",
            metadata={
                "calendar_semantic_kind": "booked_activity",
                "predicate": "booked_event",
            },
        )
        self.assertEqual(mapper.map_observation(forged_calendar), ())
        self.assertEqual(
            mapper.accepted_evidence(forged_calendar, (), as_of=NOW), ()
        )

    def test_provider_cross_source_gate_is_copied_to_evidence(self) -> None:
        safe = concept("topic:safe")
        graph = OntologyGraph(
            concepts={safe.key: safe},
            edges=(),
            aliases={"safe": [(safe.key, 1.0, "preferred")]},
        )
        mapper = ObservationMapper(graph)
        item = replace(
            observation(term("safe")),
            source="youtube",
            data_type="liked",
            action="liked",
            evidence_channel="video",
            independence_group="video",
            metadata={"cross_source_fusion_approved": False},
        )
        candidates = mapper.map_observation(item)
        accepted = mapper.accepted_evidence(item, candidates, as_of=NOW)
        self.assertEqual(len(accepted), 1)
        self.assertFalse(accepted[0].cross_source_fusion_allowed)

    def test_forged_external_acceptance_and_foreign_term_yield_no_evidence(self) -> None:
        safe = concept("topic:safe")
        graph = OntologyGraph(
            concepts={safe.key: safe},
            edges=(),
            aliases={"safe": [(safe.key, 1.0, "preferred")]},
        )
        mapper = ObservationMapper(graph)
        original_term = term("safe")
        item = observation(original_term)
        forged_external = MappingCandidate(
            observation_id=item.id,
            term=original_term,
            concept_key=safe.key,
            confidence=1.0,
            method="external_candidate",
            state=MappingState.ACCEPTED,
        )
        foreign_term = MappingCandidate(
            observation_id=item.id,
            term=term("different"),
            concept_key=safe.key,
            confidence=1.0,
            method="curated_alias",
            state=MappingState.ACCEPTED,
        )
        self.assertEqual(
            mapper.accepted_evidence(item, [forged_external, foreign_term]),
            (),
        )

    def test_forged_curated_alias_for_unresolved_concept_yields_no_evidence(self) -> None:
        claimed = concept("topic:claimed")
        actual = concept("topic:actual")
        graph = OntologyGraph(
            concepts={claimed.key: claimed, actual.key: actual},
            edges=(),
            aliases={"safe": [(actual.key, 1.0, "preferred")]},
        )
        mapper = ObservationMapper(graph)
        item_term = term("safe")
        item = observation(item_term)
        forged = MappingCandidate(
            observation_id=item.id,
            term=item_term,
            concept_key=claimed.key,
            confidence=1.0,
            method="curated_alias",
            state=MappingState.ACCEPTED,
        )
        self.assertEqual(mapper.accepted_evidence(item, [forged]), ())

    def test_term_normalization_cannot_spoof_an_alias(self) -> None:
        safe = concept("topic:italian_music")
        graph = OntologyGraph(
            concepts={safe.key: safe},
            edges=(),
            aliases={"italian music": [(safe.key, 1.0, "preferred")]},
        )
        spoofed = Term(
            text="unrelated private string",
            normalized="italian music",
            role="fixture",
            source_field="fixture",
            type_hint="topic",
        )
        item = observation(spoofed)
        mapper = ObservationMapper(graph)
        self.assertEqual(mapper.map_observation(item), ())


class GraphTraversalTests(unittest.TestCase):
    def test_non_broader_traversal_is_one_hop_and_skips_unsafe_target(self) -> None:
        concepts = {
            "topic:start": concept("topic:start"),
            "place:first": concept("place:first", kind="place"),
            "place:second": concept("place:second", kind="place"),
            "place:draft": concept("place:draft", kind="place", status="draft"),
        }
        graph = OntologyGraph(
            concepts=concepts,
            edges=(
                edge("topic:start", "supports_cultural_affinity_candidate", "place:first"),
                edge("place:first", "supports_cultural_affinity_candidate", "place:second"),
                edge("topic:start", "supports_cultural_affinity_candidate", "place:draft"),
            ),
            aliases={},
        )

        targets = graph.safe_targets(
            "topic:start",
            "supports_cultural_affinity_candidate",
            max_hops=3,
        )
        self.assertEqual([item[0] for item in targets], ["place:first"])

    def test_broader_traversal_may_use_multiple_safe_hops(self) -> None:
        concepts = {
            "topic:leaf": concept("topic:leaf"),
            "topic:middle": concept("topic:middle"),
            "hub:root": concept("hub:root", kind="hub"),
        }
        graph = OntologyGraph(
            concepts=concepts,
            edges=(
                edge("topic:leaf", "broader", "topic:middle"),
                edge("topic:middle", "broader", "hub:root"),
            ),
            aliases={},
        )

        targets = graph.safe_targets("topic:leaf", "broader", max_hops=3)
        self.assertEqual(
            [(target, len(path)) for target, path in targets],
            [("topic:middle", 1), ("hub:root", 2)],
        )

    def test_ambiguous_affinity_target_abstains(self) -> None:
        concepts = {
            "place:x": concept("place:x", kind="place"),
            "affinity:a": concept("affinity:a", kind="affinity"),
            "affinity:b": concept("affinity:b", kind="affinity"),
        }
        ambiguous = OntologyGraph(
            concepts=concepts,
            edges=(
                edge("affinity:a", "about", "place:x"),
                edge("affinity:b", "about", "place:x"),
            ),
            aliases={},
        )
        unambiguous = OntologyGraph(
            concepts=concepts,
            edges=(edge("affinity:a", "about", "place:x"),),
            aliases={},
        )

        self.assertIsNone(ambiguous.affinity_for_target("place:x"))
        self.assertEqual(
            unambiguous.affinity_for_target("place:x"),
            concepts["affinity:a"],
        )


if __name__ == "__main__":
    unittest.main()
