from __future__ import annotations

import unittest
from dataclasses import replace
from pathlib import Path

from written_ontology.graph import OntologyGraph
from written_ontology.models import Evidence
from written_ontology.scoring import ConvergenceEngine, FusionEngine, ScoringConfig


def evidence(
    identifier: str,
    group: str,
    lineage: str,
    contribution: float = 0.8,
    *,
    cross_source_fusion_allowed: bool = True,
) -> Evidence:
    source = {
        "music": "apple_music",
        "video": "youtube",
        "calendar": "apple_calendar",
    }.get(group, group)
    return Evidence(
        observation_id=identifier,
        concept_key="topic:x",
        source=source,
        evidence_channel=group,
        independence_group=group,
        content_lineage=lineage,
        mapping_confidence=contribution,
        action_weight=1.0,
        source_quality=1.0,
        cross_source_fusion_allowed=cross_source_fusion_allowed,
    )


class ScoringTests(unittest.TestCase):
    def test_exact_duplicates_do_not_change_score(self) -> None:
        engine = FusionEngine()
        item = evidence("obs-1", "music", "track-1")
        single = engine.score("topic:x", [item])
        duplicates = engine.score("topic:x", [item] * 100)
        self.assertEqual(single, duplicates)

    def test_same_channel_does_not_increase_breadth(self) -> None:
        engine = FusionEngine()
        items = [
            evidence("apple-1", "music", "track-1"),
            evidence("spotify-1", "music", "track-1"),
            evidence("apple-2", "music", "track-2"),
        ]
        score = engine.score("topic:x", items)
        self.assertEqual(score.breadth, 1)

    def test_cross_posted_lineage_does_not_create_fake_breadth(self) -> None:
        engine = FusionEngine()
        items = [
            evidence("music-1", "music", "canonical-isrc-1"),
            evidence("video-1", "video", "canonical-isrc-1"),
        ]
        score = engine.score("topic:x", items)
        self.assertEqual(score.breadth, 1)
        self.assertEqual(len(score.source_breakdown), 1)

    def test_independent_groups_increase_breadth_and_stability(self) -> None:
        engine = FusionEngine()
        items = [
            evidence("m1", "music", "track-1"),
            evidence("v1", "video", "film-1"),
            evidence("c1", "calendar", "event-1"),
        ]
        score = engine.score("topic:x", items)
        self.assertEqual(score.breadth, 3)
        self.assertGreater(score.stability, 0)

    def test_provider_gate_allows_local_score_but_blocks_cross_source_fusion(self) -> None:
        engine = FusionEngine()
        gated_video = evidence(
            "v1",
            "video",
            "video-1",
            contribution=0.95,
            cross_source_fusion_allowed=False,
        )
        local = engine.score("topic:x", [gated_video])
        combined = engine.score(
            "topic:x",
            [evidence("m1", "music", "track-1", 0.40), gated_video],
        )
        self.assertGreater(local.strength, 0.0)
        self.assertEqual(combined, local)
        self.assertEqual(combined.breadth, 1)

    def test_gated_provider_cannot_fire_shared_target_convergence(self) -> None:
        graph = OntologyGraph.from_seed_dir(Path(__file__).resolve().parents[1] / "ontology")
        engine = ConvergenceEngine(graph)
        items = [
            Evidence(
                observation_id="music",
                concept_key="concept:italian_music",
                source="apple_music",
                evidence_channel="music",
                independence_group="music",
                content_lineage="track-1",
                mapping_confidence=1.0,
                action_weight=1.0,
                source_quality=1.0,
            ),
            Evidence(
                observation_id="video",
                concept_key="concept:italian_cinema",
                source="youtube",
                evidence_channel="video",
                independence_group="video",
                content_lineage="video-1",
                mapping_confidence=1.0,
                action_weight=1.0,
                source_quality=1.0,
                cross_source_fusion_allowed=False,
            ),
        ]
        self.assertEqual(engine.infer_shared_target_affinities(items), ())

    def test_missing_source_count_does_not_reduce_strength(self) -> None:
        engine = FusionEngine()
        items = [evidence("m1", "music", "track-1")]
        connected = engine.score("topic:x", items, usable_source_count=1, missing_source_count=0)
        missing = engine.score("topic:x", items, usable_source_count=1, missing_source_count=4)
        self.assertEqual(connected.strength, missing.strength)
        self.assertEqual(connected.mapping_agreement, missing.mapping_agreement)
        self.assertEqual(connected.evidence_quality, missing.evidence_quality)

    def test_two_weak_sources_do_not_create_affinity(self) -> None:
        graph = OntologyGraph.from_seed_dir(Path(__file__).resolve().parents[1] / "ontology")
        engine = ConvergenceEngine(graph)
        items = [
            Evidence(
                observation_id="weak-music",
                concept_key="concept:italian_music",
                source="apple_music",
                evidence_channel="music",
                independence_group="music",
                content_lineage="track-1",
                mapping_confidence=0.20,
                action_weight=0.20,
                source_quality=0.40,
            ),
            Evidence(
                observation_id="weak-video",
                concept_key="concept:italian_cinema",
                source="youtube",
                evidence_channel="video",
                independence_group="video",
                content_lineage="film-1",
                mapping_confidence=0.20,
                action_weight=0.20,
                source_quality=0.40,
            ),
        ]
        self.assertEqual(engine.infer_shared_target_affinities(items), ())

    def test_caller_cannot_substitute_a_generic_graph_relation(self) -> None:
        graph = OntologyGraph.from_seed_dir(Path(__file__).resolve().parents[1] / "ontology")
        with self.assertRaises(TypeError):
            ConvergenceEngine(graph).infer_shared_target_affinities(
                [], relation="about"  # type: ignore[call-arg]
            )

    def test_malformed_evidence_is_dropped_instead_of_inflating_metrics(self) -> None:
        malformed = replace(
            evidence("bad", "music", "lineage"),
            mapping_confidence=5.0,
            source_quality=float("nan"),
        )
        score = FusionEngine().score("topic:x", [malformed])
        self.assertEqual(score.strength, 0.0)
        self.assertEqual(score.mapping_agreement, 0.0)
        self.assertEqual(score.evidence_quality, 0.0)

    def test_invalid_scoring_config_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            FusionEngine(ScoringConfig(source_alpha=float("inf")))
        with self.assertRaises(ValueError):
            FusionEngine(ScoringConfig(minimum_convergence_groups=1))
        with self.assertRaises(ValueError):
            FusionEngine(ScoringConfig(minimum_convergence_groups=float("nan")))  # type: ignore[arg-type]

    def test_unhashable_or_malformed_evidence_is_dropped(self) -> None:
        malformed = replace(
            evidence("bad", "music", "lineage"),
            independence_group=["not", "hashable"],  # type: ignore[arg-type]
        )
        self.assertEqual(FusionEngine().score("topic:x", [malformed]).strength, 0.0)
        self.assertEqual(FusionEngine().score("topic:x", [None]).strength, 0.0)  # type: ignore[list-item]

    def test_direct_evidence_cannot_spoof_an_independence_group(self) -> None:
        spoofed = replace(
            evidence("spoofed", "music", "lineage"),
            evidence_channel="video",
            independence_group="video",
        )
        self.assertEqual(FusionEngine().score("topic:x", [spoofed]).strength, 0.0)


if __name__ == "__main__":
    unittest.main()
