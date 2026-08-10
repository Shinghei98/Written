from __future__ import annotations

import math
import re
from dataclasses import dataclass, field
from enum import StrEnum
from typing import Protocol

from .models import Term
from .normalize import normalize_text


_CHANNEL_ID = re.compile(r"^UC[A-Za-z0-9_-]{22}$")


class YouTubeChannelRole(StrEnum):
    """Role of the channel itself; never infer this from its title alone."""

    OFFICIAL_CREATOR = "official_creator"
    PUBLISHER = "publisher"
    TOPICAL = "topical"
    FAN_REPOST = "fan_repost"
    UNKNOWN = "unknown"


class ResolutionState(StrEnum):
    CANDIDATE = "candidate"
    ACTIVE = "active"
    REJECTED = "rejected"


@dataclass(frozen=True, slots=True)
class YouTubeChannelResolution:
    channel_id: str
    channel_label: str
    role: YouTubeChannelRole
    state: ResolutionState
    exact_id_match: bool
    confidence: float
    provenance: str
    represented_label: str | None = None
    represented_kind: str | None = None
    metadata: dict[str, str] = field(default_factory=dict)

    def is_usable(self, requested_channel_id: str) -> bool:
        if (
            self.state is not ResolutionState.ACTIVE
            or self.exact_id_match is not True
            or self.channel_id != requested_channel_id
            or not _CHANNEL_ID.fullmatch(self.channel_id)
            or not self.channel_label.strip()
            or not self.provenance.strip()
            or not isinstance(self.confidence, (int, float))
            or isinstance(self.confidence, bool)
            or not math.isfinite(self.confidence)
            or not 0.0 <= self.confidence <= 1.0
        ):
            return False
        if self.role is YouTubeChannelRole.OFFICIAL_CREATOR:
            return bool(self.represented_label and self.represented_kind == "creator")
        if self.role is YouTubeChannelRole.PUBLISHER:
            return self.represented_kind in {None, "organization"}
        return self.represented_label is None and self.represented_kind is None


class YouTubeChannelResolver(Protocol):
    def resolve(
        self,
        channel_id: str,
        channel_label: str,
    ) -> YouTubeChannelResolution | None: ...


class StaticYouTubeChannelResolver:
    """Deterministic resolver for tests and curated production cache reads."""

    def __init__(self, resolutions: tuple[YouTubeChannelResolution, ...]) -> None:
        self._by_id = {item.channel_id: item for item in resolutions}

    def resolve(
        self,
        channel_id: str,
        channel_label: str,
    ) -> YouTubeChannelResolution | None:
        del channel_label  # Titles can change; stable ID is authoritative.
        return self._by_id.get(channel_id)


@dataclass(frozen=True, slots=True)
class YouTubeTermPolicy:
    """Feature gates must correspond to documented YouTube approval scope."""

    channel_identity_terms: bool = False
    channel_role_resolution: bool = False
    uploader_tags: bool = False
    written_title_tags: bool = False
    cross_source_fusion: bool = False
    bio_surface: bool = False
    icebreaker_surface: bool = False


@dataclass(frozen=True, slots=True)
class YouTubeTermResult:
    terms: tuple[Term, ...]
    channel_id: str | None
    channel_role: YouTubeChannelRole
    resolution_used: bool
    policy: YouTubeTermPolicy


def _channel_weight(action: str) -> float:
    if action == "subscription":
        return 1.0
    if action in {"liked", "liked_video", "shared"}:
        return 0.25
    return 0.12


def _append_unique(terms: list[Term], term: Term) -> None:
    identity = (term.normalized, term.role, term.type_hint)
    if any((item.normalized, item.role, item.type_hint) == identity for item in terms):
        return
    terms.append(term)


def build_youtube_terms(
    *,
    action: str,
    channel_id: str | None,
    channel_label: str,
    title: str,
    provider_topics: tuple[str, ...],
    uploader_tags: tuple[str, ...] = (),
    policy: YouTubeTermPolicy | None = None,
    resolver: YouTubeChannelResolver | None = None,
) -> YouTubeTermResult:
    """Create distinct channel, represented-entity, and content terms.

    Provider topics remain content descriptions. A channel can represent a
    creator only through an active exact-ID resolution. Fan/repost channels
    never transfer evidence to the person or group shown in their videos.
    """

    policy = policy or YouTubeTermPolicy()
    normalized_channel_id = (channel_id or "").strip()
    if not _CHANNEL_ID.fullmatch(normalized_channel_id):
        normalized_channel_id = ""
    terms: list[Term] = []

    for topic in provider_topics:
        if not topic.strip():
            continue
        _append_unique(
            terms,
            Term(
                text=topic.strip(),
                normalized=normalize_text(topic),
                role="youtube_provider_topic",
                source_field="extra.provider_topic",
                type_hint="topic",
                evidence_weight=1.0,
            ),
        )

    if policy.uploader_tags:
        for tag in uploader_tags:
            if not tag.strip():
                continue
            _append_unique(
                terms,
                Term(
                    text=tag.strip(),
                    normalized=normalize_text(tag),
                    role="youtube_uploader_tag",
                    source_field="extra.tags",
                    type_hint="topic",
                    evidence_weight=0.65,
                ),
            )

    channel_role = YouTubeChannelRole.UNKNOWN
    resolution_used = False
    resolution: YouTubeChannelResolution | None = None
    if (
        policy.channel_role_resolution
        and resolver is not None
        and normalized_channel_id
    ):
        try:
            candidate = resolver.resolve(normalized_channel_id, channel_label)
        except Exception:  # noqa: BLE001 - exact resolver boundary fails closed
            candidate = None
        if candidate is not None and candidate.is_usable(normalized_channel_id):
            resolution = candidate
            channel_role = candidate.role
            resolution_used = True

    if policy.channel_identity_terms and normalized_channel_id and channel_label.strip():
        _append_unique(
            terms,
            Term(
                text=channel_label.strip(),
                normalized=normalize_text(channel_label),
                role="youtube_channel",
                source_field="creator",
                type_hint="channel",
                evidence_weight=_channel_weight(action),
            ),
        )

    if resolution is not None:
        if resolution.role is YouTubeChannelRole.OFFICIAL_CREATOR:
            _append_unique(
                terms,
                Term(
                    text=resolution.represented_label or "",
                    normalized=normalize_text(resolution.represented_label or ""),
                    role="channel_represents_creator",
                    source_field="resolved_channel_id",
                    type_hint="creator",
                    evidence_weight=0.85 if action == "subscription" else 0.20,
                ),
            )
        elif resolution.role is YouTubeChannelRole.PUBLISHER:
            label = resolution.represented_label or resolution.channel_label
            _append_unique(
                terms,
                Term(
                    text=label,
                    normalized=normalize_text(label),
                    role="youtube_publisher",
                    source_field="resolved_channel_id",
                    type_hint="organization",
                    evidence_weight=0.55 if action == "subscription" else 0.12,
                ),
            )

    if policy.written_title_tags and title.strip():
        _append_unique(
            terms,
            Term(
                text=title.strip(),
                normalized=normalize_text(title),
                role="written_derived_title_candidate",
                source_field="name",
                type_hint="work",
                evidence_weight=0.55,
            ),
        )

    return YouTubeTermResult(
        terms=tuple(terms),
        channel_id=normalized_channel_id or None,
        channel_role=channel_role,
        resolution_used=resolution_used,
        policy=policy,
    )
