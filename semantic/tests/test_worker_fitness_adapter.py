"""The vault envelope, read by the HealthKit classifier.

**Two shapes meet here and neither side knows about the other.** The app writes
a typed `FitnessPayload`; `written_ontology.healthkit` reads the legacy row —
`source`, `data_type`, `item_id` and a semicolon `extra` string. `legacy_row` in
`aws/worker/fitness.py` is the join, and every failure mode it has is silent:
a mistyped key, a wrong casing or a float where an integer is wanted all read as
*absent*, which the classifier reports as a malformed row rather than as a bug.
A snapshot would then state, confidently and wrongly, that a year of somebody's
activity was unparseable.

So these assert the classifier's **output**, not the adapter's — the only thing
that proves the two halves actually meet.

Skipped when `WRITTEN_REPOSITORY_PATH` is unset, like the rest of the
repository-integration suite.
"""

import importlib.util
import os
import sys

import pytest

from written_ontology.healthkit import (
    HealthKitCoverageState,
    HealthKitRecordKind,
    ingest_healthkit_rows,
)

REPOSITORY = os.environ.get("WRITTEN_REPOSITORY_PATH")

pytestmark = pytest.mark.skipif(
    not REPOSITORY, reason="WRITTEN_REPOSITORY_PATH is unset"
)


@pytest.fixture(scope="module")
def legacy_row():
    """`aws/worker/fitness.py` is a Lambda module, not an installed package."""
    worker = os.path.join(REPOSITORY, "aws", "worker")
    path = os.path.join(worker, "fitness.py")
    if not os.path.exists(path):
        pytest.skip("worker not present")
    # `fitness` imports `observations`, its sibling.
    if worker not in sys.path:
        sys.path.insert(0, worker)
    spec = importlib.util.spec_from_file_location("written_worker_fitness", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.legacy_row


def envelope(data_type: str, value: dict, item_id: str = "") -> tuple[dict, dict]:
    """A row and the envelope inside it, in the shapes the worker sees.

    The keys are the wire form exactly: snake_case on the envelope, which has
    explicit `CodingKeys`, and camelCase inside the payload, which has none.
    """
    record = {"data_type": data_type}
    return record, {
        "schema_version": "written-source-envelope-v2",
        "record_source_code": "healthkit",
        "data_type": data_type,
        "provider_item_id": item_id,
        "typed_payload": {"kind": "fitness", "value": {"kind": data_type, **value}},
    }


def test_an_activity_day_survives_the_round_trip(legacy_row):
    """The fields the day carries, all the way to an accepted record.

    `firstMoveHour` is the one that was silently lost: the distiller writes
    `first_move=06:00` and `FitnessPayload` read it with `Int("06:00")`, which is
    nil. It is an `Int` on the wire now and `HH:00` again by the time the
    classifier sees it.
    """
    result = ingest_healthkit_rows([legacy_row(*envelope("activity_day", {
        "date": "2026-03-14",
        "steps": 8134.0,          # a Double on the wire, as Swift encodes it
        "activeKcal": 512.0,
        "exerciseMinutes": 41.0,
        "firstMoveHour": 6,
    }))])

    assert result.excluded_counts == {}
    assert len(result.records) == 1
    record = result.records[0]
    assert record.kind is HealthKitRecordKind.ACTIVITY_DAY
    assert record.values["date"] == "2026-03-14"
    # **Integral, not `8134.0`.** `_finite_number(integer=True)` refuses a float
    # string, so without `_whole` the step count vanishes and the day with it.
    assert record.values["steps"] == 8134
    assert record.values["active_kcal"] == 512
    assert record.values["first_move"] == "06:00"


def test_a_day_carrying_only_a_date_is_refused(legacy_row):
    """The negative case, so the test above is not passing on the fallback.

    `_parse_activity_day` rejects a row it recovered nothing from. If the adapter
    wrote `steps=` for an absent value this would parse as a stated blank and
    the row would be accepted empty.
    """
    result = ingest_healthkit_rows([legacy_row(*envelope("activity_day", {
        "date": "2026-03-14",
    }))])
    assert result.records == ()
    assert result.excluded_counts == {"malformed_healthkit_activity_day": 1}


def test_a_snake_case_payload_would_be_refused(legacy_row):
    """Proof that the casing above is load-bearing rather than incidental.

    This is what the first draft of the adapter produced. Every field reads as
    absent and the day is malformed — the exact failure that would have been
    reported as "a year of activity is unparseable" instead of "the keys are
    wrong".
    """
    result = ingest_healthkit_rows([legacy_row(*envelope("activity_day", {
        "date": "2026-03-14",
        "active_kcal": 512.0,
        "first_move_hour": 6,
    }))])
    assert result.records == ()


def test_an_activity_hour_carries_its_share(legacy_row):
    result = ingest_healthkit_rows([legacy_row(*envelope("activity_hour", {
        "hourOfDay": 18,
        "steps": 1204.0,
        "hourShare": 0.1481,
    }))])

    assert len(result.records) == 1
    values = result.records[0].values
    assert values["hour"] == 18
    assert values["steps"] == 1204
    assert values["share"] == pytest.approx(0.1481)


def test_a_workout_nominates_its_activity(legacy_row):
    """The path no device here can exercise yet.

    Every `activity:*` concept the classifier can reach comes from a typed
    workout, so this is the only evidence that the adapter works for the data
    that would actually produce a claim.
    """
    result = ingest_healthkit_rows([legacy_row(*envelope("workout", {
        "sport": "Running",
        "startedAt": "2026-03-14T07:12:00Z",
        "durationMinutes": 38.0,
        "energyKcal": 401.0,
        "distanceKm": 6.4,
        "recordingApp": "Strava",
    }, item_id="workout-1"))])

    assert result.excluded_counts == {}
    assert len(result.records) == 1
    assert result.records[0].kind is HealthKitRecordKind.WORKOUT
    assert result.coverage.state is HealthKitCoverageState.WORKOUT_TYPED


def test_an_unrecognised_sport_nominates_nothing(legacy_row):
    """The guard that makes routing the sport into `activity_type` safe.

    `_parse_workout` reads only `extra` because *free-text workout names never
    nominate an activity*. The adapter puts the sport there anyway, on the
    grounds that it comes from a closed mapping off `HKWorkoutActivityType`
    rather than from anything a person typed. That argument is only worth having
    if the classifier's own closed table still refuses what it does not know —
    so this asserts it does, rather than trusting the comment.
    """
    result = ingest_healthkit_rows([legacy_row(*envelope("workout", {
        "sport": "Underwater hockey",
        "startedAt": "2026-03-14T07:12:00Z",
        "durationMinutes": 38.0,
    }, item_id="workout-2"))])

    assert result.records == ()
    assert result.excluded_counts == {"malformed_healthkit_workout": 1}


def test_a_year_of_aggregates_abstains(legacy_row):
    """What this account actually holds, and what §10 requires of it.

    366 days and 24 hours with no workout is `aggregate_only`, and the point of
    the assertion is the *absence* that follows: no workouts means no activity
    concept may be nominated, however much movement was recorded.
    """
    rows = [
        legacy_row(*envelope("activity_day", {
            "date": f"2026-{month:02d}-{day:02d}",
            "steps": float(3000 + day),
            "firstMoveHour": 7,
        }))
        for month in range(1, 13)
        for day in range(1, 29)
    ] + [
        legacy_row(*envelope("activity_hour", {
            "hourOfDay": hour,
            "steps": float(100 + hour),
        }))
        for hour in range(24)
    ]

    coverage = ingest_healthkit_rows(rows).coverage
    assert coverage.state is HealthKitCoverageState.AGGREGATE_ONLY
    assert coverage.activity_days == 336
    assert coverage.activity_hours == 24
    assert coverage.workouts == 0
    assert coverage.sleep_sessions == 0
