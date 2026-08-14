"""Deterministic, versioned recency policy for semantic evidence.

Recency is a ranking feature, not a claim about a person and not a learned
probability.  The hand-authored rules are deliberately keyed by all three of
domain, source, and action.  This prevents a connector-wide half-life from
treating a transient watch like an enduring subscription or library save.

Scheduled events use a different clock: they gain relevance inside an
anticipation window, peak at the event, and decay after it.  Missing
timestamps remain usable at explicitly reduced weight and quality.  Exact
timestamps are never copied into the evidence explanation step.
"""

from __future__ import annotations

import math
import re
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import datetime
from enum import StrEnum
from types import MappingProxyType


RECENCY_POLICY_VERSION = "written-recency-v1.0.0"
_SAFE_IDENTIFIER = re.compile(r"^[a-z0-9][a-z0-9._:-]{0,127}$")


class RecencyMode(StrEnum):
    HISTORICAL = "historical_decay"
    SCHEDULED = "scheduled_anticipation"


class TemporalStatus(StrEnum):
    UNKNOWN_TIMESTAMP = "unknown_timestamp"
    RECENT = "recent"
    DECAYING = "decaying"
    FUTURE_CLOCK_SKEW = "future_clock_skew"
    FUTURE_OUTSIDE_WINDOW = "future_outside_anticipation_window"
    FUTURE_ANTICIPATION = "future_anticipation"
    EVENT_CURRENT = "event_current"
    POST_EVENT_DECAY = "post_event_decay"
    EXPIRED = "expired"


class TimestampQuality(StrEnum):
    KNOWN = "known"
    UNKNOWN = "unknown"


class RecencyPolicyError(ValueError):
    """Safe policy failure; the message never contains source payload data."""

    def __init__(self, code: str) -> None:
        self.code = code
        super().__init__(code)


@dataclass(frozen=True, slots=True, order=True)
class RecencyKey:
    domain: str
    source: str
    action: str

    def __post_init__(self) -> None:
        if not all(
            isinstance(value, str) and _SAFE_IDENTIFIER.fullmatch(value)
            for value in (self.domain, self.source, self.action)
        ):
            raise ValueError("invalid_recency_key")


@dataclass(frozen=True, slots=True)
class RecencyRule:
    """One interpretable curve shared by explicitly registered keys.

    ``half_life_days`` halves the weight *above the minimum floor*.  The floor
    prevents underflow from silently converting old evidence into a hard
    negative.  ``expiry_days`` switches to that floor exactly at its boundary.
    """

    rule_id: str
    mode: RecencyMode
    half_life_days: float
    peak_weight: float
    minimum_weight: float
    unknown_timestamp_weight: float
    unknown_timestamp_quality: float
    freshness_window_days: float
    expiry_days: float | None = None
    anticipation_window_days: float | None = None

    def __post_init__(self) -> None:
        if not isinstance(self.rule_id, str) or not _SAFE_IDENTIFIER.fullmatch(
            self.rule_id
        ):
            raise ValueError("invalid_recency_rule_id")
        if not isinstance(self.mode, RecencyMode):
            raise ValueError("invalid_recency_mode")
        positive = (self.half_life_days, self.freshness_window_days)
        bounded = (
            self.peak_weight,
            self.minimum_weight,
            self.unknown_timestamp_weight,
            self.unknown_timestamp_quality,
        )
        if any(
            not isinstance(value, (int, float))
            or isinstance(value, bool)
            or not math.isfinite(value)
            or value <= 0.0
            for value in positive
        ):
            raise ValueError("recency_days_must_be_finite_and_positive")
        if any(
            not isinstance(value, (int, float))
            or isinstance(value, bool)
            or not math.isfinite(value)
            or not 0.0 < value <= 1.0
            for value in bounded
        ):
            raise ValueError("recency_weights_must_be_finite_in_open_unit_interval")
        if not (
            self.minimum_weight
            <= self.unknown_timestamp_weight
            < self.peak_weight
            and self.minimum_weight < self.peak_weight
            and self.unknown_timestamp_quality < 1.0
        ):
            raise ValueError("invalid_recency_weight_order")
        for value in (self.expiry_days, self.anticipation_window_days):
            if value is not None and (
                not isinstance(value, (int, float))
                or isinstance(value, bool)
                or not math.isfinite(value)
                or value <= 0.0
            ):
                raise ValueError("optional_recency_days_must_be_positive")
        if self.expiry_days is not None and self.expiry_days <= self.freshness_window_days:
            raise ValueError("recency_expiry_must_follow_freshness_window")
        if (
            self.mode is RecencyMode.SCHEDULED
            and self.anticipation_window_days is None
        ):
            raise ValueError("scheduled_rule_requires_anticipation_window")
        if (
            self.mode is RecencyMode.HISTORICAL
            and self.anticipation_window_days is not None
        ):
            raise ValueError("historical_rule_cannot_have_anticipation_window")


@dataclass(frozen=True, slots=True)
class RecencyDecision:
    weight: float
    timestamp_quality_weight: float
    policy_version: str
    rule_id: str
    mode: RecencyMode
    temporal_status: TemporalStatus
    timestamp_quality: TimestampQuality
    half_life_days: float
    minimum_weight: float
    anticipation_window_days: float | None
    expiry_days: float | None

    def __post_init__(self) -> None:
        if (
            not isinstance(self.weight, (int, float))
            or isinstance(self.weight, bool)
            or not math.isfinite(self.weight)
            or not 0.0 < self.weight <= 1.0
            or not isinstance(self.timestamp_quality_weight, (int, float))
            or isinstance(self.timestamp_quality_weight, bool)
            or not math.isfinite(self.timestamp_quality_weight)
            or not 0.0 < self.timestamp_quality_weight <= 1.0
        ):
            raise ValueError("invalid_recency_decision")

    def evidence_step(self) -> dict[str, object]:
        """Return sanitized, sufficient provenance without an exact timestamp."""

        step: dict[str, object] = {
            "step": "recency_policy",
            "policy_version": self.policy_version,
            "rule_id": self.rule_id,
            "mode": self.mode.value,
            "temporal_status": self.temporal_status.value,
            "timestamp_quality": self.timestamp_quality.value,
            "recency_weight": self.weight,
            "timestamp_quality_weight": self.timestamp_quality_weight,
            "half_life_days": self.half_life_days,
            "minimum_weight": self.minimum_weight,
        }
        if self.anticipation_window_days is not None:
            step["anticipation_window_days"] = self.anticipation_window_days
        if self.expiry_days is not None:
            step["expiry_days"] = self.expiry_days
        return step


@dataclass(frozen=True, slots=True)
class RecencyPolicy:
    version: str
    rules: Mapping[RecencyKey, RecencyRule]
    future_clock_skew_hours: float = 24.0

    def __post_init__(self) -> None:
        if not isinstance(self.version, str) or not _SAFE_IDENTIFIER.fullmatch(
            self.version
        ):
            raise ValueError("invalid_recency_policy_version")
        if (
            not isinstance(self.future_clock_skew_hours, (int, float))
            or isinstance(self.future_clock_skew_hours, bool)
            or not math.isfinite(self.future_clock_skew_hours)
            or not 0.0 <= self.future_clock_skew_hours <= 72.0
        ):
            raise ValueError("invalid_future_clock_skew_hours")
        copied: dict[RecencyKey, RecencyRule] = {}
        for key, rule in self.rules.items():
            if not isinstance(key, RecencyKey) or not isinstance(rule, RecencyRule):
                raise ValueError("invalid_recency_policy_rule")
            if key in copied:
                raise ValueError("duplicate_recency_policy_rule")
            copied[key] = rule
        if not copied:
            raise ValueError("recency_policy_requires_rules")
        object.__setattr__(self, "rules", MappingProxyType(copied))

    @property
    def supported_keys(self) -> tuple[RecencyKey, ...]:
        return tuple(sorted(self.rules))

    def rule_for(self, *, domain: str, source: str, action: str) -> RecencyRule:
        try:
            key = RecencyKey(domain=domain, source=source, action=action)
        except ValueError as error:
            raise RecencyPolicyError("invalid_recency_key") from error
        rule = self.rules.get(key)
        if rule is None:
            raise RecencyPolicyError("unsupported_recency_key")
        return rule

    @staticmethod
    def _validate_datetime(value: object, *, field: str) -> datetime:
        if not isinstance(value, datetime) or value.tzinfo is None:
            raise RecencyPolicyError(f"invalid_{field}")
        try:
            offset = value.utcoffset()
        except (OverflowError, TypeError, ValueError) as error:
            raise RecencyPolicyError(f"invalid_{field}") from error
        if offset is None:
            raise RecencyPolicyError(f"invalid_{field}")
        return value

    @staticmethod
    def _decayed_weight(rule: RecencyRule, age_days: float) -> float:
        excess = rule.peak_weight - rule.minimum_weight
        value = rule.minimum_weight + excess * math.exp(
            -math.log(2.0) * age_days / rule.half_life_days
        )
        return min(rule.peak_weight, max(rule.minimum_weight, value))

    def evaluate(
        self,
        *,
        domain: str,
        source: str,
        action: str,
        occurred_at: datetime | None,
        as_of: datetime,
    ) -> RecencyDecision:
        """Evaluate one timestamp without reading source payload or wall clock."""

        rule = self.rule_for(domain=domain, source=source, action=action)
        reference = self._validate_datetime(as_of, field="as_of")
        if occurred_at is None:
            return self._decision(
                rule,
                weight=rule.unknown_timestamp_weight,
                quality=rule.unknown_timestamp_quality,
                status=TemporalStatus.UNKNOWN_TIMESTAMP,
                timestamp_quality=TimestampQuality.UNKNOWN,
            )
        occurrence = self._validate_datetime(occurred_at, field="occurred_at")
        try:
            signed_age_days = (
                reference - occurrence
            ).total_seconds() / 86_400.0
        except (OverflowError, TypeError, ValueError) as error:
            raise RecencyPolicyError("invalid_timestamp_difference") from error

        if rule.mode is RecencyMode.SCHEDULED:
            return self._evaluate_scheduled(rule, signed_age_days)
        return self._evaluate_historical(rule, signed_age_days)

    def _evaluate_historical(
        self,
        rule: RecencyRule,
        signed_age_days: float,
    ) -> RecencyDecision:
        tolerance_days = self.future_clock_skew_hours / 24.0
        if signed_age_days < -tolerance_days:
            raise RecencyPolicyError("future_timestamp_for_historical_action")
        if signed_age_days < 0.0:
            age_days = 0.0
            status = TemporalStatus.FUTURE_CLOCK_SKEW
        else:
            age_days = signed_age_days
            status = (
                TemporalStatus.RECENT
                if age_days <= rule.freshness_window_days
                else TemporalStatus.DECAYING
            )
        if rule.expiry_days is not None and age_days >= rule.expiry_days:
            weight = rule.minimum_weight
            status = TemporalStatus.EXPIRED
        else:
            weight = self._decayed_weight(rule, age_days)
        return self._decision(rule, weight=weight, quality=1.0, status=status)

    def _evaluate_scheduled(
        self,
        rule: RecencyRule,
        signed_age_days: float,
    ) -> RecencyDecision:
        anticipation = rule.anticipation_window_days
        if anticipation is None:  # protected by RecencyRule validation
            raise RecencyPolicyError("scheduled_rule_missing_anticipation_window")
        if signed_age_days < 0.0:
            days_until_event = -signed_age_days
            if days_until_event > anticipation:
                weight = rule.minimum_weight
                status = TemporalStatus.FUTURE_OUTSIDE_WINDOW
            else:
                # Linear anticipation is intentionally easy to audit: the
                # floor applies at the window boundary and the peak at zero.
                progress = 1.0 - days_until_event / anticipation
                weight = rule.minimum_weight + (
                    rule.peak_weight - rule.minimum_weight
                ) * progress
                status = TemporalStatus.FUTURE_ANTICIPATION
        elif signed_age_days == 0.0:
            weight = rule.peak_weight
            status = TemporalStatus.EVENT_CURRENT
        elif rule.expiry_days is not None and signed_age_days >= rule.expiry_days:
            weight = rule.minimum_weight
            status = TemporalStatus.EXPIRED
        else:
            weight = self._decayed_weight(rule, signed_age_days)
            status = TemporalStatus.POST_EVENT_DECAY
        return self._decision(rule, weight=weight, quality=1.0, status=status)

    def _decision(
        self,
        rule: RecencyRule,
        *,
        weight: float,
        quality: float,
        status: TemporalStatus,
        timestamp_quality: TimestampQuality = TimestampQuality.KNOWN,
    ) -> RecencyDecision:
        return RecencyDecision(
            weight=round(weight, 8),
            timestamp_quality_weight=quality,
            policy_version=self.version,
            rule_id=rule.rule_id,
            mode=rule.mode,
            temporal_status=status,
            timestamp_quality=timestamp_quality,
            half_life_days=rule.half_life_days,
            minimum_weight=rule.minimum_weight,
            anticipation_window_days=rule.anticipation_window_days,
            expiry_days=rule.expiry_days,
        )


def _historical(
    rule_id: str,
    *,
    half_life_days: float,
    peak_weight: float,
    minimum_weight: float,
    unknown_timestamp_weight: float,
    unknown_timestamp_quality: float,
    freshness_window_days: float,
    expiry_days: float | None,
) -> RecencyRule:
    return RecencyRule(
        rule_id=rule_id,
        mode=RecencyMode.HISTORICAL,
        half_life_days=half_life_days,
        peak_weight=peak_weight,
        minimum_weight=minimum_weight,
        unknown_timestamp_weight=unknown_timestamp_weight,
        unknown_timestamp_quality=unknown_timestamp_quality,
        freshness_window_days=freshness_window_days,
        expiry_days=expiry_days,
    )


VIDEO_LIKE = _historical(
    "video.like.recent",
    half_life_days=120.0,
    peak_weight=1.0,
    minimum_weight=0.12,
    unknown_timestamp_weight=0.48,
    unknown_timestamp_quality=0.65,
    freshness_window_days=14.0,
    expiry_days=1095.0,
)
VIDEO_EPHEMERAL = _historical(
    "video.behavior.ephemeral",
    half_life_days=30.0,
    peak_weight=0.90,
    minimum_weight=0.05,
    unknown_timestamp_weight=0.28,
    unknown_timestamp_quality=0.55,
    freshness_window_days=7.0,
    expiry_days=365.0,
)
VIDEO_SHARE = _historical(
    "video.share.medium",
    half_life_days=60.0,
    peak_weight=0.95,
    minimum_weight=0.08,
    unknown_timestamp_weight=0.38,
    unknown_timestamp_quality=0.60,
    freshness_window_days=14.0,
    expiry_days=730.0,
)
ENDURING_FOLLOW = _historical(
    "explicit.follow.enduring",
    half_life_days=1080.0,
    peak_weight=1.0,
    minimum_weight=0.30,
    unknown_timestamp_weight=0.72,
    unknown_timestamp_quality=0.75,
    freshness_window_days=30.0,
    expiry_days=3650.0,
)
ENDURING_LIBRARY = _historical(
    "library.save.enduring",
    half_life_days=1440.0,
    peak_weight=1.0,
    minimum_weight=0.28,
    unknown_timestamp_weight=0.70,
    unknown_timestamp_quality=0.75,
    freshness_window_days=90.0,
    expiry_days=3650.0,
)
ENDURING_RATING = _historical(
    "explicit.rating.enduring",
    half_life_days=900.0,
    peak_weight=1.0,
    minimum_weight=0.25,
    unknown_timestamp_weight=0.68,
    unknown_timestamp_quality=0.75,
    freshness_window_days=30.0,
    expiry_days=3650.0,
)
MUSIC_RECENT = _historical(
    "music.play.recent",
    half_life_days=120.0,
    peak_weight=0.90,
    minimum_weight=0.10,
    unknown_timestamp_weight=0.42,
    unknown_timestamp_quality=0.60,
    freshness_window_days=14.0,
    expiry_days=1095.0,
)
MUSIC_TOP = _historical(
    # **A ranking of a window, never an event, so it carries no timestamp at
    # all.** Spotify's `/me/top/*` returns a `medium_term` ordering — roughly six
    # months of actual listening — with no dates on it, and it is regenerated on
    # every distillation. So `unknown_timestamp_weight` is not a fallback here;
    # it is the only value this rule will ever produce, and the historical
    # parameters exist for the day the endpoint states a date rather than for
    # today.
    #
    # **0.70 rather than something higher, deliberately.** A top track is the
    # strongest listening signal any music source gives us, and
    # `SOURCE_ACTION_WEIGHTS` already says so — 0.78, above `saved_track`'s 0.60.
    # Recency answers *how stale is this*, not *how much does it mean*; raising
    # the weight here would encode the same judgement twice and neither copy
    # would say it was doing so. Matched to `ENDURING_LIBRARY` so recency stays
    # neutral between the two.
    "music.top.medium_term",
    half_life_days=180.0,
    peak_weight=0.95,
    minimum_weight=0.25,
    unknown_timestamp_weight=0.70,
    unknown_timestamp_quality=0.75,
    freshness_window_days=180.0,
    expiry_days=1095.0,
)
MUSIC_ADDED = _historical(
    "music.added.medium",
    half_life_days=540.0,
    peak_weight=0.95,
    minimum_weight=0.20,
    unknown_timestamp_weight=0.62,
    unknown_timestamp_quality=0.70,
    freshness_window_days=30.0,
    expiry_days=2555.0,
)
PODCAST_PLAY = _historical(
    "podcast.play.recent",
    half_life_days=180.0,
    peak_weight=0.90,
    minimum_weight=0.10,
    unknown_timestamp_weight=0.45,
    unknown_timestamp_quality=0.60,
    freshness_window_days=14.0,
    expiry_days=1095.0,
)
CALENDAR_SCHEDULED = RecencyRule(
    rule_id="calendar.scheduled.anticipation",
    mode=RecencyMode.SCHEDULED,
    half_life_days=540.0,
    peak_weight=1.0,
    minimum_weight=0.12,
    unknown_timestamp_weight=0.40,
    unknown_timestamp_quality=0.55,
    freshness_window_days=30.0,
    expiry_days=1825.0,
    anticipation_window_days=180.0,
)
FITNESS_ROUTINE = _historical(
    "fitness.routine.current",
    half_life_days=21.0,
    peak_weight=1.0,
    minimum_weight=0.10,
    unknown_timestamp_weight=0.35,
    unknown_timestamp_quality=0.50,
    freshness_window_days=7.0,
    expiry_days=42.0,
)


def _default_rules() -> Mapping[RecencyKey, RecencyRule]:
    rules: dict[RecencyKey, RecencyRule] = {}

    def register(
        domain: str,
        sources: tuple[str, ...],
        actions: tuple[str, ...],
        rule: RecencyRule,
    ) -> None:
        for source in sources:
            for action in actions:
                key = RecencyKey(domain, source, action)
                if key in rules:
                    raise ValueError("duplicate_default_recency_rule")
                rules[key] = rule

    register("video", ("youtube",), ("liked", "liked_video"), VIDEO_LIKE)
    register("video", ("youtube",), ("watched", "video"), VIDEO_EPHEMERAL)
    register("video", ("youtube",), ("shared",), VIDEO_SHARE)
    register("video", ("youtube",), ("subscription",), ENDURING_FOLLOW)

    register(
        "music",
        ("apple_music", "spotify"),
        ("followed_artist",),
        ENDURING_FOLLOW,
    )
    register(
        "music",
        ("apple_music", "spotify"),
        ("saved_album", "saved_track"),
        ENDURING_LIBRARY,
    )
    register(
        "music",
        ("apple_music",),
        (
            "library_album",
            "library_artist",
            "library_playlist",
            "library_song",
            "playlist_item",
        ),
        ENDURING_LIBRARY,
    )
    register("music", ("music_library",), ("library_song",), ENDURING_LIBRARY)
    register("music", ("apple_music",), ("rating",), ENDURING_RATING)
    register(
        "music",
        ("apple_music", "spotify"),
        ("recently_played",),
        MUSIC_RECENT,
    )
    register("music", ("apple_music",), ("recently_added",), MUSIC_ADDED)
    # Spotify only: Apple Music states no equivalent ranking.
    register("music", ("spotify",), ("top_artist", "top_track"), MUSIC_TOP)

    register(
        "podcast",
        ("apple_podcasts", "podcast"),
        ("followed",),
        ENDURING_FOLLOW,
    )
    register(
        "podcast",
        ("apple_podcasts", "podcast"),
        ("saved",),
        ENDURING_LIBRARY,
    )
    register(
        "podcast",
        ("apple_podcasts", "podcast"),
        ("played",),
        PODCAST_PLAY,
    )

    register(
        "calendar",
        ("apple_calendar", "google_calendar"),
        ("scheduled",),
        CALENDAR_SCHEDULED,
    )
    register("fitness", ("healthkit",), ("routine",), FITNESS_ROUTINE)
    return MappingProxyType(rules)


DEFAULT_RECENCY_POLICY = RecencyPolicy(
    version=RECENCY_POLICY_VERSION,
    rules=_default_rules(),
)


__all__ = [
    "CALENDAR_SCHEDULED",
    "FITNESS_ROUTINE",
    "DEFAULT_RECENCY_POLICY",
    "RECENCY_POLICY_VERSION",
    "RecencyDecision",
    "RecencyKey",
    "RecencyMode",
    "RecencyPolicy",
    "RecencyPolicyError",
    "RecencyRule",
    "TemporalStatus",
    "TimestampQuality",
]
