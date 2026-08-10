from __future__ import annotations

from dataclasses import dataclass, field
from collections.abc import Callable, Iterable
from datetime import datetime, timezone
from enum import StrEnum
import math
from typing import Protocol


class _HasAssertionKey(Protocol):
    key: str


class FeedbackAction(StrEnum):
    SUPPRESS = "suppress"
    RESTORE = "restore"
    CONFIRM = "confirm"
    EXPLICIT_ADD = "explicit_add"


@dataclass(frozen=True, slots=True)
class FeedbackEvent:
    user_id: str
    client_event_id: str
    action: FeedbackAction
    assertion_key: str
    rule_signature: str
    linked_observation_ids: tuple[str, ...] = ()
    occurred_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))


@dataclass(frozen=True, slots=True)
class FeedbackEffects:
    suppress_for_user: bool
    semantic_positive_observation_ids: tuple[str, ...]
    semantic_global_negative: bool
    acceptance_probability: float
    needs_curator_review: bool


@dataclass(slots=True)
class _RuleState:
    alpha: float = 4.0
    beta: float = 2.0
    positive_users: set[str] = field(default_factory=set)
    rejection_users: set[str] = field(default_factory=set)
    exposed_users: set[str] = field(default_factory=set)

    @property
    def mean(self) -> float:
        return self.alpha / (self.alpha + self.beta)


class FeedbackLearner:
    """Offline analytics helper; Postgres remains the visibility authority."""

    def __init__(
        self,
        global_review_user_threshold: int = 8,
        minimum_exposed_users: int = 20,
        rejection_rate_threshold: float = 0.30,
        link_validator: Callable[[FeedbackEvent], Iterable[str]] | None = None,
        rule_resolver: Callable[[FeedbackEvent], str] | None = None,
    ) -> None:
        if (
            type(global_review_user_threshold) is not int
            or global_review_user_threshold < 1
            or type(minimum_exposed_users) is not int
            or minimum_exposed_users < 1
            or not isinstance(rejection_rate_threshold, (int, float))
            or isinstance(rejection_rate_threshold, bool)
            or not math.isfinite(rejection_rate_threshold)
            or not 0.0 <= rejection_rate_threshold <= 1.0
        ):
            raise ValueError("feedback review thresholds are invalid")
        self.global_review_user_threshold = global_review_user_threshold
        self.minimum_exposed_users = minimum_exposed_users
        self.rejection_rate_threshold = rejection_rate_threshold
        self.link_validator = link_validator
        self.rule_resolver = rule_resolver
        self.suppressions: set[tuple[str, str]] = set()
        self.event_fingerprints: dict[tuple[str, str], tuple[object, ...]] = {}
        self.event_effects: dict[tuple[str, str], FeedbackEffects] = {}
        self.rule_states: dict[str, _RuleState] = {}

    def record_exposure(self, rule_signature: str, user_id: str) -> None:
        """Record a server-validated display exposure for batch diagnostics."""
        if any(
            not isinstance(value, str) or not value.strip() or len(value) > 512
            for value in (rule_signature, user_id)
        ):
            raise ValueError("exposure identifiers must be nonempty bounded strings")
        self.rule_states.setdefault(rule_signature, _RuleState()).exposed_users.add(user_id)

    def apply(self, event: FeedbackEvent) -> FeedbackEffects:
        if not isinstance(event.action, FeedbackAction):
            raise ValueError("feedback action is not recognized")
        identifiers = {
            "user_id": event.user_id,
            "client_event_id": event.client_event_id,
            "assertion_key": event.assertion_key,
            "rule_signature": event.rule_signature,
        }
        if any(
            not isinstance(value, str) or not value.strip() or len(value) > 512
            for value in identifiers.values()
        ):
            raise ValueError("feedback identifiers must be nonempty bounded strings")
        if (
            not isinstance(event.occurred_at, datetime)
            or event.occurred_at.tzinfo is None
            or event.occurred_at.utcoffset() is None
        ):
            raise ValueError("feedback occurred_at must be timezone-aware")
        if not isinstance(event.linked_observation_ids, tuple):
            raise ValueError("linked observation IDs must be an immutable tuple")
        if any(
            not isinstance(identifier, str) or not identifier.strip() or len(identifier) > 512
            for identifier in event.linked_observation_ids
        ):
            raise ValueError("linked observation IDs must be nonempty bounded strings")
        idempotency_key = (event.user_id, event.client_event_id)
        fingerprint = (
            event.action,
            event.assertion_key,
            event.rule_signature,
            event.linked_observation_ids,
            event.occurred_at,
        )
        if idempotency_key in self.event_fingerprints:
            if self.event_fingerprints[idempotency_key] != fingerprint:
                raise ValueError("client_event_id was reused with a different feedback payload")
            return self.event_effects[idempotency_key]
        rule_signature = (
            self.rule_resolver(event)
            if self.rule_resolver is not None
            else f"assertion:{event.assertion_key}"
        )
        if not isinstance(rule_signature, str) or not rule_signature.strip():
            raise ValueError("server rule resolver returned an empty signature")
        semantic_positive: tuple[str, ...] = ()
        if event.action == FeedbackAction.EXPLICIT_ADD and self.link_validator is not None:
            validated = tuple(dict.fromkeys(self.link_validator(event)))
            requested = set(event.linked_observation_ids)
            if any(identifier not in requested for identifier in validated):
                raise ValueError("link validator returned an observation the event did not request")
            semantic_positive = validated

        state = self.rule_states.setdefault(rule_signature, _RuleState())

        if event.action == FeedbackAction.SUPPRESS:
            self.suppressions.add((event.user_id, event.assertion_key))
            if event.user_id in state.positive_users:
                state.positive_users.remove(event.user_id)
                state.alpha -= 1.0
            if event.user_id not in state.rejection_users:
                state.rejection_users.add(event.user_id)
                state.beta += 1.0
        elif event.action == FeedbackAction.RESTORE:
            self.suppressions.discard((event.user_id, event.assertion_key))
            if event.user_id in state.rejection_users:
                state.rejection_users.remove(event.user_id)
                state.beta -= 1.0
        elif event.action in {FeedbackAction.CONFIRM, FeedbackAction.EXPLICIT_ADD}:
            self.suppressions.discard((event.user_id, event.assertion_key))
            if event.user_id in state.rejection_users:
                state.rejection_users.remove(event.user_id)
                state.beta -= 1.0
            if event.user_id not in state.positive_users:
                state.positive_users.add(event.user_id)
                state.alpha += 1.0
        exposed_users = len(state.exposed_users)
        rejection_rate = (
            len(state.rejection_users) / exposed_users if exposed_users else 0.0
        )

        effects = FeedbackEffects(
            suppress_for_user=(event.user_id, event.assertion_key) in self.suppressions,
            semantic_positive_observation_ids=semantic_positive,
            semantic_global_negative=False,
            acceptance_probability=round(state.mean, 8),
            needs_curator_review=(
                len(state.rejection_users) >= self.global_review_user_threshold
                and exposed_users >= self.minimum_exposed_users
                and rejection_rate >= self.rejection_rate_threshold
            ),
        )
        self.event_fingerprints[idempotency_key] = fingerprint
        self.event_effects[idempotency_key] = effects
        return effects

    def is_suppressed(self, user_id: str, assertion_key: str) -> bool:
        return (user_id, assertion_key) in self.suppressions

    def visible_assertions(
        self,
        user_id: str,
        assertions: Iterable[_HasAssertionKey],
    ) -> tuple[_HasAssertionKey, ...]:
        """Final fail-safe filter to apply after every recomputation."""
        return tuple(
            assertion
            for assertion in assertions
            if not self.is_suppressed(user_id, assertion.key)
        )
