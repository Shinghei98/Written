from __future__ import annotations

import unittest
from dataclasses import replace
from datetime import datetime, timedelta, timezone

from written_ontology.healthkit import (
    FitnessCandidateKind,
    FitnessHabitBuilder,
    FitnessHabitPolicy,
    HealthKitCoverageState,
    HealthKitRecordKind,
    fitness_candidate_observation,
    ingest_healthkit_rows,
)
from written_ontology.graph import OntologyGraph
from written_ontology.mapping import ObservationMapper
from written_ontology.models import Concept, InferencePolicyName
from written_ontology.safety import InferenceSafetyPolicy


NOW = datetime(2030, 2, 15, 12, 0, tzinfo=timezone.utc)


def row(
    source: str,
    data_type: str,
    item_id: str,
    *,
    name: str = "",
    detail: str = "",
    extra: str = "",
) -> dict[str, str]:
    return {
        "source": source,
        "data_type": data_type,
        "item_id": item_id,
        "name": name,
        "creator": "",
        "detail": detail,
        "extra": extra,
        "collected_at": NOW.isoformat(),
    }


def workout(
    index: int,
    when: datetime,
    *,
    activity: str = "running",
    source: str = "healthkit",
) -> dict[str, str]:
    return row(
        source,
        "workout",
        f"w-{index}",
        name="Private free-text workout name",
        detail="route and heart-rate text must not propagate",
        extra=(
            f"activity_type={activity};start={when.isoformat()};"
            "duration_min=35;heart_rate=188;route=private"
        ),
    )


class HealthKitIngestionTests(unittest.TestCase):
    def test_source_aliases_canonicalize_and_deduplicate(self) -> None:
        rows = [
            row(
                "health",
                "activity_day",
                "2030-01-01",
                name="2030-01-01",
                extra="steps=8000;active_kcal=250;first_move=07:30",
            ),
            row(
                "HealthKit",
                "activity_day",
                "2030-01-01",
                name="2030-01-01",
                extra="steps=8000;active_kcal=250;first_move=07:30",
            ),
        ]
        result = ingest_healthkit_rows(rows)
        self.assertEqual(len(result.records), 1)
        self.assertEqual(result.excluded_counts["duplicate_healthkit_record"], 1)
        self.assertEqual(result.coverage.state, HealthKitCoverageState.AGGREGATE_ONLY)

    def test_aggregate_only_shape_is_ingested_but_derives_no_habit(self) -> None:
        rows = []
        for offset in range(365):
            day = (NOW.date() - timedelta(days=offset)).isoformat()
            rows.append(
                row(
                    "health",
                    "activity_day",
                    day,
                    name=day,
                    extra="steps=7500;active_kcal=200;first_move=08:00",
                )
            )
        for hour in range(24):
            rows.append(
                row(
                    "health",
                    "activity_hour",
                    str(hour),
                    extra=f"hour={hour};steps=100000;share={1 / 24:.8f}",
                )
            )
        result = ingest_healthkit_rows(rows)
        self.assertEqual(len(result.records), 389)
        self.assertEqual(result.coverage.activity_days, 365)
        self.assertEqual(result.coverage.activity_hours, 24)
        self.assertEqual(result.coverage.state, HealthKitCoverageState.AGGREGATE_ONLY)
        self.assertEqual(FitnessHabitBuilder().derive(result.records, as_of=NOW), ())

    def test_closed_contract_rejects_unknown_malformed_and_nonfinite_values(self) -> None:
        rows = [
            row("healthkit", "heart_rate", "a", extra="bpm=72"),
            row("healthkit", "activity_day", "b", name="not-a-date", extra="steps=10"),
            row(
                "healthkit",
                "activity_hour",
                "c",
                extra="hour=24;steps=100;share=0.1",
            ),
            row(
                "healthkit",
                "workout",
                "d",
                extra=f"activity_type=running;start={NOW.isoformat()};duration_min=nan",
            ),
            row("healthkit", "activity_hour", "e", extra="hour=7;steps=100"),
            row("healthkit", "activity_hour", "f", extra="hour=7;steps=200"),
            row(
                "healthkit",
                "workout",
                "g",
                extra=(
                    "activity_type=running;start=2030-01-02T07:00:00;"
                    "duration_min=30"
                ),
            ),
        ]
        result = ingest_healthkit_rows(rows)
        self.assertEqual(result.records, ())
        self.assertEqual(result.coverage.state, HealthKitCoverageState.EMPTY)
        self.assertEqual(result.excluded_counts["duplicate_healthkit_hour_bin"], 2)
        self.assertEqual(sum(result.excluded_counts.values()), 7)

        incoherent = [
            row(
                "healthkit",
                "activity_hour",
                f"bad-share-{hour}",
                extra=f"hour={hour};share=0.1",
            )
            for hour in range(24)
        ]
        incoherent_result = ingest_healthkit_rows(incoherent)
        self.assertEqual(incoherent_result.records, ())
        self.assertEqual(
            incoherent_result.excluded_counts[
                "incoherent_healthkit_hour_share_snapshot"
            ],
            24,
        )

        multi_day = ingest_healthkit_rows(
            [
                row(
                    "healthkit",
                    "workout",
                    "multi-day",
                    extra=(
                        f"activity_type=running;start={NOW.isoformat()};"
                        f"end={(NOW + timedelta(days=2)).isoformat()}"
                    ),
                )
            ]
        )
        self.assertEqual(multi_day.records, ())

    def test_removed_row_is_not_retained_and_reason_is_ignored(self) -> None:
        result = ingest_healthkit_rows(
            [
                row(
                    "healthkit",
                    "activity_day",
                    "2030-01-01",
                    name="2030-01-01",
                    extra=(
                        "steps=8000;removed_by_user=1;"
                        "removed_reason=private-medical-detail"
                    ),
                )
            ]
        )
        self.assertEqual(result.records, ())
        self.assertEqual(
            result.excluded_counts["user_removed_healthkit_record"], 1
        )
        self.assertNotIn("private-medical-detail", repr(result))

    def test_workout_parser_uses_controlled_type_not_free_text(self) -> None:
        result = ingest_healthkit_rows([workout(1, NOW - timedelta(days=1))])
        self.assertEqual(len(result.records), 1)
        record = result.records[0]
        self.assertEqual(record.kind, HealthKitRecordKind.WORKOUT)
        self.assertEqual(record.activity_concept_key, "activity:running")
        serialized = repr(record)
        self.assertNotIn("Private free-text", serialized)
        self.assertNotIn("heart_rate", serialized)
        self.assertNotIn("route", serialized)


class FitnessHabitBuilderTests(unittest.TestCase):
    def records(self, rows: list[dict[str, str]]):
        return ingest_healthkit_rows(rows).records

    def test_one_or_three_workouts_do_not_become_a_routine(self) -> None:
        rows = [
            workout(index, NOW - timedelta(days=index * 7))
            for index in range(1, 4)
        ]
        self.assertEqual(
            FitnessHabitBuilder().derive(self.records(rows), as_of=NOW), ()
        )

    def test_threshold_across_three_weeks_emits_one_controlled_routine(self) -> None:
        rows = [
            workout(1, NOW - timedelta(days=2)),
            workout(2, NOW - timedelta(days=8)),
            workout(3, NOW - timedelta(days=15)),
            workout(4, NOW - timedelta(days=20)),
        ]
        candidates = FitnessHabitBuilder().derive(self.records(rows), as_of=NOW)
        activity = next(
            item
            for item in candidates
            if item.kind is FitnessCandidateKind.ACTIVITY_ROUTINE
        )
        self.assertEqual(activity.concept_key, "activity:running")
        self.assertEqual(activity.predicate, "routine")
        self.assertGreaterEqual(activity.distinct_weeks, 3)
        self.assertTrue(activity.requires_user_review)

    def test_duplicate_workout_rows_do_not_satisfy_recurrence(self) -> None:
        repeated = workout(1, NOW - timedelta(days=2))
        records = self.records([repeated, dict(repeated), dict(repeated), dict(repeated)])
        self.assertEqual(len(records), 1)
        self.assertEqual(FitnessHabitBuilder().derive(records, as_of=NOW), ())

    def test_revised_provider_item_cannot_satisfy_recurrence(self) -> None:
        physical = [
            workout(1, NOW - timedelta(days=2)),
            workout(2, NOW - timedelta(days=9)),
            workout(3, NOW - timedelta(days=16)),
        ]
        revised_first = dict(physical[0])
        revised_first["extra"] = revised_first["extra"].replace(
            "duration_min=35", "duration_min=36"
        )

        result = ingest_healthkit_rows([*physical, revised_first])

        self.assertEqual(len(result.records), 2)
        self.assertEqual(
            result.excluded_counts["conflicting_healthkit_item_revision"], 2
        )
        self.assertEqual(FitnessHabitBuilder().derive(result.records, as_of=NOW), ())

    def test_revised_provider_item_across_ingestion_runs_cannot_recur(self) -> None:
        physical = [
            workout(1, NOW - timedelta(days=2)),
            workout(2, NOW - timedelta(days=9)),
            workout(3, NOW - timedelta(days=16)),
        ]
        revised_first = dict(physical[0])
        revised_first["extra"] = revised_first["extra"].replace(
            "duration_min=35", "duration_min=36"
        )
        records_from_separate_runs = (
            *ingest_healthkit_rows(physical).records,
            *ingest_healthkit_rows([revised_first]).records,
        )

        self.assertEqual(len(records_from_separate_runs), 4)
        self.assertEqual(
            FitnessHabitBuilder().derive(records_from_separate_runs, as_of=NOW),
            (),
        )

    def test_session_without_provider_item_identity_fails_closed(self) -> None:
        missing_identity = workout(1, NOW - timedelta(days=2))
        missing_identity["item_id"] = ""

        result = ingest_healthkit_rows([missing_identity])

        self.assertEqual(result.records, ())
        self.assertEqual(
            result.excluded_counts["missing_healthkit_source_item_identity"], 1
        )

    def test_daypart_requires_concentration_and_week_coverage(self) -> None:
        rows = []
        for index, days in enumerate((1, 3, 8, 10, 15, 17), start=1):
            when = (NOW - timedelta(days=days)).replace(hour=7)
            rows.append(workout(index, when))
        candidates = FitnessHabitBuilder().derive(self.records(rows), as_of=NOW)
        daypart = next(
            item
            for item in candidates
            if item.kind is FitnessCandidateKind.WORKOUT_DAYPART
        )
        self.assertEqual(daypart.concept_key, "routine:morning_workouts")
        daypart_observation = fitness_candidate_observation(daypart)
        daypart_concept = Concept(
            key="routine:morning_workouts",
            label="Morning workouts",
            kind="activity",
            sensitivity="ordinary",
            inference_policy=InferencePolicyName.REVIEW_REQUIRED,
        )
        daypart_mapper = ObservationMapper(
            OntologyGraph(
                concepts={daypart_concept.key: daypart_concept},
                edges=(),
                aliases={
                    "morning workouts": [
                        (daypart_concept.key, 1.0, "preferred")
                    ]
                },
            )
        )
        self.assertTrue(
            daypart_mapper.accepted_evidence(
                daypart_observation,
                daypart_mapper.map_observation(daypart_observation),
                as_of=NOW,
            )
        )

        monday = (NOW - timedelta(days=NOW.weekday())).replace(
            hour=7, minute=0, second=0, microsecond=0
        )
        concentrated_in_one_week = [
            workout(100 + day, monday + timedelta(days=day))
            for day in range(5)
        ] + [
            workout(200, (monday - timedelta(days=7)).replace(hour=19)),
            workout(201, (monday - timedelta(days=14)).replace(hour=19)),
        ]
        adversarial = FitnessHabitBuilder().derive(
            self.records(concentrated_in_one_week), as_of=NOW
        )
        self.assertFalse(
            any(
                item.kind is FitnessCandidateKind.WORKOUT_DAYPART
                for item in adversarial
            )
        )

    def test_sleep_is_typed_private_but_does_not_emit_a_semantic_claim(self) -> None:
        rows = []
        for index in range(14):
            start = (NOW - timedelta(days=index + 1)).replace(hour=23, minute=index % 3)
            end = start + timedelta(hours=7, minutes=30)
            rows.append(
                row(
                    "healthkit",
                    "sleep",
                    f"s-{index}",
                    extra=(
                        f"stage=asleep;start={start.isoformat()};end={end.isoformat()};"
                        "diagnosis=insomnia;sleep_quality=poor"
                    ),
                )
            )
        records = self.records(rows)
        self.assertEqual(len(records), 14)
        self.assertTrue(
            all(item.kind is HealthKitRecordKind.SLEEP_SESSION for item in records)
        )
        candidates = FitnessHabitBuilder().derive(records, as_of=NOW)
        self.assertEqual(candidates, ())
        self.assertNotIn("insomnia", repr(records))
        self.assertNotIn("sleep_quality", repr(records))

    def test_sanitized_candidate_projection_has_no_raw_health_values_or_egress(self) -> None:
        rows = [
            workout(1, NOW - timedelta(days=2)),
            workout(2, NOW - timedelta(days=8)),
            workout(3, NOW - timedelta(days=15)),
            workout(4, NOW - timedelta(days=20)),
        ]
        candidate = next(
            item
            for item in FitnessHabitBuilder().derive(self.records(rows), as_of=NOW)
            if item.kind is FitnessCandidateKind.ACTIVITY_ROUTINE
        )
        observation = fitness_candidate_observation(candidate)
        self.assertEqual(observation.source, "healthkit")
        self.assertEqual(observation.data_type, "fitness_habit")
        self.assertEqual(observation.action, "routine")
        self.assertEqual(observation.privacy_class, "private_fitness_sanitized")
        self.assertEqual(observation.metadata["purpose_scope"], "fitness_connection")
        self.assertFalse(observation.metadata["cross_source_fusion_approved"])
        self.assertNotIn("duration", repr(observation))
        with self.assertRaises(ValueError):
            replace(candidate, label="Raw private workout title")
        with self.assertRaises(ValueError):
            replace(candidate, concept_key="place:italy")
        with self.assertRaises(ValueError):
            replace(candidate, mapping_agreement=True)
        with self.assertRaises(ValueError):
            replace(candidate, requires_user_review=False)
        with self.assertRaises(ValueError):
            replace(
                self.records(rows)[0],
                policy_version="written-healthkit-fitness-v0.9.0",
            )
        with self.assertRaises(ValueError):
            replace(
                candidate,
                support_record_ids=(candidate.support_record_ids[0],),
            )
        with self.assertRaises(ValueError):
            replace(
                candidate,
                support_record_ids=(
                    candidate.support_record_ids[0],
                    candidate.support_record_ids[0],
                    *candidate.support_record_ids[2:],
                ),
            )
        with self.assertRaises(ValueError):
            FitnessHabitPolicy(daypart_min_concentration=True)
        with self.assertRaises(ValueError):
            FitnessHabitPolicy(workout_window_days=365)
        running = Concept(
            key="activity:running",
            label="Running",
            kind="activity",
            sensitivity="ordinary",
            inference_policy=InferencePolicyName.REVIEW_REQUIRED,
        )
        mapper = ObservationMapper(
            OntologyGraph(
                concepts={running.key: running},
                edges=(),
                aliases={"running": [(running.key, 1.0, "preferred")]},
            )
        )
        accepted = mapper.accepted_evidence(
            observation, mapper.map_observation(observation), as_of=NOW
        )
        self.assertTrue(accepted)
        self.assertTrue(
            all(not item.cross_source_fusion_allowed for item in accepted)
        )
        forged_projection = replace(
            observation,
            privacy_class="public_catalog",
            metadata={},
        )
        self.assertEqual(mapper.map_observation(forged_projection), ())
        self.assertEqual(
            mapper.accepted_evidence(
                forged_projection,
                mapper.map_observation(observation),
                as_of=NOW,
            ),
            (),
        )
        raw_extra_projection = replace(
            observation,
            metadata={**observation.metadata, "raw_title": "private value"},
        )
        stale_policy_projection = replace(
            observation,
            metadata={
                **observation.metadata,
                "policy_version": "written-healthkit-fitness-v0.9.0",
            },
        )
        self.assertEqual(mapper.map_observation(raw_extra_projection), ())
        self.assertEqual(mapper.map_observation(stale_policy_projection), ())
        expired_observation = replace(
            observation,
            occurred_at=NOW - timedelta(days=43),
            collected_at=NOW - timedelta(days=43),
        )
        self.assertEqual(
            mapper.accepted_evidence(
                expired_observation,
                mapper.map_observation(expired_observation),
                as_of=NOW,
            ),
            (),
        )
        safety = InferenceSafetyPolicy()
        self.assertTrue(
            all(
                not safety.term_may_leave_device_boundary(observation, term)
                for term in observation.terms
            )
        )
        self.assertTrue(
            all(
                not safety.term_is_safe_for_global_mining(observation, term)
                for term in observation.terms
            )
        )


if __name__ == "__main__":
    unittest.main()
