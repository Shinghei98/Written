"""Purpose-limited, typed HealthKit ingestion and habit derivation.

HealthKit is not a bag of free-text ontology terms.  This module accepts a
small set of structured row contracts, retains their quantitative provenance
inside the private fitness lane, and derives only controlled exercise-routine
candidates after versioned recurrence thresholds are met.

The generic term mapper must never receive raw steps, calories, sleep times,
routes, heart-rate values, workout names, or other HealthKit payload fields.
"""

from __future__ import annotations

import math
import re
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from enum import StrEnum
from typing import Any, Iterable, Mapping, Sequence

from .normalize import normalize_text, parse_semicolon_kv, stable_hash


HEALTHKIT_POLICY_VERSION = "written-healthkit-fitness-v1.0.0"
HEALTHKIT_SOURCE_ALIASES = frozenset(
    {
        "health",
        "healthkit",
        "apple_health",
        "apple_healthkit",
        "motion_fitness",
    }
)

_TIME = re.compile(r"^(?:[01]\d|2[0-3]):[0-5]\d(?::[0-5]\d)?$")


class HealthKitRecordKind(StrEnum):
    ACTIVITY_DAY = "activity_day"
    ACTIVITY_HOUR = "activity_hour"
    WORKOUT = "workout"
    SLEEP_SESSION = "sleep_session"


class HealthKitCoverageState(StrEnum):
    EMPTY = "empty"
    AGGREGATE_ONLY = "aggregate_only"
    WORKOUT_TYPED = "workout_typed"
    SLEEP_TYPED = "sleep_typed"
    MIXED = "mixed"


class FitnessCandidateKind(StrEnum):
    ACTIVITY_ROUTINE = "activity_routine"
    WORKOUT_DAYPART = "workout_daypart"


@dataclass(frozen=True, slots=True)
class HealthKitRecord:
    """A purpose-minimized private record, never a generic ontology term."""

    record_id: str
    kind: HealthKitRecordKind
    occurred_at: datetime | None
    record_fingerprint: str
    source_item_fingerprint: str
    activity_concept_key: str | None = None
    activity_label: str | None = None
    controlled_values: tuple[tuple[str, float | int | str], ...] = ()
    policy_version: str = HEALTHKIT_POLICY_VERSION
    data_use_purpose: str = "fitness_connection"

    def __post_init__(self) -> None:
        if (
            re.fullmatch(r"[0-9a-f]{24}", self.record_id) is None
            or re.fullmatch(r"[0-9a-f]{64}", self.record_fingerprint) is None
            or re.fullmatch(r"[0-9a-f]{64}", self.source_item_fingerprint) is None
        ):
            raise ValueError("healthkit_record_requires_stable_identity")
        if self.data_use_purpose != "fitness_connection":
            raise ValueError("healthkit_record_has_invalid_purpose")
        if self.policy_version != HEALTHKIT_POLICY_VERSION:
            raise ValueError("healthkit_record_policy_not_licensed")
        if self.kind is HealthKitRecordKind.WORKOUT and (
            not self.activity_concept_key or not self.activity_label
        ):
            raise ValueError("workout_requires_controlled_activity")
        keys = [key for key, _ in self.controlled_values]
        if len(keys) != len(set(keys)):
            raise ValueError("healthkit_record_has_duplicate_value")

    @property
    def values(self) -> dict[str, float | int | str]:
        return dict(self.controlled_values)


@dataclass(frozen=True, slots=True)
class HealthKitCoverage:
    state: HealthKitCoverageState
    accepted_records: int
    activity_days: int
    activity_hours: int
    workouts: int
    sleep_sessions: int
    rejected_records: int
    policy_version: str = HEALTHKIT_POLICY_VERSION


@dataclass(frozen=True, slots=True)
class FitnessHabitPolicy:
    version: str = HEALTHKIT_POLICY_VERSION
    workout_window_days: int = 42
    workout_min_sessions: int = 4
    workout_min_distinct_weeks: int = 3
    daypart_min_sessions: int = 6
    daypart_min_distinct_weeks: int = 3
    daypart_min_concentration: float = 0.70

    def __post_init__(self) -> None:
        if self.version != HEALTHKIT_POLICY_VERSION:
            raise ValueError("unsupported_healthkit_policy_version")
        integer_values = (
            self.workout_window_days,
            self.workout_min_sessions,
            self.workout_min_distinct_weeks,
            self.daypart_min_sessions,
            self.daypart_min_distinct_weeks,
        )
        if any(type(value) is not int or value < 1 for value in integer_values):
            raise ValueError("invalid_healthkit_integer_threshold")
        if (
            isinstance(self.daypart_min_concentration, bool)
            or not isinstance(self.daypart_min_concentration, (int, float))
            or not math.isfinite(self.daypart_min_concentration)
            or not 0.5 <= self.daypart_min_concentration <= 1.0
        ):
            raise ValueError("invalid_healthkit_daypart_threshold")
        if (
            self.workout_window_days,
            self.workout_min_sessions,
            self.workout_min_distinct_weeks,
            self.daypart_min_sessions,
            self.daypart_min_distinct_weeks,
            float(self.daypart_min_concentration),
        ) != (42, 4, 3, 6, 3, 0.70):
            raise ValueError("healthkit_policy_parameters_do_not_match_version")


@dataclass(frozen=True, slots=True)
class FitnessHabitCandidate:
    key: str
    kind: FitnessCandidateKind
    concept_key: str
    label: str
    predicate: str
    support_record_ids: tuple[str, ...]
    last_supported_at: datetime
    distinct_days: int
    distinct_weeks: int
    mapping_agreement: float
    evidence_quality: float
    policy_version: str
    data_use_purpose: str = "fitness_connection"
    requires_user_review: bool = True

    def __post_init__(self) -> None:
        if self.data_use_purpose != "fitness_connection":
            raise ValueError("fitness_candidate_has_invalid_purpose")
        if (
            not isinstance(self.support_record_ids, tuple)
            or not self.support_record_ids
            or len(self.support_record_ids) != len(set(self.support_record_ids))
            or any(
                not isinstance(value, str)
                or re.fullmatch(r"[0-9a-f]{24}", value) is None
                for value in self.support_record_ids
            )
        ):
            raise ValueError("fitness_candidate_requires_support")
        if re.fullmatch(r"[0-9a-f]{24}", self.key) is None:
            raise ValueError("fitness_candidate_requires_stable_identity")
        if self.last_supported_at.tzinfo is None:
            raise ValueError("fitness_candidate_requires_timezone")
        if self.predicate != "routine":
            raise ValueError("fitness_candidate_predicate_not_licensed")
        if self.requires_user_review is not True:
            raise ValueError("fitness_candidate_requires_user_review")
        if self.policy_version != HEALTHKIT_POLICY_VERSION:
            raise ValueError("fitness_candidate_policy_not_licensed")
        for value in (self.distinct_days, self.distinct_weeks):
            if type(value) is not int or value < 1:
                raise ValueError("fitness_candidate_has_invalid_counts")
        if (
            self.distinct_days > len(self.support_record_ids)
            or self.distinct_weeks > self.distinct_days
        ):
            raise ValueError("fitness_candidate_counts_exceed_support")
        if self.kind is FitnessCandidateKind.ACTIVITY_ROUTINE:
            expected_label = _ACTIVITY_CONCEPT_LABELS.get(self.concept_key)
        elif self.kind is FitnessCandidateKind.WORKOUT_DAYPART:
            expected_label = _DAYPART_ROUTINE_LABELS.get(self.concept_key)
        else:  # Defensive for future enum expansion.
            expected_label = None
        if expected_label is None or self.label != expected_label:
            raise ValueError("fitness_candidate_concept_or_label_not_licensed")
        for value in (self.mapping_agreement, self.evidence_quality):
            if (
                isinstance(value, bool)
                or not isinstance(value, (int, float))
                or not math.isfinite(value)
            ):
                raise ValueError("fitness_candidate_has_invalid_quality")
            if not 0.0 <= value <= 1.0:
                raise ValueError("fitness_candidate_quality_out_of_bounds")
        if self.kind is FitnessCandidateKind.ACTIVITY_ROUTINE and (
            len(self.support_record_ids) < 4 or self.distinct_weeks < 3
        ):
            raise ValueError("fitness_activity_candidate_below_threshold")
        if self.kind is FitnessCandidateKind.WORKOUT_DAYPART and (
            len(self.support_record_ids) < 6
            or self.distinct_weeks < 3
            or self.evidence_quality < 0.70
        ):
            raise ValueError("fitness_daypart_candidate_below_threshold")


@dataclass(frozen=True, slots=True)
class HealthKitIngestionResult:
    records: tuple[HealthKitRecord, ...]
    coverage: HealthKitCoverage
    excluded_counts: dict[str, int]


# Provider activity identifiers are normalized before lookup.  This is a
# deliberately closed list; aliases can be extended only with tests and a
# version bump.  Free-text workout names never nominate an activity.
_ACTIVITY_TYPES: dict[str, tuple[str, str]] = {
    "running": ("activity:running", "Running"),
    "run": ("activity:running", "Running"),
    "walking": ("activity:walking", "Walking"),
    "walk": ("activity:walking", "Walking"),
    "cycling": ("activity:cycling", "Cycling"),
    "biking": ("activity:cycling", "Cycling"),
    "swimming": ("activity:swimming", "Swimming"),
    "hiking": ("activity:hiking", "Hiking"),
    "strength training": ("activity:strength_training", "Strength training"),
    "traditional strength training": (
        "activity:strength_training",
        "Strength training",
    ),
    "functional strength training": (
        "activity:strength_training",
        "Strength training",
    ),
    "yoga": ("activity:yoga", "Yoga"),
    "pilates": ("activity:pilates", "Pilates"),
    "dance": ("activity:dance", "Dance"),
    "high intensity interval training": ("activity:hiit", "HIIT"),
    "hiit": ("activity:hiit", "HIIT"),
    "rowing": ("activity:rowing", "Rowing"),
    "elliptical": ("activity:elliptical", "Elliptical training"),
    "climbing": ("activity:climbing", "Climbing"),
    "tennis": ("activity:tennis", "Tennis"),
    "pickleball": ("activity:pickleball", "Pickleball"),
    "basketball": ("activity:basketball", "Basketball"),
    "soccer": ("activity:soccer", "Soccer"),
    "skiing": ("activity:skiing", "Skiing"),
    "snowboarding": ("activity:snowboarding", "Snowboarding"),
}

_ACTIVITY_CONCEPT_LABELS = {
    concept_key: label for concept_key, label in _ACTIVITY_TYPES.values()
}
_DAYPART_ROUTINE_LABELS = {
    f"routine:{daypart}_workouts": f"{daypart.title()} workouts"
    for daypart in ("morning", "afternoon", "evening", "overnight")
}
_SLEEP_STAGES = frozenset(
    {"asleep", "core", "deep", "rem", "unspecified", "in bed"}
)


def canonical_healthkit_source(value: str) -> str:
    token = "_".join(normalize_text(value).split())
    return "healthkit" if token in HEALTHKIT_SOURCE_ALIASES else token


def _finite_number(
    value: object,
    *,
    minimum: float,
    maximum: float,
    integer: bool = False,
) -> float | int | None:
    if value is None or isinstance(value, bool):
        return None
    try:
        parsed = float(str(value).strip())
    except (TypeError, ValueError):
        return None
    if not math.isfinite(parsed) or not minimum <= parsed <= maximum:
        return None
    if integer:
        if not parsed.is_integer():
            return None
        return int(parsed)
    return parsed


def _datetime(value: object) -> datetime | None:
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        parsed = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        return None
    return parsed


def _date(value: object) -> date | None:
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        return date.fromisoformat(value.strip()[:10])
    except ValueError:
        return None


def _record(
    *,
    row: Mapping[str, str],
    kind: HealthKitRecordKind,
    occurred_at: datetime | None,
    values: Mapping[str, float | int | str],
    activity: tuple[str, str] | None = None,
) -> HealthKitRecord | None:
    canonical_values = tuple(sorted(values.items()))
    provider_item_id = row.get("item_id", "").strip()
    if provider_item_id:
        source_item_fingerprint = stable_hash(
            "healthkit-source-item",
            kind.value,
            provider_item_id,
        )
    elif kind is HealthKitRecordKind.ACTIVITY_DAY:
        # The legacy daily aggregate contract has one typed bin per ISO date.
        # This is a bounded structural fallback, not a payload-derived identity.
        source_item_fingerprint = stable_hash(
            "healthkit-source-item-fallback",
            kind.value,
            values["date"],
        )
    elif kind is HealthKitRecordKind.ACTIVITY_HOUR:
        # Legacy hourly rows represent one coarse 24-bin snapshot. Without a
        # provider ID, the hour is the only safe bin identity; later snapshots
        # must use a versioned contract with a provider ID/date rather than be
        # merged here.
        source_item_fingerprint = stable_hash(
            "healthkit-source-item-fallback",
            kind.value,
            values["hour"],
        )
    else:
        # Workout/sleep recurrence must never fall back to mutable timestamps or
        # values: doing so lets revisions or mirrors manufacture sessions.
        return None
    record_fingerprint = stable_hash(
        "healthkit-record-revision",
        kind.value,
        source_item_fingerprint,
        occurred_at.isoformat() if occurred_at else "",
        canonical_values,
    )
    return HealthKitRecord(
        record_id=record_fingerprint[:24],
        kind=kind,
        occurred_at=occurred_at,
        record_fingerprint=record_fingerprint,
        source_item_fingerprint=source_item_fingerprint,
        activity_concept_key=activity[0] if activity else None,
        activity_label=activity[1] if activity else None,
        controlled_values=canonical_values,
    )


def _parse_activity_day(
    row: Mapping[str, str], extra: Mapping[str, str]
) -> HealthKitRecord | None:
    day = _date(extra.get("date") or row.get("item_id") or row.get("name"))
    if day is None:
        return None
    values: dict[str, float | int | str] = {"date": day.isoformat()}
    steps = _finite_number(extra.get("steps"), minimum=0, maximum=200_000, integer=True)
    active_kcal = _finite_number(
        extra.get("active_kcal"), minimum=0, maximum=10_000
    )
    first_move = (extra.get("first_move") or "").strip()
    if steps is not None:
        values["steps"] = steps
    if active_kcal is not None:
        values["active_kcal"] = round(float(active_kcal), 3)
    if first_move and _TIME.fullmatch(first_move):
        values["first_move"] = first_move[:5]
    if len(values) == 1:
        return None
    occurrence = datetime.combine(day, datetime.min.time(), tzinfo=timezone.utc)
    return _record(
        row=row,
        kind=HealthKitRecordKind.ACTIVITY_DAY,
        occurred_at=occurrence,
        values=values,
    )


def _parse_activity_hour(
    row: Mapping[str, str], extra: Mapping[str, str]
) -> HealthKitRecord | None:
    hour = _finite_number(extra.get("hour"), minimum=0, maximum=23, integer=True)
    steps = _finite_number(extra.get("steps"), minimum=0, maximum=20_000_000, integer=True)
    share = _finite_number(extra.get("share"), minimum=0, maximum=1)
    if hour is None or (steps is None and share is None):
        return None
    values: dict[str, float | int | str] = {"hour": hour}
    if steps is not None:
        values["steps"] = steps
    if share is not None:
        values["share"] = round(float(share), 8)
    return _record(
        row=row,
        kind=HealthKitRecordKind.ACTIVITY_HOUR,
        occurred_at=None,
        values=values,
    )


def _parse_workout(
    row: Mapping[str, str], extra: Mapping[str, str]
) -> HealthKitRecord | None:
    raw_activity = normalize_text(
        extra.get("activity_type") or extra.get("workout_type") or ""
    )
    activity = _ACTIVITY_TYPES.get(raw_activity)
    start = _datetime(extra.get("start") or extra.get("start_at"))
    end = _datetime(extra.get("end") or extra.get("end_at"))
    duration = _finite_number(
        extra.get("duration_min"), minimum=1, maximum=1_440
    )
    if duration is None and start is not None and end is not None and end > start:
        duration = (end - start).total_seconds() / 60.0
    if (
        activity is None
        or start is None
        or duration is None
        or not 1 <= float(duration) <= 1_440
    ):
        return None
    values: dict[str, float | int | str] = {
        "activity_type": activity[0],
        "duration_min": round(float(duration), 2),
    }
    return _record(
        row=row,
        kind=HealthKitRecordKind.WORKOUT,
        occurred_at=start,
        values=values,
        activity=activity,
    )


def _parse_sleep(
    row: Mapping[str, str], extra: Mapping[str, str]
) -> HealthKitRecord | None:
    stage = normalize_text(extra.get("stage") or extra.get("sleep_stage") or "asleep")
    start = _datetime(extra.get("start") or extra.get("start_at"))
    end = _datetime(extra.get("end") or extra.get("end_at"))
    if stage not in _SLEEP_STAGES or start is None or end is None or end <= start:
        return None
    duration = (end - start).total_seconds() / 60.0
    if not 30.0 <= duration <= 1_440.0:
        return None
    return _record(
        row=row,
        kind=HealthKitRecordKind.SLEEP_SESSION,
        occurred_at=start,
        values={
            "stage": stage,
            "duration_min": round(duration, 2),
            "start_minute_local": start.hour * 60 + start.minute,
        },
    )


def ingest_healthkit_rows(rows: Iterable[Mapping[str, str]]) -> HealthKitIngestionResult:
    """Parse HealthKit aliases into one canonical private quantitative lane."""

    accepted_by_lineage: dict[str, HealthKitRecord] = {}
    conflicted_lineages: set[str] = set()
    excluded: Counter[str] = Counter()
    parser_by_type = {
        "activity_day": _parse_activity_day,
        "activity_hour": _parse_activity_hour,
        "workout": _parse_workout,
        "sleep": _parse_sleep,
        "sleep_session": _parse_sleep,
    }
    for row in rows:
        source = canonical_healthkit_source(row.get("source", ""))
        if source != "healthkit":
            continue
        extra = parse_semicolon_kv(row.get("extra", ""))
        if "removed_by_user" in extra:
            excluded["user_removed_healthkit_record"] += 1
            continue
        data_type = "_".join(normalize_text(row.get("data_type", "")).split())
        parser = parser_by_type.get(data_type)
        if parser is None:
            excluded["unsupported_healthkit_data_type"] += 1
            continue
        if data_type in {"workout", "sleep", "sleep_session"} and not row.get(
            "item_id", ""
        ).strip():
            excluded["missing_healthkit_source_item_identity"] += 1
            continue
        record = parser(row, extra)
        if record is None:
            excluded[f"malformed_healthkit_{data_type}"] += 1
            continue
        lineage = record.source_item_fingerprint
        if lineage in conflicted_lineages:
            excluded["conflicting_healthkit_item_revision"] += 1
            continue
        previous = accepted_by_lineage.get(lineage)
        if previous is None:
            accepted_by_lineage[lineage] = record
            continue
        if previous.record_fingerprint == record.record_fingerprint:
            excluded["duplicate_healthkit_record"] += 1
            continue
        # With no trustworthy revision/etag ordering in the legacy row shape,
        # choosing either payload would be arbitrary. Quarantine every typed
        # revision for that provider item; the encrypted raw vault is unaffected.
        del accepted_by_lineage[lineage]
        conflicted_lineages.add(lineage)
        excluded["conflicting_healthkit_item_revision"] += 2

    accepted = list(accepted_by_lineage.values())

    # Hour rows form one coarse distribution snapshot in the legacy contract.
    # Distinct raw records that claim the same bin are ambiguous, so none of
    # those colliding bins enters the typed feature lane. The raw vault remains
    # unaffected and can be reprocessed under a later, better-typed contract.
    hour_groups: dict[int, list[HealthKitRecord]] = defaultdict(list)
    for record in accepted:
        if record.kind is HealthKitRecordKind.ACTIVITY_HOUR:
            hour_groups[int(record.values["hour"])].append(record)
    colliding_hour_ids = {
        record.record_id
        for records in hour_groups.values()
        if len(records) > 1
        for record in records
    }
    if colliding_hour_ids:
        accepted = [
            record for record in accepted if record.record_id not in colliding_hour_ids
        ]
        excluded["duplicate_healthkit_hour_bin"] += len(colliding_hour_ids)

    # When a complete 24-bin share distribution is supplied, require it to be
    # approximately normalized. Partial snapshots and steps-only bins remain
    # usable for coverage, but an internally incoherent complete distribution
    # does not become a typed timing feature.
    hourly = [
        record
        for record in accepted
        if record.kind is HealthKitRecordKind.ACTIVITY_HOUR
    ]
    is_complete_share_snapshot = (
        len(hourly) == 24
        and {int(record.values["hour"]) for record in hourly} == set(range(24))
        and all("share" in record.values for record in hourly)
    )
    if is_complete_share_snapshot:
        total_share = sum(float(record.values["share"]) for record in hourly)
        if not 0.98 <= total_share <= 1.02:
            invalid_ids = {record.record_id for record in hourly}
            accepted = [
                record for record in accepted if record.record_id not in invalid_ids
            ]
            excluded["incoherent_healthkit_hour_share_snapshot"] += len(invalid_ids)

    counts = Counter(record.kind for record in accepted)
    has_workout = counts[HealthKitRecordKind.WORKOUT] > 0
    has_sleep = counts[HealthKitRecordKind.SLEEP_SESSION] > 0
    has_aggregate = (
        counts[HealthKitRecordKind.ACTIVITY_DAY]
        + counts[HealthKitRecordKind.ACTIVITY_HOUR]
        > 0
    )
    if not accepted:
        state = HealthKitCoverageState.EMPTY
    elif has_workout and (has_sleep or has_aggregate):
        state = HealthKitCoverageState.MIXED
    elif has_sleep and has_aggregate:
        state = HealthKitCoverageState.MIXED
    elif has_workout:
        state = HealthKitCoverageState.WORKOUT_TYPED
    elif has_sleep:
        state = HealthKitCoverageState.SLEEP_TYPED
    else:
        state = HealthKitCoverageState.AGGREGATE_ONLY
    coverage = HealthKitCoverage(
        state=state,
        accepted_records=len(accepted),
        activity_days=counts[HealthKitRecordKind.ACTIVITY_DAY],
        activity_hours=counts[HealthKitRecordKind.ACTIVITY_HOUR],
        workouts=counts[HealthKitRecordKind.WORKOUT],
        sleep_sessions=counts[HealthKitRecordKind.SLEEP_SESSION],
        rejected_records=sum(excluded.values()),
    )
    return HealthKitIngestionResult(
        records=tuple(accepted),
        coverage=coverage,
        excluded_counts=dict(sorted(excluded.items())),
    )


def _iso_week(value: datetime) -> tuple[int, int]:
    result = value.date().isocalendar()
    return result.year, result.week


def _daypart(value: datetime) -> str:
    hour = value.hour
    if 5 <= hour < 12:
        return "morning"
    if 12 <= hour < 18:
        return "afternoon"
    if 18 <= hour < 24:
        return "evening"
    return "overnight"


class FitnessHabitBuilder:
    """Derive reviewable habits without converting one sample into identity."""

    def __init__(self, policy: FitnessHabitPolicy | None = None) -> None:
        self.policy = policy or FitnessHabitPolicy()

    def derive(
        self,
        records: Sequence[HealthKitRecord],
        *,
        as_of: datetime | None = None,
    ) -> tuple[FitnessHabitCandidate, ...]:
        if any(not isinstance(record, HealthKitRecord) for record in records):
            raise TypeError("fitness_builder_requires_healthkit_records")
        # Ingestion normally resolves provider-item revisions before this
        # boundary, but callers may combine typed results from multiple runs.
        # Re-apply the stable-lineage rule here so cross-run mirrors/revisions
        # cannot manufacture recurrence. Exact repeated revisions count once;
        # an ambiguous lineage contributes no typed session at all.
        records_by_lineage: dict[str, HealthKitRecord] = {}
        conflicted_lineages: set[str] = set()
        for record in records:
            lineage = record.source_item_fingerprint
            if lineage in conflicted_lineages:
                continue
            previous = records_by_lineage.get(lineage)
            if previous is None:
                records_by_lineage[lineage] = record
            elif previous.record_fingerprint != record.record_fingerprint:
                del records_by_lineage[lineage]
                conflicted_lineages.add(lineage)
        records = tuple(records_by_lineage.values())
        timestamps = [
            record.occurred_at
            for record in records
            if record.occurred_at is not None
        ]
        reference = as_of or (max(timestamps) if timestamps else None)
        if reference is None:
            return ()
        candidates: list[FitnessHabitCandidate] = []
        candidates.extend(self._activity_routines(records, reference))
        daypart = self._workout_daypart(records, reference)
        if daypart is not None:
            candidates.append(daypart)
        return tuple(sorted(candidates, key=lambda item: (item.kind.value, item.key)))

    def _activity_routines(
        self,
        records: Sequence[HealthKitRecord],
        reference: datetime,
    ) -> list[FitnessHabitCandidate]:
        start = reference - timedelta(days=self.policy.workout_window_days)
        grouped: dict[str, list[HealthKitRecord]] = defaultdict(list)
        for record in records:
            if (
                record.kind is HealthKitRecordKind.WORKOUT
                and record.occurred_at is not None
                and start <= record.occurred_at <= reference
                and record.activity_concept_key
            ):
                grouped[record.activity_concept_key].append(record)
        candidates: list[FitnessHabitCandidate] = []
        for concept_key, items in grouped.items():
            days = {item.occurred_at.date() for item in items if item.occurred_at}
            weeks = {_iso_week(item.occurred_at) for item in items if item.occurred_at}
            if (
                len(items) < self.policy.workout_min_sessions
                or len(weeks) < self.policy.workout_min_distinct_weeks
            ):
                continue
            label = items[0].activity_label or concept_key
            support = tuple(sorted(item.record_id for item in items))
            candidates.append(
                FitnessHabitCandidate(
                    key=stable_hash("fitness-routine", concept_key, support)[:24],
                    kind=FitnessCandidateKind.ACTIVITY_ROUTINE,
                    concept_key=concept_key,
                    label=label,
                    predicate="routine",
                    support_record_ids=support,
                    last_supported_at=max(
                        item.occurred_at for item in items if item.occurred_at
                    ),
                    distinct_days=len(days),
                    distinct_weeks=len(weeks),
                    mapping_agreement=1.0,
                    evidence_quality=min(1.0, 0.65 + 0.05 * len(weeks)),
                    policy_version=self.policy.version,
                )
            )
        return candidates

    def _workout_daypart(
        self,
        records: Sequence[HealthKitRecord],
        reference: datetime,
    ) -> FitnessHabitCandidate | None:
        start = reference - timedelta(days=self.policy.workout_window_days)
        workouts = [
            record
            for record in records
            if record.kind is HealthKitRecordKind.WORKOUT
            and record.occurred_at is not None
            and start <= record.occurred_at <= reference
        ]
        weeks = {_iso_week(item.occurred_at) for item in workouts if item.occurred_at}
        if (
            len(workouts) < self.policy.daypart_min_sessions
            or len(weeks) < self.policy.daypart_min_distinct_weeks
        ):
            return None
        counts = Counter(_daypart(item.occurred_at) for item in workouts if item.occurred_at)
        daypart, count = max(counts.items(), key=lambda item: (item[1], item[0]))
        concentration = count / len(workouts)
        if concentration < self.policy.daypart_min_concentration:
            return None
        supporting = tuple(
            sorted(
                item.record_id
                for item in workouts
                if item.occurred_at and _daypart(item.occurred_at) == daypart
            )
        )
        supporting_records = [
            item
            for item in workouts
            if item.occurred_at and _daypart(item.occurred_at) == daypart
        ]
        supporting_weeks = {
            _iso_week(item.occurred_at)
            for item in supporting_records
            if item.occurred_at
        }
        if len(supporting_weeks) < self.policy.daypart_min_distinct_weeks:
            return None
        # Preserve the full typed denominator so concentration is auditable;
        # the dominant subset alone cannot prove the 70% gate.
        all_workout_support = tuple(sorted(item.record_id for item in workouts))
        return FitnessHabitCandidate(
            key=stable_hash("fitness-daypart", daypart, all_workout_support)[:24],
            kind=FitnessCandidateKind.WORKOUT_DAYPART,
            concept_key=f"routine:{daypart}_workouts",
            label=f"{daypart.title()} workouts",
            predicate="routine",
            support_record_ids=all_workout_support,
            last_supported_at=max(
                item.occurred_at
                for item in workouts
                if item.occurred_at and _daypart(item.occurred_at) == daypart
            ),
            distinct_days=len(
                {
                    item.occurred_at.date()
                    for item in workouts
                    if item.occurred_at and _daypart(item.occurred_at) == daypart
                }
            ),
            distinct_weeks=len(supporting_weeks),
            mapping_agreement=1.0,
            evidence_quality=round(concentration, 6),
            policy_version=self.policy.version,
        )

def fitness_candidate_observation(candidate: FitnessHabitCandidate):
    """Project a validated candidate into a sanitized mapper observation.

    The delayed import avoids a models/adapter cycle.  This projection carries
    only a controlled label and policy metadata; supporting Health values stay
    in the private feature lane.
    """

    from .models import Observation, Term

    fingerprint = stable_hash(
        "healthkit-fitness-candidate",
        candidate.key,
        candidate.policy_version,
    )
    return Observation(
        id=fingerprint[:24],
        source="healthkit",
        data_type="fitness_habit",
        action="routine",
        evidence_channel="fitness",
        independence_group="fitness",
        occurred_at=candidate.last_supported_at,
        collected_at=candidate.last_supported_at,
        terms=(
            Term(
                text=candidate.label,
                normalized=normalize_text(candidate.label),
                role="validated_fitness_habit",
                source_field="fitness_habit_candidate.controlled_label",
                type_hint="activity",
                safe_for_online=False,
                safe_for_global_mining=False,
            ),
        ),
        record_fingerprint=fingerprint,
        content_lineage=stable_hash("healthkit-fitness-family", candidate.key),
        field_quality=candidate.evidence_quality,
        action_weight=0.85,
        privacy_class="private_fitness_sanitized",
        allow_external_resolution=False,
        metadata={
            "candidate_id": candidate.key,
            "candidate_kind": candidate.kind.value,
            "controlled_label": candidate.label,
            "predicate": candidate.predicate,
            "purpose_scope": candidate.data_use_purpose,
            "policy_version": candidate.policy_version,
            "requires_user_review": candidate.requires_user_review,
            # Purpose-aware surfaces compare validated fitness facts directly.
            # Generic breadth/synergy/convergence has no data-use-purpose axis,
            # so HealthKit must remain excluded from that path.
            "cross_source_fusion_approved": False,
        },
    )


__all__ = [
    "FitnessCandidateKind",
    "FitnessHabitBuilder",
    "FitnessHabitCandidate",
    "FitnessHabitPolicy",
    "HEALTHKIT_POLICY_VERSION",
    "HEALTHKIT_SOURCE_ALIASES",
    "HealthKitCoverage",
    "HealthKitCoverageState",
    "HealthKitIngestionResult",
    "HealthKitRecord",
    "HealthKitRecordKind",
    "canonical_healthkit_source",
    "fitness_candidate_observation",
    "ingest_healthkit_rows",
]
