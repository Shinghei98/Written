"""Fail-closed calendar semantics for Written.

This module deliberately does *not* turn arbitrary calendar titles into
ontology terms.  Calendar text is private and heterogeneous: a timed event can
be a flight, but it can just as easily be a birthday, medical appointment,
funeral, friend's event, or work meeting.  Classification therefore follows an
allowlist:

1. hard exclusions run before positive recognition;
2. only a structurally validated flight or leisure booking is emitted;
3. one strong ticket is sufficient for a private Memory candidate;
4. connector mirrors are deduplicated and never count as corroboration;
5. recurrence is counted by journeys, not rows or flight legs; and
6. calendar evidence never infers ``visited``, ``likes``, ``hometown``, or
   ``lives_in``.

The module is self-contained and uses only the Python standard library.  Raw
titles, exact travel times, reservation identifiers, and flight numbers are
not included in surface wording.  Production callers should retain those
fields only in their encrypted private evidence store.
"""

from __future__ import annotations

import hashlib
import hmac
import re
import unicodedata
from collections import defaultdict
from collections.abc import Callable, Collection, Iterable, Mapping, Sequence
from dataclasses import dataclass, replace
from datetime import datetime, timedelta, timezone
from enum import StrEnum
from typing import Any, TypeAlias
from urllib.parse import urlparse


LineageSigner: TypeAlias = Callable[[bytes], str]
PlaceCatalogValue: TypeAlias = str | Sequence[str]


class CalendarDisposition(StrEnum):
    """Exhaustive, auditable outcome of calendar classification."""

    FLIGHT_SEGMENT = "flight_segment"
    BOOKED_ACTIVITY = "booked_activity"
    EXCLUDED_REMOVED = "excluded_removed"
    EXCLUDED_CANCELLED = "excluded_cancelled"
    EXCLUDED_SENSITIVE = "excluded_sensitive"
    EXCLUDED_PERSONAL = "excluded_personal"
    EXCLUDED_WORK = "excluded_work"
    EXCLUDED_CALENDAR = "excluded_calendar"
    EXCLUDED_OWNERSHIP = "excluded_ownership"
    EXCLUDED_UNKNOWN = "excluded_unknown"
    EXCLUDED_MALFORMED = "excluded_malformed"


class Surface(StrEnum):
    MEMORIES = "memories"
    PUBLIC_BIO = "public_bio"
    DYADIC = "dyadic"


@dataclass(frozen=True, slots=True)
class FlightSegment:
    """One scheduled flight leg after structural validation.

    ``predicate`` is intentionally fixed to ``scheduled_travel_to``.  A past
    scheduled event is still not proof of boarding or arrival.
    """

    lineage_id: str
    source_event_ids: tuple[str, ...]
    connector_sources: tuple[str, ...]
    carrier_code: str
    flight_number: str
    origin_place_id: str | None
    destination_place_id: str
    destination_label: str
    starts_at: datetime
    ends_at: datetime
    duration_minutes: int
    reservation_id: str | None = None
    predicate: str = "scheduled_travel_to"
    evidence_confidence: float = 0.92


@dataclass(frozen=True, slots=True)
class BookedActivity:
    """A structured booking, not proof of attendance or preference.

    ``activity_label`` is a controlled category label.  The private source
    title participates only in the HMAC lineage and is not returned by the
    classifier or made available to a surface renderer.
    """

    lineage_id: str
    source_event_ids: tuple[str, ...]
    connector_sources: tuple[str, ...]
    activity_label: str
    place_id: str | None
    place_label: str | None
    starts_at: datetime | None
    ends_at: datetime | None
    vendor_key: str | None
    predicate: str = "booked_activity_at"
    evidence_confidence: float = 0.90


@dataclass(frozen=True, slots=True)
class Journey:
    """A connection-aware sequence of flight segments.

    Intermediate destinations are transit places and contribute zero votes to
    travel recurrence.  Only the terminal destination contributes a journey
    vote.  ``round_trip_group_id`` groups an outbound and return journey; it
    does not identify a home or hometown.
    """

    journey_id: str
    segments: tuple[FlightSegment, ...]
    origin_place_id: str | None
    terminal_place_id: str
    terminal_label: str
    transit_place_ids: tuple[str, ...]
    starts_at: datetime
    ends_at: datetime
    round_trip_group_id: str | None = None


@dataclass(frozen=True, slots=True)
class TravelCandidate:
    """Private, reviewable claim derived from one or more journeys.

    The only automatically emitted predicates are:

    - ``scheduled_travel_to``: one strong ticket is sufficient;
    - ``recurring_travel_connection_for_review``: recurrence across distinct journeys;
    - ``possible_base_for_review``: repeated round-trip topology.

    The latter two are questions for the user, not public assertions.
    """

    place_id: str
    place_label: str
    predicate: str
    journey_votes: int
    recurrence_score: float
    evidence_confidence: float
    first_journey_at: datetime
    last_journey_at: datetime
    evidence_lineages: tuple[str, ...]
    complete_round_trip_count: int = 0
    memories_only: bool = True
    requires_confirmation: bool = True

    @property
    def is_recurring(self) -> bool:
        return self.predicate == "recurring_travel_connection_for_review"

    @property
    def is_possible_base(self) -> bool:
        return self.predicate == "possible_base_for_review"


@dataclass(frozen=True, slots=True)
class CalendarDecision:
    disposition: CalendarDisposition
    reason: str
    flight_segment: FlightSegment | None = None
    booked_activity: BookedActivity | None = None

    @property
    def included(self) -> bool:
        return self.disposition in {
            CalendarDisposition.FLIGHT_SEGMENT,
            CalendarDisposition.BOOKED_ACTIVITY,
        }


@dataclass(frozen=True, slots=True)
class WordingLicense:
    allowed: bool
    surface: Surface
    predicate: str | None
    wording: str | None
    reason: str


_FLIGHT_TITLE_RE = re.compile(
    r"^\s*FLIGHT\s+to\s+(?P<destination>.+?)\s*"
    r"\(\s*(?P<carrier>[A-Z0-9]{2,3})\s*"
    r"(?P<number>\d{1,4}[A-Z]?)\s*\)\s*$",
    re.IGNORECASE,
)

# These filters supplement the more important unknown-by-default rule.  They
# provide stable diagnostic reasons and ensure that a positive-looking title
# cannot bypass a sensitive or work exclusion.
_SENSITIVE_RE = re.compile(
    r"\b(?:therapy|therapist|psychiatr\w*|psycholog\w*|surgery|post[ -]?op|"
    r"outpatient|doctor|dentist|dental|hospital|clinic|diagnos\w*|medication|"
    r"pharmacy|prescription|rehab|physio\w*|physical therapy|counsel(?:or|ing|ling)|"
    r"ob[ -]?gyn|dermatolog\w*|optometr\w*|oncolog\w*|radiolog\w*|mri|"
    r"ct scan|ultrasound|blood test|lab test|vaccine|vaccination|check[ -]?up|"
    r"worship|church|mosque|synagogue|temple|prayer|campaign|ballot|election|"
    r"politic\w*|protest|court|lawyer|attorney|legal|hearing|deposition|visa|"
    r"immigration|asylum)\b",
    re.IGNORECASE,
)

_PERSONAL_RE = re.compile(
    r"\b(?:birthday|bday|funeral|memorial service|wake|burial|cremation|"
    r"condolence|wedding|reception|anniversary|baby shower|graduation|party|"
    r"friend|family|mom|mother|dad|father|sister|brother|aunt|uncle|cousin|"
    r"boyfriend|girlfriend|partner's event)\b",
    re.IGNORECASE,
)

_PERSON_POSSESSIVE_EVENT_RE = re.compile(
    r"\b[A-Z][\w'-]{1,40}(?:'s|’s)\s+"
    r"(?:arrival|departure|birthday|wedding|party|funeral|memorial|dinner|"
    r"lunch|visit|appointment|event|concert|show|performance|reservation|"
    r"tour|ticket|game|recital)\b"
)

_WORK_RE = re.compile(
    r"\b(?:meeting|zoom|microsoft teams|teams call|stand[ -]?up|sync|seminar|"
    r"conference|journal club|lab meeting|office hours|presentation|interview|"
    r"workshop|lecture|class|course|project|committee|research meeting|exam|"
    r"thesis|defen[cs]e|deadline|training|webinar|orientation|job|work|shift|"
    r"one[ -]?on[ -]?one|1:1|jira|support ticket|bug triage)\b",
    re.IGNORECASE,
)

_HOLIDAY_CALENDAR_RE = re.compile(
    r"\b(?:holiday|holidays|birthday|birthdays|observance|observances)\b",
    re.IGNORECASE,
)

_LEISURE_TITLE_RE = re.compile(
    r"\b(?:guided tour|walking tour|food tour|city tour|attraction|museum|"
    r"concert|theatre|theater|cinema|exhibit|aquarium|zoo|theme park|cruise|"
    r"tasting|performance|ballet|opera|live show|comedy show|musical|festival|"
    r"gig|restaurant|dining|dinner reservation|lunch reservation|"
    r"brunch reservation|table reservation|reservation at|hotel stay|hotel|"
    r"lodging)\b",
    re.IGNORECASE,
)

_DINING_TITLE_RE = re.compile(
    r"\b(?:restaurant|dining|dinner reservation|lunch reservation|"
    r"brunch reservation|table reservation|reservation at)\b",
    re.IGNORECASE,
)

_LIVE_EVENT_TITLE_RE = re.compile(
    r"\b(?:concert|theatre|theater|cinema|performance|ballet|opera|"
    r"live show|comedy show|musical|festival|gig)\b",
    re.IGNORECASE,
)

_TICKET_PREFIX_RE = re.compile(r"^\s*Ticket\s*:\s*\S", re.IGNORECASE)

_VERIFIED_VENDOR_HOSTS: dict[str, frozenset[str]] = {
    "airbnb experiences": frozenset({"airbnb.com"}),
    "eventbrite": frozenset({"eventbrite.com"}),
    "opentable": frozenset({"opentable.com"}),
    "resy": frozenset({"resy.com"}),
    "ticketmaster": frozenset({"ticketmaster.com"}),
}

_FORBIDDEN_INFERRED_PREDICATES = frozenset(
    {"visited", "likes", "hometown", "lives_in"}
)

_EXPLICIT_TRAVEL_PREDICATES = frozenset(
    {"visited", "travels_to", "often_travels_to", "hometown", "lives_in", "likes"}
)

_EXPLICIT_ACTIVITY_PREDICATES = frozenset(
    {
        "attended_activity_at",
        "likes_activity",
        "booked_activity_at",
        "booked_event",
        "scheduled_dining",
    }
)


def _controlled_activity_semantics(
    title: str,
    vendor_key: str | None = None,
) -> tuple[str, str]:
    """Return a typed predicate and non-identifying category label."""

    normalized = _normalize(title)
    vendor = _normalize(vendor_key)
    if vendor in {"opentable", "resy"} or _DINING_TITLE_RE.search(title):
        return "scheduled_dining", "Restaurant reservation"
    if vendor in {"eventbrite", "ticketmaster"} or _LIVE_EVENT_TITLE_RE.search(title):
        labels = (
            ("concert", "Concert"),
            ("theatre", "Theatre performance"),
            ("theater", "Theater performance"),
            ("cinema", "Cinema"),
            ("ballet", "Ballet performance"),
            ("opera", "Opera performance"),
            ("comedy show", "Comedy show"),
            ("musical", "Musical performance"),
            ("festival", "Festival"),
            ("gig", "Live performance"),
            ("live show", "Live performance"),
            ("performance", "Performance"),
        )
        return "booked_event", next(
            (label for token, label in labels if token in normalized),
            "Ticketed event",
        )
    labels = (
        ("food tour", "Food tour"),
        ("walking tour", "Walking tour"),
        ("guided tour", "Guided tour"),
        ("city tour", "City tour"),
        ("museum", "Museum visit"),
        ("exhibit", "Exhibition ticket"),
        ("aquarium", "Aquarium visit"),
        ("zoo", "Zoo visit"),
        ("theme park", "Theme park ticket"),
        ("cruise", "Cruise"),
        ("tasting", "Tasting"),
        ("hotel", "Hotel stay"),
        ("lodging", "Hotel stay"),
        ("tour", "Tour"),
        ("attraction", "Attraction ticket"),
    )
    return "booked_activity_at", next(
        (label for token, label in labels if token in normalized),
        "Booked leisure activity",
    )


def _normalize(value: object) -> str:
    text = unicodedata.normalize("NFKC", str(value or "")).casefold().strip()
    chars: list[str] = []
    for char in text:
        category = unicodedata.category(char)
        chars.append(char if category[0] in {"L", "N"} else " ")
    return " ".join("".join(chars).split())


def _parse_semicolon_values(value: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for part in value.split(";") if value else ():
        if "=" not in part:
            continue
        key, item = part.split("=", 1)
        if key.strip():
            result[key.strip()] = item.strip()
    return result


def _extra_from(row: Mapping[str, Any] | None) -> dict[str, str]:
    if not row:
        return {}
    value = row.get("extra", row)
    if isinstance(value, str):
        return _parse_semicolon_values(value)
    if isinstance(value, Mapping):
        return {str(key): str(item) for key, item in value.items()}
    return {}


def _flag_is_true(value: object) -> bool:
    return _normalize(value) in {"1", "true", "yes", "self", "owner"}


def _flag_is_false(value: object) -> bool:
    return _normalize(value) in {"0", "false", "no", "other", "third party"}


def _parse_datetime(value: object) -> datetime | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _duration_minutes(
    extra: Mapping[str, str], starts_at: datetime | None, ends_at: datetime | None
) -> int | None:
    raw = extra.get("duration_min")
    if raw:
        try:
            value = int(round(float(raw)))
        except ValueError:
            return None
    elif starts_at is not None and ends_at is not None:
        value = int(round((ends_at - starts_at).total_seconds() / 60))
    else:
        return None
    return value if 30 <= value <= 1_200 else None


def _build_signer(
    *, lineage_key: bytes | None, lineage_signer: LineageSigner | None
) -> LineageSigner:
    if lineage_key is not None and lineage_signer is not None:
        raise ValueError("provide lineage_key or lineage_signer, not both")
    if lineage_signer is not None:
        return lineage_signer
    if not isinstance(lineage_key, bytes) or not lineage_key:
        raise ValueError("a non-empty HMAC lineage key or signer callback is required")

    def sign(payload: bytes) -> str:
        return hmac.new(lineage_key, payload, hashlib.sha256).hexdigest()

    return sign


def _signed_lineage(signer: LineageSigner, *parts: object) -> str:
    payload = "\x1f".join(str(part or "") for part in parts).encode("utf-8")
    value = signer(payload)
    if not isinstance(value, str) or not value:
        raise ValueError("lineage signer must return a non-empty string")
    return value


class CalendarClassifier:
    """Allowlist-first classifier for private calendar rows."""

    def __init__(
        self,
        *,
        place_catalog: Mapping[str, PlaceCatalogValue],
        carrier_codes: Collection[str],
        recognized_leisure_vendors: Collection[str] = (),
        place_labels: Mapping[str, str] | None = None,
        lineage_key: bytes | None = None,
        lineage_signer: LineageSigner | None = None,
    ) -> None:
        self._signer = _build_signer(
            lineage_key=lineage_key, lineage_signer=lineage_signer
        )
        self._carrier_codes = {_normalize(value).upper() for value in carrier_codes}
        self._vendor_tokens = {
            _normalize(value) for value in recognized_leisure_vendors if _normalize(value)
        }
        self._place_labels = dict(place_labels or {})
        self._place_aliases: dict[str, frozenset[str]] = {}
        for alias, raw_targets in place_catalog.items():
            if isinstance(raw_targets, str):
                targets = (raw_targets,)
            else:
                targets = tuple(raw_targets)
            normalized_alias = _normalize(alias)
            clean_targets = frozenset(str(target) for target in targets if str(target))
            if normalized_alias and clean_targets:
                self._place_aliases[normalized_alias] = clean_targets

    def classify(
        self,
        row: Mapping[str, Any],
        *,
        calendar_metadata: Mapping[str, Any] | None = None,
    ) -> CalendarDecision:
        """Classify one event without emitting arbitrary private text."""

        if not isinstance(row, Mapping) or str(row.get("data_type", "event")) != "event":
            return CalendarDecision(
                CalendarDisposition.EXCLUDED_MALFORMED,
                "not_a_calendar_event",
            )

        extra = _extra_from(row)
        title = str(row.get("name") or "").strip()
        detail = str(row.get("detail") or "").strip()
        searchable = " ".join((title, detail))

        # Ordered hard exclusions.  A valid-looking ticket cannot bypass these.
        if "removed_by_user" in extra:
            return CalendarDecision(
                CalendarDisposition.EXCLUDED_REMOVED, "user_removed_event"
            )
        if extra.get("cancelled") == "1" or _normalize(extra.get("status")) == "cancelled":
            return CalendarDecision(
                CalendarDisposition.EXCLUDED_CANCELLED, "cancelled_event"
            )
        # Container provenance precedes title interpretation. A subscribed
        # holiday/birthday feed must not bypass the boundary by looking like a
        # commercial ticket or flight.
        if self._calendar_is_excluded(calendar_metadata, extra):
            return CalendarDecision(
                CalendarDisposition.EXCLUDED_CALENDAR,
                "subscribed_birthday_or_holiday_calendar",
            )
        if _SENSITIVE_RE.search(searchable):
            return CalendarDecision(
                CalendarDisposition.EXCLUDED_SENSITIVE,
                "medical_religious_political_or_legal_event",
            )
        if _PERSONAL_RE.search(searchable) or _PERSON_POSSESSIVE_EVENT_RE.search(searchable):
            return CalendarDecision(
                CalendarDisposition.EXCLUDED_PERSONAL,
                "birthday_funeral_wedding_or_third_party_event",
            )
        if _WORK_RE.search(searchable):
            return CalendarDecision(
                CalendarDisposition.EXCLUDED_WORK, "work_or_school_event"
            )
        ownership, user_owned_artifact = self._ownership_state(
            row, extra, calendar_metadata
        )
        # Explicit evidence that the event belongs to someone else always
        # blocks inference unless a separate typed artifact says the user owns
        # this booking.  This diagnostic is evaluated before title parsing so
        # a shared ticket cannot masquerade as the user's travel.
        if ownership == "negative" and not user_owned_artifact:
            return CalendarDecision(
                CalendarDisposition.EXCLUDED_OWNERSHIP,
                "event_not_owned_or_attendance_declined",
            )

        segment, flight_reason = self._parse_flight(row, extra, title, detail)
        if segment is not None:
            return CalendarDecision(
                CalendarDisposition.FLIGHT_SEGMENT,
                "strong_structured_flight",
                flight_segment=segment,
            )

        activity = self._parse_booked_activity(row, extra, title, detail)
        if activity is not None:
            # Unknown legacy ownership may pass only this narrow strong-ticket
            # allowlist.  The parser already requires a recognized leisure
            # vendor or strong ticket/tour/attraction shape plus a booking
            # artifact.  Explicit negative ownership, declined attendance, or
            # a third-party shared calendar was rejected above.
            return CalendarDecision(
                CalendarDisposition.BOOKED_ACTIVITY,
                "strong_structured_leisure_booking",
                booked_activity=activity,
            )

        return CalendarDecision(
            CalendarDisposition.EXCLUDED_UNKNOWN,
            flight_reason or "calendar_event_not_allowlisted",
        )

    def _ownership_state(
        self,
        row: Mapping[str, Any],
        extra: Mapping[str, str],
        calendar_metadata: Mapping[str, Any] | None,
    ) -> tuple[str, bool]:
        """Return positive/negative/unknown ownership plus artifact status.

        The exporter should eventually provide these typed fields on every
        event.  Their absence is treated as unknown, never implicitly true.
        """

        calendar_extra = _extra_from(calendar_metadata)
        values: dict[str, object] = {**calendar_extra, **extra}
        for key in (
            "owner_is_user",
            "organizer_self",
            "creator_self",
            "calendar_owner_is_user",
            "shared_third_party",
            "attendee_declined",
            "attendee_status",
            "user_owned_booking_artifact",
            "booking_owned_by_user",
        ):
            if key in row:
                values[key] = row[key]
            if calendar_metadata and key in calendar_metadata:
                values[key] = calendar_metadata[key]

        artifact = any(
            _flag_is_true(values.get(key))
            for key in ("user_owned_booking_artifact", "booking_owned_by_user")
        )
        declined = _flag_is_true(values.get("attendee_declined")) or _normalize(
            values.get("attendee_status")
        ) == "declined"
        shared_third_party = _flag_is_true(values.get("shared_third_party"))
        explicit_false = any(
            _flag_is_false(values.get(key))
            for key in (
                "owner_is_user",
                "organizer_self",
                "creator_self",
                "calendar_owner_is_user",
            )
            if key in values
        )
        if declined or shared_third_party or explicit_false:
            return "negative", artifact
        explicit_true = any(
            _flag_is_true(values.get(key))
            for key in (
                "owner_is_user",
                "organizer_self",
                "creator_self",
                "calendar_owner_is_user",
            )
            if key in values
        )
        return ("positive" if explicit_true or artifact else "unknown"), artifact

    def build_journeys(
        self,
        segments: Iterable[FlightSegment],
        *,
        booked_activities: Iterable[BookedActivity] = (),
    ) -> tuple[Journey, ...]:
        return build_journeys(
            segments,
            booked_activities=booked_activities,
            lineage_signer=self._signer,
        )

    def travel_candidates(
        self,
        journeys: Iterable[Journey],
        *,
        record_ends_at: datetime | None = None,
    ) -> tuple[TravelCandidate, ...]:
        return derive_travel_candidates(journeys, record_ends_at=record_ends_at)

    def _calendar_is_excluded(
        self,
        calendar_metadata: Mapping[str, Any] | None,
        event_extra: Mapping[str, str],
    ) -> bool:
        metadata = _extra_from(calendar_metadata)
        if calendar_metadata:
            for field in ("name", "calendar_name"):
                if field in calendar_metadata:
                    metadata[field] = str(calendar_metadata[field])
        calendar_type = _normalize(
            metadata.get("type")
            or metadata.get("calendar_type")
            or metadata.get("cal_type")
            or event_extra.get("calendar_type")
            or event_extra.get("cal_type")
        )
        calendar_name = str(
            metadata.get("name")
            or metadata.get("calendar_name")
            or event_extra.get("calendar")
            or ""
        )
        return (
            metadata.get("subscribed") == "1"
            or calendar_type in {"birthday", "subscription", "holiday", "holidays"}
            or bool(_HOLIDAY_CALENDAR_RE.search(calendar_name))
        )

    def _resolve_place(self, *references: object) -> tuple[str, str] | None:
        candidates: set[str] = set()
        for reference in references:
            normalized = _normalize(reference)
            if not normalized:
                continue
            candidates.update(self._place_aliases.get(normalized, ()))
            tokens = set(normalized.split())
            for alias, targets in self._place_aliases.items():
                # Codes and whole-word multi-token aliases can be recovered from
                # a private location string without sending it to a resolver.
                if (len(alias) == 3 and alias in tokens) or (
                    " " in alias
                    and re.search(rf"(?:^|\s){re.escape(alias)}(?:$|\s)", normalized)
                ):
                    candidates.update(targets)
        if len(candidates) != 1:
            return None
        place_id = next(iter(candidates))
        return place_id, self._place_labels.get(place_id, place_id)

    def _parse_flight(
        self,
        row: Mapping[str, Any],
        extra: Mapping[str, str],
        title: str,
        detail: str,
    ) -> tuple[FlightSegment | None, str | None]:
        match = _FLIGHT_TITLE_RE.fullmatch(title)
        if match is None:
            if re.search(r"\bflight\b", title, re.IGNORECASE):
                return None, "generic_or_malformed_flight_title"
            return None, None
        if extra.get("all_day") == "1":
            return None, "all_day_flight_is_not_structured"

        carrier = _normalize(match.group("carrier")).upper()
        if carrier not in self._carrier_codes:
            return None, "unknown_carrier_code"

        destination = self._resolve_place(
            match.group("destination"),
            extra.get("destination_code"),
            extra.get("arrival_airport"),
            extra.get("destination_airport"),
        )
        if destination is None:
            return None, "ambiguous_or_unknown_destination"

        starts_at = _parse_datetime(extra.get("start"))
        ends_at = _parse_datetime(extra.get("end"))
        duration = _duration_minutes(extra, starts_at, ends_at)
        if starts_at is None or ends_at is None or ends_at <= starts_at or duration is None:
            return None, "implausible_or_missing_flight_time"

        explicit_origin_references = (
            extra.get("origin_code"),
            extra.get("departure_airport"),
            extra.get("origin_airport"),
        )
        # The finalized legacy exporter writes the destination in the title
        # (``FLIGHT to ...``) and the *origin* city/airport in ``detail``.  New
        # exporters should send typed origin fields; detail is only a fallback
        # when those fields are absent.  Treating detail as destination would
        # reverse or ambiguate every legacy leg.
        origin = self._resolve_place(
            *(explicit_origin_references if any(explicit_origin_references) else (detail,))
        )
        # **A place the gazetteer does not know is still the same place twice.**
        # Chaining asks whether this leg leaves where the last one landed, and
        # that question needs identity, not a name — so an unresolved origin
        # takes an opaque continuity key derived from its own text. It carries
        # no label, so `derive_travel_candidates` can never mint it and no
        # surface can ever draw it; it exists only to let two legs recognise
        # each other. Without it every leg out of a city missing from the
        # catalogue starts a new journey, and a connection reads as a
        # destination.
        origin_id = (
            origin[0]
            if origin is not None
            else _continuity_key(
                *(explicit_origin_references if any(explicit_origin_references) else (detail,))
            )
        )
        number = match.group("number").upper()
        reservation_id = (
            extra.get("reservation_id")
            or extra.get("booking_reference")
            or extra.get("itinerary_id")
            or None
        )
        lineage = _signed_lineage(
            self._signer,
            "flight_segment",
            carrier,
            number,
            starts_at.isoformat(),
            destination[0],
        )
        source = str(row.get("source") or "calendar")
        event_id = str(row.get("item_id") or lineage)
        return (
            FlightSegment(
                lineage_id=lineage,
                source_event_ids=(event_id,),
                connector_sources=(source,),
                carrier_code=carrier,
                flight_number=f"{carrier}{number}",
                origin_place_id=origin_id,
                destination_place_id=destination[0],
                destination_label=destination[1],
                starts_at=starts_at,
                ends_at=ends_at,
                duration_minutes=duration,
                reservation_id=reservation_id,
            ),
            None,
        )

    def _parse_booked_activity(
        self,
        row: Mapping[str, Any],
        extra: Mapping[str, str],
        title: str,
        detail: str,
    ) -> BookedActivity | None:
        # Vendor recognition is an identity check, not a substring search.
        # Otherwise an unrelated hostname such as ``heresy.example`` would
        # accidentally match the allowlisted vendor ``resy``.
        creator_identities = {
            _normalize(value)
            for value in (row.get("creator"), extra.get("organizer"))
            if _normalize(value)
        }
        raw_url = str(extra.get("url") or "").strip()
        parsed_url = urlparse(raw_url if "://" in raw_url else f"//{raw_url}")
        hostname = str(parsed_url.hostname or "").casefold().rstrip(".")

        def vendor_matches(token: str) -> bool:
            if token in creator_identities:
                return True
            allowed_hosts = _VERIFIED_VENDOR_HOSTS.get(token, frozenset())
            return any(
                hostname == allowed_host
                or hostname.endswith(f".{allowed_host}")
                for allowed_host in allowed_hosts
            )

        vendor = next(
            (
                token
                for token in sorted(self._vendor_tokens, key=len, reverse=True)
                if token and vendor_matches(token)
            ),
            None,
        )
        strong_title = bool(
            _TICKET_PREFIX_RE.search(title) or _LEISURE_TITLE_RE.search(title)
        )
        has_booking_artifact = (
            extra.get("booked") == "1"
            or bool(extra.get("url"))
            or bool(_TICKET_PREFIX_RE.search(title))
        )
        # `booked=1` alone is never semantic evidence.
        if not has_booking_artifact or not (vendor or strong_title):
            return None

        starts_at = _parse_datetime(extra.get("start"))
        ends_at = _parse_datetime(extra.get("end"))
        place = self._resolve_place(
            detail,
            extra.get("venue_code"),
            extra.get("place_code"),
            extra.get("city_code"),
        )
        place_id, place_label = place if place is not None else (None, None)
        lineage = _signed_lineage(
            self._signer,
            "booked_activity",
            _normalize(title),
            starts_at.isoformat() if starts_at else "",
            ends_at.isoformat() if ends_at else "",
            place_id,
            vendor,
        )
        source = str(row.get("source") or "calendar")
        event_id = str(row.get("item_id") or lineage)
        predicate, activity_label = _controlled_activity_semantics(title, vendor)
        return BookedActivity(
            lineage_id=lineage,
            source_event_ids=(event_id,),
            connector_sources=(source,),
            activity_label=activity_label,
            place_id=place_id,
            place_label=place_label,
            starts_at=starts_at,
            ends_at=ends_at,
            vendor_key=vendor,
            predicate=predicate,
        )


def deduplicate_flight_segments(
    segments: Iterable[FlightSegment],
) -> tuple[FlightSegment, ...]:
    """Merge connector mirrors without treating them as independent proof."""

    grouped: dict[str, list[FlightSegment]] = defaultdict(list)
    for segment in segments:
        grouped[segment.lineage_id].append(segment)

    result: list[FlightSegment] = []
    for lineage_id, copies in grouped.items():
        copies.sort(key=lambda item: (item.starts_at, item.source_event_ids))
        first = copies[0]
        origins = {item.origin_place_id for item in copies if item.origin_place_id}
        if len(origins) > 1:
            # Conflicting mirrors are not safe to collapse into one route.
            result.extend(copies)
            continue
        result.append(
            replace(
                first,
                source_event_ids=tuple(
                    sorted({value for item in copies for value in item.source_event_ids})
                ),
                connector_sources=tuple(
                    sorted({value for item in copies for value in item.connector_sources})
                ),
                origin_place_id=next(iter(origins), first.origin_place_id),
                evidence_confidence=max(item.evidence_confidence for item in copies),
            )
        )
    return tuple(sorted(result, key=lambda item: (item.starts_at, item.lineage_id)))


#: The prefix marking a place identified only by its own text. Nothing may
#: label, mint or display one; `_OFFLINE_CALENDAR_PLACE_LABELS` deliberately has
#: no entry, so every lookup misses and the place is dropped at the surface.
UNRESOLVED_PLACE_PREFIX = "place:unresolved:"


def _continuity_key(*references: object) -> str | None:
    """A stable, opaque id for a place the catalogue could not name.

    Derived from the normalised reference text so the same airport written the
    same way twice compares equal, and digested so no fragment of a location
    string survives into anything that is stored.
    """

    for reference in references:
        normalized = _normalize(reference)
        if not normalized:
            continue
        # Trailing IATA codes are dropped so `Boston BOS` and `Boston` agree.
        normalized = re.sub(r"\s+[a-z]{3}$", "", normalized).strip()
        if not normalized:
            continue
        digest = hashlib.sha256(normalized.encode("utf-8")).hexdigest()[:16]
        return f"{UNRESOLVED_PLACE_PREFIX}{digest}"
    return None


def _same_reservation(left: FlightSegment, right: FlightSegment) -> bool:
    return bool(
        left.reservation_id
        and right.reservation_id
        and hmac.compare_digest(left.reservation_id, right.reservation_id)
    )


def _activity_makes_stopover(
    left: FlightSegment,
    right: FlightSegment,
    booked_activities: Sequence[BookedActivity],
) -> bool:
    """A local booking during a connection turns the place into a stopover."""

    for activity in booked_activities:
        if activity.place_id != left.destination_place_id or activity.starts_at is None:
            continue
        activity_end = activity.ends_at or activity.starts_at
        if activity.starts_at < right.starts_at and activity_end > left.ends_at:
            return True
        if left.ends_at <= activity.starts_at < right.starts_at:
            return True
    return False


#: **The line between a connection and a stopover is IATA's, not ours.** Over
#: twenty-four hours between arriving and leaving again is a stopover — you were
#: in that place — and under it you were changing planes. The number is taken
#: from an external convention on purpose: a threshold read off the libraries
#: in front of us would be fitted to them, which is the mistake `0223` froze the
#: work rule to avoid.
#:
#: Measured against a labelled itinerary of 36 flights, the observed gaps are
#: 1.4-2.7 hours for connections and 41 hours or more for stays. **Nothing lies
#: between**, so any value from 3 to 40 hours would answer identically — which
#: is what makes 24 a rule the data agrees with rather than a line drawn round
#: it.
CONNECTION_MAX_GAP = timedelta(hours=24)

#: A connection needs long enough to change planes and no longer.
CONNECTION_MIN_GAP = timedelta(minutes=30)


def _can_chain(
    left: FlightSegment,
    right: FlightSegment,
    booked_activities: Sequence[BookedActivity] = (),
) -> bool:
    gap = right.starts_at - left.ends_at
    if gap < CONNECTION_MIN_GAP or gap > CONNECTION_MAX_GAP:
        return False
    same_reservation = _same_reservation(left, right)
    spatially_continuous = bool(
        right.origin_place_id
        and right.origin_place_id == left.destination_place_id
    )
    if left.destination_place_id and right.origin_place_id and not spatially_continuous:
        return False
    if _activity_makes_stopover(left, right, booked_activities):
        return False
    # **Past eighteen hours spatial continuity alone is not enough.** A day in
    # a city on two separately booked tickets is a stopover somebody arranged,
    # not a gate change — the older rule this preserves, now sitting inside the
    # twenty-four-hour bound rather than the thirty-six-hour one.
    if gap <= timedelta(hours=18):
        return spatially_continuous or same_reservation
    return same_reservation and (spatially_continuous or right.origin_place_id is None)


def build_journeys(
    segments: Iterable[FlightSegment],
    *,
    booked_activities: Iterable[BookedActivity] = (),
    lineage_key: bytes | None = None,
    lineage_signer: LineageSigner | None = None,
) -> tuple[Journey, ...]:
    """Deduplicate legs, chain connections, and group round trips."""

    signer = _build_signer(lineage_key=lineage_key, lineage_signer=lineage_signer)
    ordered = list(deduplicate_flight_segments(segments))
    activities = tuple(booked_activities)
    chains: list[list[FlightSegment]] = []
    for segment in ordered:
        if chains and _can_chain(chains[-1][-1], segment, activities):
            chains[-1].append(segment)
        else:
            chains.append([segment])

    journeys: list[Journey] = []
    for chain in chains:
        first, last = chain[0], chain[-1]
        transit: list[str] = []
        for segment in chain[:-1]:
            if segment.destination_place_id not in transit:
                transit.append(segment.destination_place_id)
        journey_id = _signed_lineage(
            signer, "journey", *(segment.lineage_id for segment in chain)
        )
        journeys.append(
            Journey(
                journey_id=journey_id,
                segments=tuple(chain),
                origin_place_id=first.origin_place_id,
                terminal_place_id=last.destination_place_id,
                terminal_label=last.destination_label,
                transit_place_ids=tuple(transit),
                starts_at=first.starts_at,
                ends_at=last.ends_at,
            )
        )

    # Pair the earliest compatible outbound and return journeys.  A round trip
    # expresses route topology only; it is not a home assertion.
    used: set[int] = set()
    for left_index, left in enumerate(journeys):
        if left_index in used or left.origin_place_id is None:
            continue
        for right_index in range(left_index + 1, len(journeys)):
            if right_index in used:
                continue
            right = journeys[right_index]
            if (
                right.starts_at >= left.ends_at
                and right.origin_place_id == left.terminal_place_id
                and right.terminal_place_id == left.origin_place_id
            ):
                group_id = _signed_lineage(
                    signer, "round_trip", left.journey_id, right.journey_id
                )
                journeys[left_index] = replace(left, round_trip_group_id=group_id)
                journeys[right_index] = replace(right, round_trip_group_id=group_id)
                used.update({left_index, right_index})
                break

    return tuple(journeys)


def _recurrence_score(votes: int, first: datetime, last: datetime) -> float:
    if votes < 2:
        return 0.0
    span_days = max(0.0, (last - first).total_seconds() / 86_400)
    frequency = min(1.0, (votes - 1) / 2)
    temporal_support = min(1.0, span_days / 90)
    return round(frequency * temporal_support, 6)


def classify_place_roles(
    journeys: Iterable[Journey],
    *,
    record_ends_at: datetime | None = None,
) -> dict[str, str]:
    """Which places somebody was in, and which they merely passed through.

    **Two clauses, and between them they need no gazetteer, no airline hub
    table and no list of cities.**

    - **You were somewhere if you departed from it.** Boarding proves presence
      whatever brought you there — a train, a car, a leg nobody saved. This is
      why an origin the calendar never records an arrival to still counts.
    - **You were somewhere if you arrived and later left again**, the later
      departure being what distinguishes a stay from a change of planes.
      Anything under `CONNECTION_MAX_GAP` has already been folded into one
      journey by `_can_chain`, so a terminal a *subsequent* journey departs
      from was somewhere you stayed.

    Everything else is transit: the middle of a chain, and — the clause that is
    easy to miss — **a terminal no later journey ever departs from, where the
    record continues past it.** An arrival with no onward leg is not evidence
    of a stay; it is what a connection looks like when only the ticketed
    long-haul leg was saved, and every such place in the itinerary this rule
    was checked against was one.

    **`record_ends_at` is what stops that clause inferring absence from
    omission.** A missing return leg means something only when we can see past
    the arrival and still find nothing; at the edge of what was captured it
    means we stopped looking. So a terminal reached at the end of the record
    stays a destination, and one arrival is still evidence of travel — which is
    the same refusal that makes every ingestion scope `partial` rather than
    `complete`. Callers that know the calendar's true horizon should pass it;
    the default is the last journey in hand, which is the conservative reading.

    **The verdict is per place across the whole record, and presence wins.** A
    city can be a connection on one trip and a destination on another — the
    same airport twice, once with two hours in it and once with four days — and
    the second is a fact the first does not contradict. That is the same shape
    as participation outranking spectating in `0200`.
    """

    # **Deduplicated by what the journey is, not by what it was signed with.**
    # `journey_id` comes from a signer the caller supplies, and a caller that
    # supplies a constant — the review harness did — would collapse every trip
    # into one and answer with a single place. The segments are the identity.
    ordered = sorted(
        {
            tuple(segment.lineage_id for segment in journey.segments)
            + (journey.starts_at, journey.terminal_place_id): journey
            for journey in journeys
        }.values(),
        key=lambda item: (item.starts_at, item.terminal_place_id or ""),
    )
    horizon = record_ends_at or (ordered[-1].ends_at if ordered else None)
    roles: dict[str, str] = {}

    def mark(place_id: str | None, role: str) -> None:
        if not place_id:
            return
        if roles.get(place_id) == "destination":
            return
        roles[place_id] = role

    for journey in ordered:
        for place_id in journey.transit_place_ids:
            mark(place_id, "transit")
    for journey in ordered:
        mark(journey.origin_place_id, "destination")
        departed_later = any(
            other.origin_place_id == journey.terminal_place_id
            and other.starts_at >= journey.ends_at
            for other in ordered
        )
        # No onward leg *and* nothing observed afterwards is a silence we are
        # not entitled to read, so the arrival stands as a destination.
        observed_afterwards = horizon is not None and horizon > journey.ends_at
        mark(
            journey.terminal_place_id,
            "destination" if departed_later or not observed_afterwards else "transit",
        )
    return roles


def derive_travel_candidates(
    journeys: Iterable[Journey],
    *,
    record_ends_at: datetime | None = None,
) -> tuple[TravelCandidate, ...]:
    """Create private review candidates with one maximum vote per journey."""

    unique_journeys = {journey.journey_id: journey for journey in journeys}
    # **A place passed through is not a place somebody went.** The role is
    # decided across the whole record rather than per journey, so a city that
    # is a connection once and a destination another time keeps its candidate.
    roles = classify_place_roles(
        unique_journeys.values(), record_ends_at=record_ends_at
    )
    by_terminal: dict[str, list[Journey]] = defaultdict(list)
    for journey in unique_journeys.values():
        if roles.get(journey.terminal_place_id) != "destination":
            continue
        by_terminal[journey.terminal_place_id].append(journey)

    candidates: list[TravelCandidate] = []
    for place_id, place_journeys in by_terminal.items():
        place_journeys.sort(key=lambda item: item.starts_at)
        votes = len(place_journeys)
        first, last = place_journeys[0], place_journeys[-1]
        evidence = tuple(sorted({item.journey_id for item in place_journeys}))
        complete_round_trips = len(
            {
                item.round_trip_group_id
                for item in place_journeys
                if item.round_trip_group_id is not None
            }
        )
        confidence = max(
            segment.evidence_confidence
            for journey in place_journeys
            for segment in journey.segments
        )
        score = _recurrence_score(votes, first.starts_at, last.starts_at)
        candidates.append(
            TravelCandidate(
                place_id=place_id,
                place_label=last.terminal_label,
                predicate="scheduled_travel_to",
                journey_votes=votes,
                recurrence_score=score,
                evidence_confidence=confidence,
                first_journey_at=first.starts_at,
                last_journey_at=last.starts_at,
                evidence_lineages=evidence,
                complete_round_trip_count=complete_round_trips,
            )
        )
        # Two distinct journeys are enough to ask a neutral recurrence
        # question only when the total span is at least 90 days.  The 30-day
        # separation is therefore necessary but not independently sufficient.
        if (
            votes >= 2
            and (last.starts_at - first.starts_at) >= timedelta(days=90)
        ):
            candidates.append(
                TravelCandidate(
                    place_id=place_id,
                    place_label=last.terminal_label,
                    predicate="recurring_travel_connection_for_review",
                    journey_votes=votes,
                    recurrence_score=score,
                    evidence_confidence=min(0.88, confidence),
                    first_journey_at=first.starts_at,
                    last_journey_at=last.starts_at,
                    evidence_lineages=evidence,
                    complete_round_trip_count=complete_round_trips,
                )
            )

    # A possible base requires at least two independent round-trip groups over
    # time.  It remains a private question and is never called a hometown.
    round_trip_members: dict[str, list[Journey]] = defaultdict(list)
    for journey in unique_journeys.values():
        if journey.round_trip_group_id:
            round_trip_members[journey.round_trip_group_id].append(journey)
    base_groups: dict[str, list[tuple[str, datetime, str]]] = defaultdict(list)
    for group_id, members in round_trip_members.items():
        members.sort(key=lambda item: item.starts_at)
        if len(members) != 2:
            continue
        outbound, returned = members
        if (
            outbound.origin_place_id
            and returned.terminal_place_id == outbound.origin_place_id
        ):
            base_groups[outbound.origin_place_id].append(
                (group_id, outbound.starts_at, returned.terminal_label)
            )
    for place_id, groups in base_groups.items():
        groups.sort(key=lambda item: item[1])
        if len(groups) < 2 or groups[-1][1] - groups[0][1] < timedelta(days=90):
            continue
        score = _recurrence_score(len(groups), groups[0][1], groups[-1][1])
        candidates.append(
            TravelCandidate(
                place_id=place_id,
                place_label=groups[-1][2],
                predicate="possible_base_for_review",
                journey_votes=len(groups),
                recurrence_score=score,
                evidence_confidence=min(0.78, 0.60 + 0.08 * len(groups)),
                first_journey_at=groups[0][1],
                last_journey_at=groups[-1][1],
                evidence_lineages=tuple(group[0] for group in groups),
                complete_round_trip_count=len(groups),
            )
        )

    if any(item.predicate in _FORBIDDEN_INFERRED_PREDICATES for item in candidates):
        raise AssertionError("calendar inference emitted a prohibited predicate")
    return tuple(sorted(candidates, key=lambda item: (item.place_id, item.predicate)))


def surface_wording_license(
    evidence: FlightSegment | BookedActivity | TravelCandidate,
    surface: Surface | str,
    *,
    now: datetime | None = None,
    confirmed_predicate: str | None = None,
    explicit_confirmation: bool = False,
    surface_permission: bool = False,
) -> WordingLicense:
    """Return the strongest wording licensed by validated evidence.

    Unconfirmed calendar evidence is Memories-only.  Public bio and dyadic
    surfaces additionally require an explicit predicate confirmation and an
    independent surface permission.  This helper never upgrades a booking to
    attendance or a flight to a visit by itself.
    """

    selected_surface = Surface(surface)
    reference_time = now or datetime.now(timezone.utc)
    if reference_time.tzinfo is None:
        reference_time = reference_time.replace(tzinfo=timezone.utc)
    else:
        reference_time = reference_time.astimezone(timezone.utc)

    if confirmed_predicate is not None and not explicit_confirmation:
        return WordingLicense(
            False,
            selected_surface,
            None,
            None,
            "predicate_was_not_explicitly_confirmed",
        )

    if confirmed_predicate is not None:
        allowed_predicates = (
            _EXPLICIT_ACTIVITY_PREDICATES
            if isinstance(evidence, BookedActivity)
            else _EXPLICIT_TRAVEL_PREDICATES
        )
        if confirmed_predicate not in allowed_predicates:
            return WordingLicense(
                False,
                selected_surface,
                None,
                None,
                "confirmed_predicate_is_incompatible_with_evidence_type",
            )
        if isinstance(evidence, FlightSegment) and evidence.starts_at > reference_time:
            if confirmed_predicate == "visited":
                return WordingLicense(
                    False,
                    selected_surface,
                    None,
                    None,
                    "future_flight_cannot_support_visited_wording",
                )
        if confirmed_predicate == "often_travels_to":
            if not isinstance(evidence, TravelCandidate):
                return WordingLicense(
                    False,
                    selected_surface,
                    None,
                    None,
                    "often_travels_requires_aggregated_journeys",
                )
            span = evidence.last_journey_at - evidence.first_journey_at
            if (
                evidence.journey_votes < 3
                or span < timedelta(days=180)
                or evidence.complete_round_trip_count < 2
            ):
                return WordingLicense(
                    False,
                    selected_surface,
                    None,
                    None,
                    "often_travels_requires_three_journeys_two_round_trips_over_180_days",
                )
        if selected_surface is not Surface.MEMORIES and not surface_permission:
            return WordingLicense(
                False,
                selected_surface,
                None,
                None,
                "public_or_dyadic_surface_permission_missing",
            )
        subject = (
            evidence.activity_label
            if isinstance(evidence, BookedActivity)
            else evidence.destination_label
            if isinstance(evidence, FlightSegment)
            else evidence.place_label
        )
        return WordingLicense(
            True,
            selected_surface,
            confirmed_predicate,
            f"User-confirmed {confirmed_predicate.replace('_', ' ')}: {subject}",
            "explicitly_confirmed_predicate",
        )

    if selected_surface is not Surface.MEMORIES:
        return WordingLicense(
            False,
            selected_surface,
            None,
            None,
            "unconfirmed_calendar_evidence_is_memories_only",
        )

    if isinstance(evidence, FlightSegment):
        future = evidence.starts_at > reference_time
        wording = (
            f"Travel scheduled to {evidence.destination_label}"
            if future
            else f"A flight to {evidence.destination_label} was scheduled"
        )
        predicate = evidence.predicate
    elif isinstance(evidence, BookedActivity):
        future = bool(evidence.starts_at and evidence.starts_at > reference_time)
        wording = (
            f"Booked: {evidence.activity_label}"
            if future
            else f"A booking appeared for {evidence.activity_label}"
        )
        predicate = evidence.predicate
    else:
        predicate = evidence.predicate
        if predicate == "scheduled_travel_to":
            wording = f"Travel to {evidence.place_label} appeared in your calendar"
        elif predicate == "recurring_travel_connection_for_review":
            wording = f"Does {evidence.place_label} recur in your travel plans?"
        elif predicate == "possible_base_for_review":
            wording = f"Is {evidence.place_label} a recurring travel base for you?"
        else:  # Defensive fail-closed branch for future predicate additions.
            return WordingLicense(
                False,
                selected_surface,
                None,
                None,
                "unknown_calendar_candidate_predicate",
            )
    return WordingLicense(
        True,
        selected_surface,
        predicate,
        wording,
        "private_review_wording",
    )


__all__ = [
    "BookedActivity",
    "CalendarClassifier",
    "CalendarDecision",
    "CalendarDisposition",
    "FlightSegment",
    "Journey",
    "Surface",
    "TravelCandidate",
    "WordingLicense",
    "build_journeys",
    "deduplicate_flight_segments",
    "derive_travel_candidates",
    "surface_wording_license",
]
