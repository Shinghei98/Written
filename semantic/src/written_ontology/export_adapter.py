from __future__ import annotations

import csv
import re
from collections.abc import Callable
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

from .calendar_semantics import (
    BookedActivity,
    CalendarClassifier,
    CalendarDisposition,
    FlightSegment,
)
from .healthkit import (
    FitnessHabitBuilder,
    HEALTHKIT_SOURCE_ALIASES,
    canonical_healthkit_source,
    ingest_healthkit_rows,
)
from .models import AdapterResult, Observation, Term
from .normalize import normalize_text, parse_semicolon_kv, stable_hash
from .safety import InferenceSafetyPolicy
from .source_policy import (
    SOURCE_ACTION_PAIRS,
    SOURCE_ACTION_WEIGHTS,
    SOURCE_LAYOUT,
)
from .youtube import (
    YouTubeChannelResolver,
    YouTubeTermPolicy,
    build_youtube_terms,
)


EXPLICIT_PROFILE_DATA_TYPES = {
    "age",
    "bio",
    "education",
    "flirt_level",
    "gender",
    "gender_preference",
    "occupation",
    "response_time",
}

CONNECTION_STATE_DATA_TYPES = {
    "apple_music_subscription",
}

CATALOG_RESOURCE_TYPE_ALIASES = {
    "albums": "album",
    "artists": "artist",
    "library_albums": "album",
    "library_artists": "artist",
    "library_songs": "song",
    "music_videos": "music_video",
    "songs": "song",
    "tracks": "track",
}

PUBLIC_CATALOG_RESOURCE_TYPES = {
    "apple_music": {"album", "artist", "music_video", "song", "track"},
    "spotify": {"album", "artist", "track"},
    "apple_podcasts": {"episode", "podcast", "show"},
    "podcast": {"episode", "podcast", "show"},
}

# Action, timestamps, ratings, removal markers, and other behavioral metadata
# must remain row-local even when two rows represent the same catalog item.
MUSIC_SIBLING_EXTRA_FIELDS = {
    "album",
    "composer",
    "genre",
    "genres",
    "isrc",
}

# This key is intentionally non-secret.  It exists only to make standalone
# export inspection deterministic.  Production persistence must inject a
# deployment-secret HMAC signer/key into CalendarClassifier.
_OFFLINE_CALENDAR_LINEAGE_KEY = b"written-offline-calendar-inspection-v0.1"

# Small bundled resolver for deterministic offline inspection of common US and
# international routes. Production should inject a licensed, versioned IATA
# and city catalog rather than expanding this table ad hoc.
_OFFLINE_CALENDAR_PLACE_CATALOG = {
    "STL": "place:saint_louis",
    "St Louis": "place:saint_louis",
    "Saint Louis": "place:saint_louis",
    "LAX": "place:los_angeles",
    "Los Angeles": "place:los_angeles",
    "HKG": "place:hong_kong",
    "Hong Kong": "place:hong_kong",
    "JFK": "place:new_york",
    "New York": "place:new_york",
    "SFO": "place:san_francisco",
    "San Francisco": "place:san_francisco",
    "ORD": "place:chicago",
    "Chicago": "place:chicago",
    "SEA": "place:seattle",
    "Seattle": "place:seattle",
    "LHR": "place:london",
    "London": "place:london",
    "CDG": "place:paris",
    "Paris": "place:paris",
    "NRT": "place:tokyo",
    "HND": "place:tokyo",
    "Tokyo": "place:tokyo",
    "SIN": "place:singapore",
    "Singapore": "place:singapore",
    "TPE": "place:taipei",
    "Taipei": "place:taipei",
}

_OFFLINE_CALENDAR_PLACE_LABELS = {
    "place:saint_louis": "St. Louis",
    "place:los_angeles": "Los Angeles",
    "place:hong_kong": "Hong Kong",
    "place:new_york": "New York",
    "place:san_francisco": "San Francisco",
    "place:chicago": "Chicago",
    "place:seattle": "Seattle",
    "place:london": "London",
    "place:paris": "Paris",
    "place:tokyo": "Tokyo",
    "place:singapore": "Singapore",
    "place:taipei": "Taipei",
}

_OFFLINE_CALENDAR_CARRIERS = {
    "AA", "AC", "AF", "AS", "B6", "BA", "CX", "DL", "EK", "F9",
    "KL", "LH", "NH", "NK", "QF", "QR", "SQ", "TK", "UA", "WN",
}

_OFFLINE_LEISURE_VENDORS = {
    "airbnb experiences",
    "eventbrite",
    "getyourguide",
    "opentable",
    "resy",
    "ticketmaster",
    "viator",
}


def _default_calendar_classifier() -> CalendarClassifier:
    return CalendarClassifier(
        place_catalog=_OFFLINE_CALENDAR_PLACE_CATALOG,
        place_labels=_OFFLINE_CALENDAR_PLACE_LABELS,
        carrier_codes=_OFFLINE_CALENDAR_CARRIERS,
        recognized_leisure_vendors=_OFFLINE_LEISURE_VENDORS,
        lineage_key=_OFFLINE_CALENDAR_LINEAGE_KEY,
    )


def _sanitized_activity_label(activity: BookedActivity) -> str:
    """Collapse a private ticket title to a controlled, non-identifying label."""

    normalized = normalize_text(activity.activity_label)
    controlled_labels = (
        ("food tour", "Food tour"),
        ("walking tour", "Walking tour"),
        ("guided tour", "Guided tour"),
        ("city tour", "City tour"),
        ("museum", "Museum visit"),
        ("concert", "Concert"),
        ("theatre", "Theatre performance"),
        ("theater", "Theater performance"),
        ("cinema", "Cinema"),
        ("aquarium", "Aquarium visit"),
        ("zoo", "Zoo visit"),
        ("hotel", "Hotel stay"),
        ("lodging", "Hotel stay"),
        ("cruise", "Cruise"),
        ("tasting", "Tasting"),
        ("tour", "Tour"),
        ("attraction", "Attraction ticket"),
        ("performance", "Performance"),
        ("restaurant reservation", "Restaurant reservation"),
        ("ballet", "Ballet performance"),
        ("opera", "Opera performance"),
        ("comedy show", "Comedy show"),
        ("musical", "Musical performance"),
        ("festival", "Festival"),
        ("live performance", "Live performance"),
    )
    return next(
        (label for token, label in controlled_labels if token in normalized),
        "Booked leisure activity",
    )


def _parse_datetime(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def _safe_text(value: str | None) -> str:
    return (value or "").strip()


def _canonical_token(value: str | None) -> str:
    return "_".join(normalize_text(value or "").split())


def _canonical_resource_type(value: str | None) -> str:
    token = _canonical_token(value)
    return CATALOG_RESOURCE_TYPE_ALIASES.get(token, token)


def _split_controlled_values(value: str | None) -> tuple[str, ...]:
    """Split provider-controlled list fields without splitting free text."""
    seen: set[str] = set()
    values: list[str] = []
    for item in re.split(r"[|,]", value or ""):
        item = item.strip()
        normalized = normalize_text(item)
        if not item or not normalized or normalized in seen:
            continue
        seen.add(normalized)
        values.append(item)
    return tuple(values)


CatalogIdentityVerifier = Callable[
    [dict[str, str], dict[str, str]],
    tuple[str, str, str] | None,
]


@dataclass(frozen=True, slots=True)
class ExportInspection:
    rows: int
    by_source: dict[str, int]
    by_source_and_type: dict[str, int]
    rows_with_user_removal_marker: int
    source_item_id_collisions: int

    def as_dict(self) -> dict[str, Any]:
        return {
            "rows": self.rows,
            "by_source": self.by_source,
            "by_source_and_type": self.by_source_and_type,
            "rows_with_user_removal_marker": self.rows_with_user_removal_marker,
            "source_item_id_collisions": self.source_item_id_collisions,
        }


@dataclass(frozen=True, slots=True)
class AdapterCapabilities:
    """Explicit approvals for YouTube semantics and product-surface use.

    The two legacy fields remain as compatibility aliases for the V0.1 CLI.
    They no longer license treating every channel title as a creator.
    """

    youtube_channel_entity_mapping: bool = False
    youtube_title_term_derivation: bool = False
    youtube_channel_identity_terms: bool = False
    youtube_channel_role_resolution: bool = False
    youtube_uploader_tags: bool = False
    youtube_cross_source_fusion: bool = False
    youtube_bio_surface: bool = False
    youtube_icebreaker_surface: bool = False
    # Health rows are always eligible for the private raw-ingestion boundary.
    # This gate enables the closed typed fitness parser and habit builder; it
    # does not grant matching, bio, or icebreaker use.
    healthkit_fitness_ingestion: bool = True


class WrittenExportAdapter:
    """Adapter for the current eight-column Written distillation export.

    The adapter is deliberately source-specific. It does not treat every CSV
    row as an independent statement of interest.
    """

    def __init__(
        self,
        safety: InferenceSafetyPolicy | None = None,
        *,
        capabilities: AdapterCapabilities | None = None,
        catalog_identity_verifier: CatalogIdentityVerifier | None = None,
        youtube_channel_resolver: YouTubeChannelResolver | None = None,
        calendar_classifier: CalendarClassifier | None = None,
    ) -> None:
        self.safety = safety or InferenceSafetyPolicy()
        # Both capabilities remain false until Written has the applicable
        # categorization approval and documented derived-data behavior.
        self.capabilities = capabilities or AdapterCapabilities()
        self.catalog_identity_verifier = catalog_identity_verifier
        self.youtube_channel_resolver = youtube_channel_resolver
        self.calendar_classifier = calendar_classifier or _default_calendar_classifier()

    def _trusted_catalog_identity(
        self,
        row: dict[str, str],
        extra: dict[str, str],
    ) -> tuple[str, str, str] | None:
        source = row.get("source", "")
        claimed_resource_type = _canonical_resource_type(
            extra.get("catalog_resource_type") or extra.get("resource_type")
        )
        if (
            self.catalog_identity_verifier is None
            or source not in PUBLIC_CATALOG_RESOURCE_TYPES
            or claimed_resource_type not in PUBLIC_CATALOG_RESOURCE_TYPES[source]
        ):
            return None
        minimized_row = {
            "source": source,
            "item_id": _safe_text(row.get("item_id")),
        }
        minimized_extra = {
            key: value
            for key, value in extra.items()
            if key
            in {
                "catalog_authority",
                "catalog_id",
                "catalog_resource_type",
                "catalog_signature",
                "catalog_verified",
                "provider_catalog_id",
                "resource_type",
            }
        }
        try:
            identity = self.catalog_identity_verifier(minimized_row, minimized_extra)
        except Exception:  # noqa: BLE001 - verifier boundary fails closed
            return None
        if (
            not isinstance(identity, tuple)
            or len(identity) != 3
            or any(not isinstance(value, str) or not value.strip() for value in identity)
        ):
            return None
        source, resource_type, catalog_id = identity
        resource_type = _canonical_resource_type(resource_type)
        if source != row["source"]:
            return None
        if resource_type not in PUBLIC_CATALOG_RESOURCE_TYPES.get(source, set()):
            return None
        return source, resource_type, catalog_id

    def read(self, path: str | Path) -> AdapterResult:
        rows = self._read_rows(path)
        input_counts = Counter(f"{row['source']}|{row['data_type']}" for row in rows)
        raw_retained = Counter()
        excluded = Counter()
        routed_profile = Counter()
        routed_location = Counter()
        routed_connection = Counter()
        policy_quarantined = Counter()
        observations: list[Observation] = []

        # Broad collection and semantic eligibility are separate. Every
        # non-removed row can enter the owner-private raw vault. HealthKit is
        # parsed into a purpose-limited quantitative lane and never sent to
        # the generic term mapper as raw observations.
        for row in rows:
            extra = parse_semicolon_kv(row["extra"])
            if "removed_by_user" not in extra:
                raw_retained[f"{row['source']}|{row['data_type']}"] += 1
        health_rows = [row for row in rows if row["source"] == "healthkit"]
        if self.capabilities.healthkit_fitness_ingestion:
            health_result = ingest_healthkit_rows(health_rows)
            fitness_records = health_result.records
            fitness_coverage = health_result.coverage
            fitness_candidates = FitnessHabitBuilder().derive(fitness_records)
            excluded.update(health_result.excluded_counts)
        else:
            health_result = None
            fitness_records = ()
            fitness_coverage = None
            fitness_candidates = ()
            if health_rows:
                excluded["healthkit_fitness_feature_disabled"] += len(health_rows)

        # Calendar container rows are connector metadata, not interests.  Keep
        # a private in-memory index so birthday/subscribed/holiday calendars can
        # exclude their children before any title parsing.  Legacy Apple rows
        # reference the container name; newer exporters should use item_id.
        calendar_metadata: dict[tuple[str, str], dict[str, Any]] = {}
        for row in rows:
            if (
                row["source"] not in {"apple_calendar", "google_calendar"}
                or row["data_type"] != "calendar"
            ):
                continue
            metadata = {
                "name": row["name"],
                "extra": parse_semicolon_kv(row["extra"]),
            }
            for reference in (row["item_id"], row["name"]):
                normalized_reference = normalize_text(reference)
                if normalized_reference:
                    calendar_metadata[(row["source"], normalized_reference)] = metadata

        # A rating or recent row can omit descriptive metadata. Reuse metadata
        # from another representation of the same provider item, but do not
        # count the representations as independent evidence.
        by_provider_item: dict[tuple[str, str, str], list[dict[str, str]]] = defaultdict(list)
        for row in rows:
            extra = parse_semicolon_kv(row["extra"])
            if "removed_by_user" in extra:
                continue
            identity = self._trusted_catalog_identity(row, extra)
            if identity is not None:
                by_provider_item[identity].append(row)

        for row in rows:
            source = row["source"]
            data_type = row["data_type"]
            extra = parse_semicolon_kv(row["extra"])

            if "removed_by_user" in extra:
                # Applies to every source. The optional legacy reason value is
                # deliberately ignored.
                excluded["user_removed_observation"] += 1
                continue

            if source == "healthkit":
                # The purpose-limited parser above owns these rows. Raw Health
                # samples must never fall through to generic term extraction.
                continue

            if source == "user":
                if data_type in CONNECTION_STATE_DATA_TYPES:
                    routed_connection[f"{source}|{data_type}"] += 1
                elif data_type in EXPLICIT_PROFILE_DATA_TYPES:
                    if extra.get("entered_by_user") != "1":
                        excluded["profile_without_explicit_provenance"] += 1
                    else:
                        routed_profile[f"{source}|{data_type}"] += 1
                else:
                    excluded["unsupported_user_data_type"] += 1
                continue

            if source == "location":
                if data_type == "place":
                    routed_location[f"{source}|{data_type}"] += 1
                else:
                    excluded["unsupported_location_data_type"] += 1
                continue
            if source not in SOURCE_LAYOUT:
                excluded["unsupported_source"] += 1
                continue

            if source in {"apple_music", "music_library", "spotify"}:
                if data_type in {"recommendation", "apple_music_subscription"}:
                    excluded[f"non_choice_{data_type}"] += 1
                    continue
                if (data_type, data_type) not in SOURCE_ACTION_PAIRS[source]:
                    excluded["music_not_semantically_usable"] += 1
                    continue
                if source == "spotify":
                    resource_type = _canonical_token(
                        extra.get("catalog_resource_type") or extra.get("resource_type")
                    )
                    if resource_type not in {"album", "artist", "track"}:
                        excluded["unsupported_or_missing_spotify_music_resource_type"] += 1
                        continue
                identity = self._trusted_catalog_identity(row, extra)
                observation = self._music_observation(
                    row,
                    extra,
                    by_provider_item.get(identity, [row]) if identity is not None else [row],
                    identity,
                )
                if observation is None:
                    excluded["music_not_semantically_usable"] += 1
                else:
                    observations.append(observation)
                continue

            if source in {"apple_calendar", "google_calendar"}:
                calendar_reference = normalize_text(
                    extra.get("calendar_id") or extra.get("calendar") or ""
                )
                observation, reason = self._calendar_observation(
                    row,
                    extra,
                    calendar_metadata=calendar_metadata.get(
                        (source, calendar_reference)
                    ),
                )
                if observation is None:
                    excluded[reason] += 1
                else:
                    observations.append(observation)
                continue

            if source == "youtube":
                observation, reason = self._youtube_observation(row, extra)
                if observation is None:
                    excluded[reason] += 1
                else:
                    observations.append(observation)
                continue

            if source in {"apple_podcasts", "podcast"}:
                observation = self._podcast_observation(
                    row,
                    extra,
                    self._trusted_catalog_identity(row, extra),
                )
                if observation is None:
                    excluded["podcast_not_semantically_usable"] += 1
                else:
                    observations.append(observation)
                continue

            excluded["adapter_not_implemented"] += 1

        deduplicated: list[Observation] = []
        seen_fingerprints: set[str] = set()
        for observation in observations:
            if observation.record_fingerprint in seen_fingerprints:
                excluded["duplicate_record_fingerprint"] += 1
                continue
            seen_fingerprints.add(observation.record_fingerprint)
            deduplicated.append(observation)

        return AdapterResult(
            observations=tuple(deduplicated),
            raw_retained_counts=dict(sorted(raw_retained.items())),
            excluded_counts=dict(sorted(excluded.items())),
            routed_profile_counts=dict(sorted(routed_profile.items())),
            routed_location_counts=dict(sorted(routed_location.items())),
            routed_connection_counts=dict(sorted(routed_connection.items())),
            policy_quarantined_counts=dict(sorted(policy_quarantined.items())),
            input_counts=dict(sorted(input_counts.items())),
            fitness_records=tuple(fitness_records),
            fitness_coverage=fitness_coverage,
            fitness_habit_candidates=tuple(fitness_candidates),
        )

    def inspect(self, path: str | Path) -> ExportInspection:
        rows = self._read_rows(path)
        by_source = Counter(row["source"] for row in rows)
        by_pair = Counter(f"{row['source']}|{row['data_type']}" for row in rows)
        item_ids = Counter((row["source"], row["item_id"]) for row in rows)
        removals = sum(
            "removed_by_user" in parse_semicolon_kv(row["extra"])
            for row in rows
        )
        return ExportInspection(
            rows=len(rows),
            by_source=dict(sorted(by_source.items())),
            by_source_and_type=dict(sorted(by_pair.items())),
            rows_with_user_removal_marker=removals,
            source_item_id_collisions=sum(count > 1 for count in item_ids.values()),
        )

    @staticmethod
    def _read_rows(path: str | Path) -> list[dict[str, str]]:
        with Path(path).open(encoding="utf-8-sig", newline="") as handle:
            reader = csv.DictReader(handle)
            required = {
                "source",
                "data_type",
                "item_id",
                "name",
                "creator",
                "detail",
                "extra",
                "collected_at",
            }
            if set(reader.fieldnames or ()) != required:
                raise ValueError(f"unexpected export columns: {reader.fieldnames}")
            rows: list[dict[str, str]] = []
            for raw_row in reader:
                row = {key: value or "" for key, value in raw_row.items()}
                source = _canonical_token(row["source"])
                row["source"] = (
                    canonical_healthkit_source(source)
                    if source in HEALTHKIT_SOURCE_ALIASES
                    else source
                )
                row["data_type"] = _canonical_token(row["data_type"])
                row["item_id"] = _safe_text(row["item_id"])
                rows.append(row)
            return rows

    def _music_observation(
        self,
        row: dict[str, str],
        extra: dict[str, str],
        siblings: list[dict[str, str]],
        catalog_identity: tuple[str, str, str] | None,
    ) -> Observation | None:
        data_type = row["data_type"]
        action_weight = SOURCE_ACTION_WEIGHTS[row["source"]].get(data_type)
        if action_weight is None:
            return None
        if data_type == "rating" and _canonical_token(extra.get("rating_polarity")) not in {
            "favorite",
            "liked",
            "positive",
        }:
            # Numeric ratings are ambiguous without a declared scale and
            # direction. Require a connector-supplied positive intent label.
            return None

        enriched = dict(row)
        for field in ("name", "creator"):
            if _safe_text(enriched[field]):
                continue
            enriched[field] = next(
                (_safe_text(item[field]) for item in siblings if _safe_text(item[field])),
                "",
            )
        sibling_extras = [parse_semicolon_kv(item["extra"]) for item in siblings]
        combined_extra = dict(extra)
        for sibling_extra in sibling_extras:
            for key in MUSIC_SIBLING_EXTRA_FIELDS:
                value = sibling_extra.get(key)
                if value:
                    combined_extra.setdefault(key, value)

        terms: list[Term] = []
        name = _safe_text(enriched["name"])
        creator = _safe_text(enriched["creator"])
        album = _safe_text(combined_extra.get("album"))
        genres = _safe_text(combined_extra.get("genres") or combined_extra.get("genre"))
        composer = _safe_text(combined_extra.get("composer"))
        verified_public_catalog = catalog_identity is not None

        custom_playlist = data_type == "library_playlist"
        name_is_creator = data_type in {"followed_artist", "library_artist"}
        if name:
            terms.append(
                Term(
                    text=name,
                    normalized=normalize_text(name),
                    role=(
                        "creator"
                        if name_is_creator
                        else "user_collection" if custom_playlist else "work"
                    ),
                    source_field="name",
                    type_hint="creator" if name_is_creator else "work" if not custom_playlist else None,
                    safe_for_online=verified_public_catalog and not custom_playlist,
                    safe_for_global_mining=verified_public_catalog and not custom_playlist,
                )
            )
        if creator and (not name_is_creator or normalize_text(creator) != normalize_text(name)):
            terms.append(
                Term(
                    text=creator,
                    normalized=normalize_text(creator),
                    role="creator",
                    source_field="creator",
                    type_hint="creator",
                    safe_for_online=verified_public_catalog,
                    safe_for_global_mining=verified_public_catalog,
                )
            )
        if album and normalize_text(album) != normalize_text(name):
            terms.append(
                Term(
                    text=album,
                    normalized=normalize_text(album),
                    role="album",
                    source_field="extra.album",
                    type_hint="work",
                    safe_for_online=verified_public_catalog,
                    safe_for_global_mining=verified_public_catalog,
                )
            )
        for genre in _split_controlled_values(genres):
            terms.append(
                Term(
                    text=genre,
                    normalized=normalize_text(genre),
                    role="genre",
                    source_field="extra.genres",
                    type_hint="genre",
                    safe_for_online=verified_public_catalog,
                    safe_for_global_mining=verified_public_catalog,
                )
            )
        if composer:
            terms.append(
                Term(
                    text=composer,
                    normalized=normalize_text(composer),
                    role="composer",
                    source_field="extra.composer",
                    type_hint="creator",
                    safe_for_online=verified_public_catalog,
                    safe_for_global_mining=verified_public_catalog,
                )
            )
        if not terms:
            return None

        occurrence_text = (
            combined_extra.get("last_played")
            or combined_extra.get("date_added")
            or combined_extra.get("added")
            or combined_extra.get("added_at")
        )
        occurred_at = _parse_datetime(occurrence_text)
        collected_at = _parse_datetime(row["collected_at"])
        duration = combined_extra.get("duration_s", "")
        isrc = normalize_text(combined_extra.get("isrc", ""))
        if isrc:
            content_lineage = stable_hash("isrc", isrc)
        else:
            content_lineage = stable_hash(
                "music",
                normalize_text(name),
                normalize_text(creator),
                normalize_text(album),
                duration,
            )
        if not name and not creator:
            content_lineage = stable_hash(row["source"], row["item_id"])
        record_fingerprint = stable_hash(
            row["source"],
            data_type,
            row["item_id"],
            occurrence_text,
            combined_extra.get("value"),
            normalize_text(row["detail"]) if data_type == "playlist_item" else "",
        )
        evidence_channel, independence_group = SOURCE_LAYOUT[row["source"]]
        return Observation(
            id=record_fingerprint[:24],
            source=row["source"],
            data_type=data_type,
            action=data_type,
            evidence_channel=evidence_channel,
            independence_group=independence_group,
            occurred_at=occurred_at,
            collected_at=collected_at,
            terms=tuple(terms),
            record_fingerprint=record_fingerprint,
            content_lineage=content_lineage,
            field_quality=1.0 if creator or genres else 0.72,
            action_weight=action_weight,
            privacy_class="public_catalog",
            allow_external_resolution=verified_public_catalog and not custom_playlist,
            metadata={
                "resource_type": combined_extra.get("resource_type"),
                "has_verified_catalog_id": verified_public_catalog,
                "catalog_namespace": catalog_identity[1] if catalog_identity else None,
            },
        )

    def _calendar_observation(
        self,
        row: dict[str, str],
        extra: dict[str, str],
        *,
        calendar_metadata: dict[str, Any] | None = None,
    ) -> tuple[Observation | None, str]:
        if row["data_type"] != "event":
            return None, "calendar_container_metadata"
        decision = self.calendar_classifier.classify(
            {**row, "extra": extra},
            calendar_metadata=calendar_metadata,
        )
        exclusion_codes = {
            CalendarDisposition.EXCLUDED_REMOVED: "user_removed_observation",
            CalendarDisposition.EXCLUDED_CANCELLED: "cancelled_calendar_event",
            CalendarDisposition.EXCLUDED_SENSITIVE: "sensitive_calendar_event",
            CalendarDisposition.EXCLUDED_PERSONAL: "private_personal_calendar_event",
            CalendarDisposition.EXCLUDED_WORK: "work_school_calendar_event",
            CalendarDisposition.EXCLUDED_CALENDAR: "excluded_calendar_event",
            CalendarDisposition.EXCLUDED_OWNERSHIP: "calendar_event_ownership_not_established",
            CalendarDisposition.EXCLUDED_UNKNOWN: "calendar_event_not_allowlisted",
            CalendarDisposition.EXCLUDED_MALFORMED: "malformed_calendar_event",
        }
        if not decision.included:
            return None, exclusion_codes.get(
                decision.disposition, "calendar_event_not_allowlisted"
            )

        occurred_at: datetime | None
        content_lineage: str
        terms: list[Term]
        action_weight: float
        field_quality: float
        semantic_metadata: dict[str, Any]
        if decision.flight_segment is not None:
            flight: FlightSegment = decision.flight_segment
            occurred_at = flight.starts_at
            content_lineage = flight.lineage_id
            terms = [
                Term(
                    text=flight.destination_label,
                    normalized=normalize_text(flight.destination_label),
                    role="scheduled_travel_destination",
                    source_field="validated_flight_destination",
                    type_hint="place",
                    safe_for_online=False,
                    safe_for_global_mining=False,
                )
            ]
            action_weight = flight.evidence_confidence
            field_quality = 0.95
            semantic_metadata = {
                "calendar_semantic_kind": "flight_segment",
                "predicate": "scheduled_travel_to",
                "destination_place_id": flight.destination_place_id,
                "origin_place_id": flight.origin_place_id,
                "memories_only": True,
                "requires_confirmation_for_public_surface": True,
                "journey_eligible": True,
            }
        elif decision.booked_activity is not None:
            activity: BookedActivity = decision.booked_activity
            occurred_at = activity.starts_at
            content_lineage = activity.lineage_id
            safe_activity = _sanitized_activity_label(activity)
            terms = [
                Term(
                    text=safe_activity,
                    normalized=normalize_text(safe_activity),
                    role="booked_leisure_activity",
                    source_field="validated_booking_category",
                    type_hint="activity",
                    safe_for_online=False,
                    safe_for_global_mining=False,
                )
            ]
            if activity.place_id and activity.place_label:
                terms.append(
                    Term(
                        text=activity.place_label,
                        normalized=normalize_text(activity.place_label),
                        role="booked_activity_place",
                        source_field="validated_booking_place",
                        type_hint="place",
                        safe_for_online=False,
                        safe_for_global_mining=False,
                    )
                )
            action_weight = activity.evidence_confidence
            field_quality = 0.92
            semantic_metadata = {
                "calendar_semantic_kind": "booked_activity",
                "predicate": activity.predicate,
                "activity_category": safe_activity,
                "place_id": activity.place_id,
                "memories_only": True,
                "requires_confirmation_for_public_surface": True,
                "journey_eligible": False,
            }
        else:  # Defensive: an included decision must carry typed evidence.
            return None, "malformed_calendar_semantic_decision"

        collected_at = _parse_datetime(row["collected_at"])
        record_fingerprint = stable_hash(
            row["source"], row["data_type"], row["item_id"], extra.get("start")
        )
        evidence_channel, independence_group = SOURCE_LAYOUT[row["source"]]
        return (
            Observation(
                id=record_fingerprint[:24],
                source=row["source"],
                data_type=row["data_type"],
                action="scheduled",
                evidence_channel=evidence_channel,
                independence_group=independence_group,
                occurred_at=occurred_at,
                collected_at=collected_at,
                terms=tuple(terms),
                record_fingerprint=record_fingerprint,
                content_lineage=content_lineage,
                field_quality=field_quality,
                action_weight=action_weight,
                privacy_class="private_calendar_sanitized",
                allow_external_resolution=False,
                metadata=semantic_metadata,
            ),
            "included",
        )

    def _youtube_observation(
        self,
        row: dict[str, str],
        extra: dict[str, str],
    ) -> tuple[Observation | None, str]:
        data_type = row["data_type"]
        if data_type in {"recommendation", "ad", "history_container"}:
            return None, f"non_choice_{data_type}"
        youtube_weights = SOURCE_ACTION_WEIGHTS["youtube"]
        if data_type not in youtube_weights:
            return None, "unsupported_youtube_data_type"
        action_weight = youtube_weights[data_type]
        # Provider-supplied categories/topics are eligible. Titles and free
        # descriptions remain excluded under the conservative V0 policy.
        provider_topics = (
            extra.get("topic_categories")
            or extra.get("topics")
            or extra.get("category")
            or extra.get("category_name")
        )
        channel = _safe_text(row["creator"] or extra.get("channel_title"))
        channel_id = _safe_text(
            extra.get("channel_id")
            or (row["item_id"] if data_type == "subscription" else "")
        )
        term_result = build_youtube_terms(
            action=data_type,
            channel_id=channel_id,
            channel_label=channel,
            title=_safe_text(row["name"]),
            provider_topics=_split_controlled_values(provider_topics),
            uploader_tags=_split_controlled_values(extra.get("tags")),
            policy=YouTubeTermPolicy(
                channel_identity_terms=(
                    self.capabilities.youtube_channel_identity_terms
                    or self.capabilities.youtube_channel_entity_mapping
                ),
                channel_role_resolution=(
                    self.capabilities.youtube_channel_role_resolution
                ),
                uploader_tags=self.capabilities.youtube_uploader_tags,
                written_title_tags=self.capabilities.youtube_title_term_derivation,
                cross_source_fusion=self.capabilities.youtube_cross_source_fusion,
                bio_surface=self.capabilities.youtube_bio_surface,
                icebreaker_surface=self.capabilities.youtube_icebreaker_surface,
            ),
            resolver=self.youtube_channel_resolver,
        )
        terms = list(term_result.terms)
        if not terms:
            return None, "youtube_without_provider_topics"

        occurred_at = _parse_datetime(
            extra.get("watched_at")
            or extra.get("liked_at")
            or extra.get("subscribed_at")
            or extra.get("added_at")
        )
        fingerprint = stable_hash(row["source"], data_type, row["item_id"], occurred_at)
        isrc = normalize_text(extra.get("isrc", ""))
        if isrc:
            lineage = stable_hash("isrc", isrc)
        else:
            lineage = stable_hash("video", row["item_id"] or normalize_text(row["name"]))
        return (
            Observation(
                id=fingerprint[:24],
                source="youtube",
                data_type=data_type,
                action=data_type,
                evidence_channel="video",
                independence_group="video",
                occurred_at=occurred_at,
                collected_at=_parse_datetime(row["collected_at"]),
                terms=tuple(terms),
                record_fingerprint=fingerprint,
                content_lineage=lineage,
                field_quality=0.90 if provider_topics else 0.65,
                action_weight=action_weight,
                privacy_class="public_catalog",
                allow_external_resolution=False,
                metadata={
                    "category_id": extra.get("category_id"),
                    "topic_source": "youtube_provider_metadata",
                    "youtube_channel_id": term_result.channel_id,
                    "channel_role": term_result.channel_role.value,
                    "channel_resolution_used": term_result.resolution_used,
                    "channel_identity_terms_enabled": (
                        term_result.policy.channel_identity_terms
                    ),
                    "channel_role_resolution_enabled": (
                        term_result.policy.channel_role_resolution
                    ),
                    "written_title_tags_enabled": (
                        term_result.policy.written_title_tags
                    ),
                    "cross_source_fusion_approved": (
                        term_result.policy.cross_source_fusion
                    ),
                    "bio_surface_approved": term_result.policy.bio_surface,
                    "icebreaker_surface_approved": (
                        term_result.policy.icebreaker_surface
                    ),
                },
            ),
            "included",
        )

    def _podcast_observation(
        self,
        row: dict[str, str],
        extra: dict[str, str],
        catalog_identity: tuple[str, str, str] | None,
    ) -> Observation | None:
        data_type = row["data_type"]
        podcast_weights = SOURCE_ACTION_WEIGHTS[row["source"]]
        if data_type not in podcast_weights:
            return None
        action_weight = podcast_weights[data_type]
        verified_public_catalog = catalog_identity is not None
        structured_show = _safe_text(extra.get("show") or extra.get("podcast"))
        if data_type in {"show", "followed"}:
            show = structured_show or _safe_text(row["name"]) or _safe_text(row["creator"])
            episode_title = ""
        else:
            show = structured_show or _safe_text(row["creator"])
            episode_title = _safe_text(row["name"])
        host = _safe_text(extra.get("host"))
        categories = _safe_text(extra.get("categories") or extra.get("genre"))
        terms: list[Term] = []
        if show:
            terms.append(Term(
                text=show, normalized=normalize_text(show), role="show",
                source_field="extra.show", type_hint="work",
                safe_for_online=verified_public_catalog,
                safe_for_global_mining=verified_public_catalog,
            ))
        if episode_title and normalize_text(episode_title) != normalize_text(show):
            terms.append(Term(
                text=episode_title, normalized=normalize_text(episode_title), role="episode",
                source_field="name", type_hint="work",
                safe_for_online=verified_public_catalog,
                safe_for_global_mining=verified_public_catalog,
            ))
        if host:
            terms.append(Term(
                text=host, normalized=normalize_text(host), role="host",
                source_field="extra.host", type_hint="creator",
                safe_for_online=verified_public_catalog,
                safe_for_global_mining=verified_public_catalog,
            ))
        for category in _split_controlled_values(categories):
            terms.append(Term(
                text=category, normalized=normalize_text(category), role="category",
                source_field="extra.categories", type_hint="topic",
                safe_for_online=verified_public_catalog,
                safe_for_global_mining=verified_public_catalog,
            ))
        if not terms:
            return None
        occurred_at = _parse_datetime(extra.get("last_played") or extra.get("date_added"))
        fingerprint = stable_hash(row["source"], data_type, row["item_id"], occurred_at)
        episode_guid = extra.get("episode_guid") or extra.get("rss_guid")
        if episode_guid:
            lineage = stable_hash("podcast_guid", episode_guid)
        else:
            lineage = stable_hash("podcast", normalize_text(show), row["item_id"])
        source = row["source"]
        return Observation(
            id=fingerprint[:24], source=source, data_type=data_type, action=data_type,
            evidence_channel="podcast", independence_group="podcast",
            occurred_at=occurred_at, collected_at=_parse_datetime(row["collected_at"]),
            terms=tuple(terms), record_fingerprint=fingerprint, content_lineage=lineage,
            field_quality=0.90 if categories else 0.75, action_weight=action_weight,
            privacy_class="public_catalog",
            allow_external_resolution=verified_public_catalog,
            metadata={
                "has_verified_catalog_id": verified_public_catalog,
                "catalog_namespace": catalog_identity[1] if catalog_identity else None,
            },
        )
