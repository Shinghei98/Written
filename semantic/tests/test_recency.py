from __future__ import annotations

import unittest
from dataclasses import FrozenInstanceError, replace
from datetime import datetime, timedelta, timezone
from types import MappingProxyType

from written_ontology.graph import OntologyGraph
from written_ontology.mapping import (
    SOURCE_ACTION_PAIRS,
    SOURCE_LAYOUT,
    ObservationMapper,
)
from written_ontology.models import (
    Concept,
    Evidence,
    InferencePolicyName,
    Observation,
    Term,
)
from written_ontology.recency import (
    DEFAULT_RECENCY_POLICY,
    RECENCY_POLICY_VERSION,
    RecencyKey,
    RecencyPolicyError,
    TemporalStatus,
    TimestampQuality,
)
from written_ontology.scoring import FusionEngine


NOW = datetime(2026, 8, 10, 12, 0, tzinfo=timezone.utc)


def decision(
    domain: str,
    source: str,
    action: str,
    occurred_at: datetime | None,
):
    return DEFAULT_RECENCY_POLICY.evaluate(
        domain=domain,
        source=source,
        action=action,
        occurred_at=occurred_at,
        as_of=NOW,
    )


def mapper_fixture(
    *,
    source: str,
    data_type: str,
    action: str,
    channel: str,
    occurred_at: datetime | None,
    action_weight: float = 1.0,
) -> tuple[ObservationMapper, Observation]:
    concept = Concept(
        key="topic:safe",
        label="Safe topic",
        kind="topic",
        sensitivity="ordinary",
        inference_policy=InferencePolicyName.INFERABLE,
    )
    item_term = Term(
        text="Safe topic",
        normalized="safe topic",
        role="fixture",
        source_field="fixture",
        type_hint="topic",
    )
    graph = OntologyGraph(
        concepts={concept.key: concept},
        edges=(),
        aliases={"safe topic": [(concept.key, 1.0, "preferred")]},
    )
    item = Observation(
        id="observation-1",
        source=source,
        data_type=data_type,
        action=action,
        evidence_channel=channel,
        independence_group=channel,
        occurred_at=occurred_at,
        collected_at=NOW,
        terms=(item_term,),
        record_fingerprint="fingerprint-1",
        content_lineage="lineage-1",
        field_quality=1.0,
        action_weight=action_weight,
    )
    return ObservationMapper(graph), item


class RuleCoverageTests(unittest.TestCase):
    def test_policy_is_versioned_immutable_and_has_no_source_only_fallback(self) -> None:
        policy = DEFAULT_RECENCY_POLICY
        self.assertEqual(policy.version, RECENCY_POLICY_VERSION)
        self.assertIsInstance(policy.rules, MappingProxyType)
        with self.assertRaises(TypeError):
            policy.rules[RecencyKey("video", "youtube", "future")] = next(  # type: ignore[index]
                iter(policy.rules.values())
            )
        with self.assertRaises(FrozenInstanceError):
            policy.version = "changed"  # type: ignore[misc]

        with self.assertRaises(RecencyPolicyError) as caught:
            decision("video", "youtube", "future_action", NOW)
        self.assertEqual(caught.exception.code, "unsupported_recency_key")

    def test_every_allowed_source_action_has_exactly_one_registered_rule(self) -> None:
        expected = {
            RecencyKey(SOURCE_LAYOUT[source][0], source, action)
            for source, pairs in SOURCE_ACTION_PAIRS.items()
            for _data_type, action in pairs
        }
        self.assertEqual(set(DEFAULT_RECENCY_POLICY.supported_keys), expected)
        self.assertEqual(len(DEFAULT_RECENCY_POLICY.rules), len(expected))


class HistoricalRecencyTests(unittest.TestCase):
    def test_recent_likes_and_new_subscriptions_are_prioritized(self) -> None:
        recent_like = decision("video", "youtube", "liked", NOW)
        old_like = decision(
            "video", "youtube", "liked", NOW - timedelta(days=365)
        )
        new_subscription = decision("video", "youtube", "subscription", NOW)
        old_subscription = decision(
            "video", "youtube", "subscription", NOW - timedelta(days=365)
        )
        new_watch = decision("video", "youtube", "watched", NOW)

        self.assertGreater(recent_like.weight, old_like.weight)
        self.assertGreater(new_subscription.weight, old_subscription.weight)
        self.assertGreater(new_subscription.weight, new_watch.weight)
        self.assertEqual(recent_like.temporal_status, TemporalStatus.RECENT)
        self.assertEqual(new_subscription.temporal_status, TemporalStatus.RECENT)

    def test_ephemeral_video_behavior_decays_faster_than_likes_and_subscriptions(self) -> None:
        occurred = NOW - timedelta(days=180)
        watched = decision("video", "youtube", "watched", occurred)
        liked = decision("video", "youtube", "liked", occurred)
        subscribed = decision("video", "youtube", "subscription", occurred)

        self.assertEqual(watched.half_life_days, 30.0)
        self.assertEqual(liked.half_life_days, 120.0)
        self.assertEqual(subscribed.half_life_days, 1080.0)
        self.assertLess(watched.weight, liked.weight)
        self.assertLess(liked.weight, subscribed.weight)

    def test_library_follow_and_save_signals_outlast_recent_play_behavior(self) -> None:
        occurred = NOW - timedelta(days=365)
        recent_play = decision(
            "music", "apple_music", "recently_played", occurred
        )
        library = decision("music", "apple_music", "library_song", occurred)
        follow = decision("music", "apple_music", "followed_artist", occurred)
        podcast_play = decision("podcast", "podcast", "played", occurred)
        podcast_save = decision("podcast", "podcast", "saved", occurred)

        self.assertGreater(library.weight, recent_play.weight)
        self.assertGreater(follow.weight, recent_play.weight)
        self.assertGreater(podcast_save.weight, podcast_play.weight)

    def test_derived_fitness_habit_decays_as_a_current_routine(self) -> None:
        recent = decision("fitness", "healthkit", "routine", NOW)
        old = decision(
            "fitness", "healthkit", "routine", NOW - timedelta(days=43)
        )
        self.assertEqual(recent.half_life_days, 21.0)
        self.assertGreater(recent.weight, old.weight)
        self.assertEqual(old.temporal_status, TemporalStatus.EXPIRED)
        self.assertEqual(recent.rule_id, "fitness.routine.current")

    def test_half_life_halves_only_weight_above_the_nonzero_floor(self) -> None:
        liked = decision(
            "video", "youtube", "liked", NOW - timedelta(days=120)
        )
        expected = 0.12 + (1.0 - 0.12) / 2.0
        self.assertAlmostEqual(liked.weight, expected, places=8)
        self.assertGreater(liked.weight, 0.0)

    def test_historical_future_timestamp_allows_small_skew_but_not_future_data(self) -> None:
        at_boundary = decision(
            "video", "youtube", "liked", NOW + timedelta(hours=24)
        )
        self.assertEqual(
            at_boundary.temporal_status, TemporalStatus.FUTURE_CLOCK_SKEW
        )
        with self.assertRaises(RecencyPolicyError) as caught:
            decision(
                "video",
                "youtube",
                "liked",
                NOW + timedelta(hours=24, microseconds=1),
            )
        self.assertEqual(
            caught.exception.code, "future_timestamp_for_historical_action"
        )


class ScheduledRecencyTests(unittest.TestCase):
    def test_future_event_enters_anticipation_window_and_peaks_at_event(self) -> None:
        outside = decision(
            "calendar", "apple_calendar", "scheduled", NOW + timedelta(days=181)
        )
        boundary = decision(
            "calendar", "apple_calendar", "scheduled", NOW + timedelta(days=180)
        )
        halfway = decision(
            "calendar", "apple_calendar", "scheduled", NOW + timedelta(days=90)
        )
        current = decision("calendar", "apple_calendar", "scheduled", NOW)

        self.assertEqual(outside.temporal_status, TemporalStatus.FUTURE_OUTSIDE_WINDOW)
        self.assertEqual(boundary.temporal_status, TemporalStatus.FUTURE_ANTICIPATION)
        self.assertEqual(halfway.temporal_status, TemporalStatus.FUTURE_ANTICIPATION)
        self.assertEqual(current.temporal_status, TemporalStatus.EVENT_CURRENT)
        self.assertEqual(outside.weight, boundary.weight)
        self.assertLess(boundary.weight, halfway.weight)
        self.assertLess(halfway.weight, current.weight)
        self.assertEqual(current.weight, 1.0)

    def test_scheduled_event_decays_after_event_and_eventually_expires(self) -> None:
        current = decision("calendar", "google_calendar", "scheduled", NOW)
        post_half_life = decision(
            "calendar",
            "google_calendar",
            "scheduled",
            NOW - timedelta(days=540),
        )
        expired = decision(
            "calendar",
            "google_calendar",
            "scheduled",
            NOW - timedelta(days=1825),
        )

        self.assertEqual(
            post_half_life.temporal_status, TemporalStatus.POST_EVENT_DECAY
        )
        self.assertAlmostEqual(
            post_half_life.weight, 0.12 + (1.0 - 0.12) / 2.0, places=8
        )
        self.assertEqual(expired.temporal_status, TemporalStatus.EXPIRED)
        self.assertEqual(expired.weight, 0.12)
        self.assertGreater(current.weight, post_half_life.weight)
        self.assertGreater(post_half_life.weight, expired.weight)


class MissingAndInvalidTimestampTests(unittest.TestCase):
    def test_missing_timestamp_is_explicitly_unknown_lower_quality_and_nonzero(self) -> None:
        unknown = decision("video", "youtube", "liked", None)
        self.assertEqual(unknown.temporal_status, TemporalStatus.UNKNOWN_TIMESTAMP)
        self.assertEqual(unknown.timestamp_quality, TimestampQuality.UNKNOWN)
        self.assertGreater(unknown.weight, 0.0)
        self.assertLess(unknown.weight, 1.0)
        self.assertGreater(unknown.timestamp_quality_weight, 0.0)
        self.assertLess(unknown.timestamp_quality_weight, 1.0)

        step = unknown.evidence_step()
        self.assertEqual(step["policy_version"], RECENCY_POLICY_VERSION)
        self.assertEqual(step["timestamp_quality"], "unknown")
        serialized = repr(step)
        self.assertNotIn("occurred_at", serialized)
        self.assertNotIn(NOW.isoformat(), serialized)

    def test_every_rule_keeps_missing_timestamp_above_zero(self) -> None:
        for key in DEFAULT_RECENCY_POLICY.supported_keys:
            with self.subTest(key=key):
                unknown = DEFAULT_RECENCY_POLICY.evaluate(
                    domain=key.domain,
                    source=key.source,
                    action=key.action,
                    occurred_at=None,
                    as_of=NOW,
                )
                self.assertGreater(unknown.weight, 0.0)
                self.assertGreater(unknown.timestamp_quality_weight, 0.0)

    def test_naive_or_non_datetime_inputs_fail_closed(self) -> None:
        with self.assertRaises(RecencyPolicyError) as naive_as_of:
            DEFAULT_RECENCY_POLICY.evaluate(
                domain="video",
                source="youtube",
                action="liked",
                occurred_at=NOW,
                as_of=NOW.replace(tzinfo=None),
            )
        self.assertEqual(naive_as_of.exception.code, "invalid_as_of")

        with self.assertRaises(RecencyPolicyError) as naive_occurrence:
            DEFAULT_RECENCY_POLICY.evaluate(
                domain="video",
                source="youtube",
                action="liked",
                occurred_at=NOW.replace(tzinfo=None),
                as_of=NOW,
            )
        self.assertEqual(naive_occurrence.exception.code, "invalid_occurred_at")

        with self.assertRaises(RecencyPolicyError) as wrong_type:
            DEFAULT_RECENCY_POLICY.evaluate(
                domain="video",
                source="youtube",
                action="liked",
                occurred_at="2026-08-10",  # type: ignore[arg-type]
                as_of=NOW,
            )
        self.assertEqual(wrong_type.exception.code, "invalid_occurred_at")


class MapperAndScoringIntegrationTests(unittest.TestCase):
    def test_mapper_requires_pinned_as_of_and_exposes_sanitized_policy_provenance(self) -> None:
        mapper, item = mapper_fixture(
            source="youtube",
            data_type="liked",
            action="liked",
            channel="video",
            occurred_at=NOW - timedelta(days=5),
        )
        candidates = mapper.map_observation(item)
        self.assertEqual(mapper.accepted_evidence(item, candidates), ())

        accepted = mapper.accepted_evidence(item, candidates, as_of=NOW)
        self.assertEqual(len(accepted), 1)
        evidence = accepted[0]
        self.assertEqual(evidence.recency_policy_version, RECENCY_POLICY_VERSION)
        self.assertEqual(evidence.recency_rule_id, "video.like.recent")
        self.assertEqual(evidence.recency_status, "recent")
        recency_step = next(
            step for step in evidence.evidence_path if step["step"] == "recency_policy"
        )
        self.assertEqual(recency_step["policy_version"], RECENCY_POLICY_VERSION)
        self.assertNotIn("occurred_at", recency_step)
        self.assertNotIn(NOW.isoformat(), repr(recency_step))

    def test_missing_timestamp_reaches_evidence_as_lower_quality_not_zero(self) -> None:
        mapper, item = mapper_fixture(
            source="youtube",
            data_type="liked",
            action="liked",
            channel="video",
            occurred_at=None,
        )
        accepted = mapper.accepted_evidence(
            item, mapper.map_observation(item), as_of=NOW
        )
        self.assertEqual(len(accepted), 1)
        evidence = accepted[0]
        self.assertEqual(evidence.recency_status, "unknown_timestamp")
        self.assertGreater(evidence.recency_weight, 0.0)
        self.assertGreater(evidence.recency_quality, 0.0)
        self.assertLess(evidence.recency_quality, 1.0)
        self.assertGreater(evidence.raw_contribution, 0.0)

    def test_one_structurally_accepted_ticket_uses_typed_not_generic_mapping(self) -> None:
        mapper, item = mapper_fixture(
            source="apple_calendar",
            data_type="event",
            action="scheduled",
            channel="calendar",
            occurred_at=NOW,
            action_weight=0.92,
        )
        self.assertEqual(mapper.map_observation(item), ())
        self.assertEqual(
            mapper.accepted_evidence(item, (), as_of=NOW),
            (),
        )

    def test_repeated_event_rows_still_dedupe_and_saturate_by_lineage(self) -> None:
        base = Evidence(
            observation_id="event-1",
            concept_key="topic:x",
            source="apple_calendar",
            evidence_channel="calendar",
            independence_group="calendar",
            content_lineage="journey-1",
            mapping_confidence=0.80,
            action_weight=1.0,
            source_quality=1.0,
            recency_weight=1.0,
            recency_policy_version=RECENCY_POLICY_VERSION,
            recency_rule_id="calendar.scheduled.anticipation",
            recency_status="event_current",
        )
        engine = FusionEngine()
        single = engine.score("topic:x", [base])
        exact_mirrors = engine.score("topic:x", [base] * 100)
        self.assertEqual(single, exact_mirrors)

        two_events = [base, replace(base, observation_id="event-2")]
        many_events = [
            replace(base, observation_id=f"event-{index}")
            for index in range(1, 101)
        ]
        self.assertEqual(
            engine.score("topic:x", two_events).strength,
            engine.score("topic:x", many_events).strength,
        )

    def test_malformed_recency_metadata_or_quality_cannot_enter_fusion(self) -> None:
        valid = Evidence(
            observation_id="video-1",
            concept_key="topic:x",
            source="youtube",
            evidence_channel="video",
            independence_group="video",
            content_lineage="video-1",
            mapping_confidence=1.0,
            action_weight=1.0,
            source_quality=1.0,
        )
        for malformed in (
            replace(valid, recency_quality=float("nan")),
            replace(valid, recency_policy_version=""),
            replace(valid, recency_rule_id=""),
            replace(valid, recency_status=""),
        ):
            with self.subTest(malformed=malformed):
                score = FusionEngine().score("topic:x", [malformed])
                self.assertEqual(score.strength, 0.0)


if __name__ == "__main__":
    unittest.main()
