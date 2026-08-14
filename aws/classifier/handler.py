"""The Calendar classifier, as a Lambda ingestion can call.

**Why this exists as a separate function.** Observations must be written by
ingestion, inside the still-`running` capture run — `guard_observation_ingestion
_run` enforces it and `run_kind` allows only `connector` and `legacy_backfill`,
so there is no reprocessing run a worker could open. Classification therefore has
to happen where the plaintext is, at ingestion time. Ingestion is JavaScript and
`written_ontology.calendar_semantics` is 1,283 lines of Python, so the two meet
over an in-account invoke rather than by porting the classifier — the same
argument that vendored the worker's queue instead of rewriting it. §7 permits
*the current Calendar classifier* over Calendar rows, and a reimplementation
would not be it.

**It returns dispositions, never content.** The classifier's own docstring makes
the point: the private source title *"participates only in the HMAC lineage and
is not returned by the classifier"*. What crosses back is a state, an artifact
type from a closed set, and a 64-hex HMAC — which is exactly the payload
`private_observation_projection_is_valid_v03` will accept and nothing more. A
calendar title enters this function and does not leave it.

**Nothing here is logged.** §12 forbids plaintext in logs, and an event title is
the most identifying string this system handles. Errors report counts and codes.
"""

from __future__ import annotations

import hashlib
import hmac
import os
import re
from typing import Any

import boto3

from written_ontology.calendar_semantics import (
    CalendarClassifier,
    CalendarDisposition,
)
from written_ontology.export_adapter import (
    _OFFLINE_CALENDAR_CARRIERS,
    _OFFLINE_CALENDAR_PLACE_CATALOG,
    _OFFLINE_CALENDAR_PLACE_LABELS,
    _OFFLINE_LEISURE_VENDORS,
)

REGION = os.environ.get("AWS_REGION", "us-east-1")
LINEAGE_KEY_ARN = os.environ["LINEAGE_KEY_ARN"]

_kms = boto3.client("kms", region_name=REGION)

# Module scope so a warm invocation reuses it: deriving it is a KMS round trip
# and the answer is the same every time.
_lineage_key: bytes | None = None

SCHEMA_VERSION = "calendar-v03"

# A place concept key and nothing that could be a sentence.
_PLACE_KEY_RE = re.compile(r"^place:[a-z0-9_]{1,80}$")


def lineage_key() -> bytes:
    """The HMAC key, derived from KMS exactly as ingestion derives its own.

    **A different key from the payload key**, which §12 requires: these hashes
    are computed over predictable inputs, so anybody holding the payload key
    could otherwise test guesses against them. Same ARN and same label as
    `lineageKey()` in `aws/ingestion/index.mjs`, because it is the same subkey.
    """
    global _lineage_key
    if _lineage_key is None:
        mac = _kms.generate_mac(
            KeyId=LINEAGE_KEY_ARN,
            MacAlgorithm="HMAC_SHA_256",
            Message=b"written:lineage-subkey:v1",
        )["Mac"]
        _lineage_key = bytes(mac)
    return _lineage_key


def signer_for(user_id: str):
    """A lineage signer salted with the user id.

    **Salted for the reason `sourceItemHmac` is.** Without it two people holding
    the same flight would produce the same `content_lineage_hmac`, which is a
    cross-account correlation handle sitting in a column that exists to be
    joined on. The package takes a signer callback precisely so this can be
    decided by the caller, so no fork of the classifier is needed.
    """
    key = lineage_key()

    def sign(payload: bytes) -> str:
        return hmac.new(key, user_id.encode("utf-8") + b"\x1f" + payload,
                        hashlib.sha256).hexdigest()

    return sign


# Places a *ticket* names, as opposed to places a flight lands at.
#
# **A booked ticket is a standalone signal and needs no flight.** The classifier
# already treats one as a `booked_activity` and reads its place straight off the
# location — the flight path is not a prerequisite. What stopped Cancún was the
# catalogue: it holds airport codes and city names for the twelve places a
# *flight* can reach, and a hotel address is not one of them.
#
# Three rules for anything added here, each measured against the real row
# `Casa Tortugas Boutique Hotel - A Hidden Gem in Cancún, Cenzontle, Kukulcan
# Boulevard, Hotel Zone, Cancún, Quintana Roo, Mexico`:
#
# - **Multi-word only.** `_resolve_place` matches a whole string, a three-letter
#   code as a token, or a multi-word alias at word boundaries. A single token
#   like `Cancún` matches none of those mid-sentence, and adding it does nothing
#   — measured, not assumed.
# - **Accents as written.** Normalisation is NFKC and casefold, which keeps
#   `ú`; `Cancun Quintana Roo` resolves to nothing while `Cancún Quintana Roo`
#   resolves. Both spellings are listed because a different exporter will
#   eventually write the plain one.
# - **City with its region, never the region alone.** `Quintana Roo` also holds
#   Tulum and Playa del Carmen, so mapping the state to Cancún would file three
#   different trips under one name — a term in the wrong place being a false
#   claim about somebody.
#
# This is a stopgap and the file it extends says so: production wants a
# licensed, versioned gazetteer rather than a table grown one holiday at a time.
_TICKET_PLACE_ALIASES = {
    "Cancún Quintana Roo": "place:cancun",
    "Cancun Quintana Roo": "place:cancun",
}

_TICKET_PLACE_LABELS = {"place:cancun": "Cancún"}


def classifier_for(user_id: str) -> CalendarClassifier:
    return CalendarClassifier(
        place_catalog={**_OFFLINE_CALENDAR_PLACE_CATALOG, **_TICKET_PLACE_ALIASES},
        place_labels={**_OFFLINE_CALENDAR_PLACE_LABELS, **_TICKET_PLACE_LABELS},
        carrier_codes=_OFFLINE_CALENDAR_CARRIERS,
        recognized_leisure_vendors=_OFFLINE_LEISURE_VENDORS,
        lineage_signer=signer_for(user_id),
    )


def _extra(payload: dict[str, Any]) -> str:
    """`CalendarPayload` back into the semicolon `extra` the classifier reads.

    **The envelope's keys are snake_case and the payload's are camelCase** —
    explicit `CodingKeys` on `SourceEnvelope`, none on `CalendarPayload`.
    Guessing one casing for both reads every field as absent, which here means
    every event classified `excluded_unknown` and a calendar that looks empty of
    anything worth keeping. The HealthKit adapter was written wrong this way
    first.

    Absent values are omitted rather than written empty, because `booked=` and
    `cancelled=` are tested for presence and a stated blank is not an absence.
    """
    pairs: list[tuple[str, Any]] = [
        ("start", payload.get("startsAt")),
        ("end", payload.get("endsAt")),
        ("duration_min", payload.get("durationMinutes")),
        ("calendar", payload.get("calendarName")),
        ("cal_type", payload.get("calendarType")),
        ("organizer", payload.get("organizer")),
        ("url", payload.get("url")),
    ]
    # Flags are written only when true, which is what the distiller does and
    # what `_flag_is_true` expects.
    for key, field in (
        ("all_day", "isAllDay"),
        ("cancelled", "isCancelled"),
        ("booked", "isBooked"),
    ):
        if payload.get(field) is True:
            pairs.append((key, "1"))
    return ";".join(f"{k}={v}" for k, v in pairs if v is not None and v != "")


def legacy_row(payload: dict[str, Any], item_id: str) -> dict[str, Any]:
    """A typed calendar payload in the shape `CalendarClassifier.classify` reads."""
    return {
        "source": "apple_calendar",
        "data_type": "event",
        "item_id": item_id,
        "name": payload.get("title") or "",
        # `detail` is the location — `CalendarPayload.location` is built from
        # `record.detail`, and the classifier searches title and detail together
        # for the patterns that make a flight or a booking.
        "detail": payload.get("location") or "",
        "creator": payload.get("organizer") or "",
        "extra": _extra(payload),
    }


def _artifact_type(decision) -> str:
    """Which of the three closed artifact types this decision is.

    A booking with a recognised vendor is a commercial reservation; one without
    is a public ticket. Both are already inside the classifier's allowlist, so
    this only names what kind of allowed thing it is.
    """
    if decision.disposition is CalendarDisposition.FLIGHT_SEGMENT:
        return "travel_itinerary"
    activity = decision.booked_activity
    if activity is not None and activity.vendor_key:
        return "commercial_reservation"
    return "public_ticket"


def _occurred_at(decision):
    if decision.flight_segment is not None:
        return decision.flight_segment.starts_at
    activity = decision.booked_activity
    return activity.starts_at if activity is not None else None


def project(decision, place_key: str | None = None) -> dict[str, Any]:
    """One decision as the projection the database will accept, or refuse.

    Three states, and the middle one is the interesting decision:

    * **`candidate`** — included by the classifier, with a start time and a
      lineage. Four keys exactly, which is what the constraint compares against.
    * **`review`** — included, but missing something a candidate requires. A
      booked activity may carry no start time, and the constraint demands
      `occurred_at` for a candidate. Recording it as `review` keeps *"the
      classifier included this and it was incomplete"*, which `excluded` would
      throw away and a candidate would overstate.
    * **`excluded`** — everything the allowlist refused, which is most rows.
    """
    if not decision.included:
        return {
            "classification_state": "excluded",
            "normalized_payload": {
                "schema_version": SCHEMA_VERSION,
                "record_kind": "calendar_classification",
                "classification_state": "excluded",
            },
        }

    occurred = _occurred_at(decision)
    lineage = (
        decision.flight_segment.lineage_id
        if decision.flight_segment is not None
        else decision.booked_activity.lineage_id
    )
    if occurred is None or not lineage:
        return {
            "classification_state": "review",
            "normalized_payload": {
                "schema_version": SCHEMA_VERSION,
                "record_kind": "calendar_classification",
                "classification_state": "review",
            },
        }

    payload = {
        "schema_version": SCHEMA_VERSION,
        "record_kind": "calendar_classification",
        "classification_state": "candidate",
        "artifact_type": _artifact_type(decision),
    }
    # **A place, and only ever as a key.** `place:hong_kong` is our vocabulary —
    # the same object `work:sword_art_online` is — while the title it came from,
    # the address, the organiser and the email domain are all still discarded
    # here and a test asserts it. The pattern is what makes that structural: a
    # sentence cannot match, so no future edit to this function can turn the
    # payload back into prose.
    #
    # Absent where the row earned none, so a transit leg and an unrecognised
    # event keep exactly the four keys this projection has always had.
    if place_key and _PLACE_KEY_RE.fullmatch(place_key):
        payload["place_key"] = place_key

    return {
        "classification_state": "candidate",
        "artifact_type": _artifact_type(decision),
        "occurred_at": occurred.isoformat(),
        "content_lineage_hmac": lineage,
        "normalized_payload": payload,
    }


def _round_trip_anchors(journeys) -> set[str]:
    """The places a round trip departs from and comes back to.

    **A base is where you return to, and that is readable from one round trip.**
    The package groups an outbound and a return under a shared
    `round_trip_group_id` and offers `possible_base_for_review` for *repeated*
    round trips — but on the account this was built against there is exactly one
    (out in November, back in January), so nothing was flagged and both ends read
    as trips. The origin of the earliest leg in a group is the anchor: St. Louis
    here, which is a home rather than a holiday.

    A one-way journey has no anchor and is left alone. Guessing a base from a
    single leg would turn every emigration into a holiday and every holiday into
    a home, and the calendar cannot tell those apart.

    This deliberately names no `identity:` anything. An anchor is *where somebody
    returns to*, which is a fact about a diary; it is not where they are from,
    which is an origin claim and the reason `identity:*_ancestry` and
    `identity:*_nationality` are blocked.
    """
    groups: dict[str, list] = {}
    for journey in journeys:
        if journey.round_trip_group_id:
            groups.setdefault(journey.round_trip_group_id, []).append(journey)

    anchors: set[str] = set()
    for group in groups.values():
        if len(group) < 2:
            continue
        first = min(group, key=lambda j: j.starts_at)
        origin = first.segments[0].origin_place_id if first.segments else None
        if origin:
            anchors.add(origin)
    return anchors


def _terminal_refs(classifier, classified) -> dict[str, str]:
    """Which rows named a place somebody actually went, keyed by ref.

    **A flight leg is not a destination.** Only the last segment of a journey
    contributes its place; every earlier one is transit and contributes nothing,
    which is the package's own rule (`Journey.transit_place_ids`) applied for the
    first time. A booked activity carries its place directly — a tour is not a
    connection.

    Returns only rows that earned a place, so `project` receives `None` for
    everything else and the payload keeps the shape it has always had.
    """
    segments = [
        decision.flight_segment
        for _, decision in classified
        if getattr(decision, "flight_segment", None) is not None
    ]
    activities = [
        decision.booked_activity
        for _, decision in classified
        if getattr(decision, "booked_activity", None) is not None
    ]

    terminal_lineages: dict[str, str] = {}
    if segments:
        journeys = [
            j
            for j in classifier.build_journeys(segments, booked_activities=activities)
            if j.segments
        ]
        anchors = _round_trip_anchors(journeys)
        for journey in journeys:
            # **The anchor is a base, not a destination.** In a round trip the
            # place somebody leaves from and returns to is where they live; the
            # far end is where they went. Suppressing the anchor is the whole
            # travel-versus-base split, and it needs one round trip rather than
            # the repetition `possible_base_for_review` waits for — which this
            # account does not have, so without it St. Louis reads as a trip.
            if journey.terminal_place_id in anchors:
                continue
            # The last leg is the one that arrived. Chaining is the package's;
            # this only reads the answer.
            terminal_lineages[journey.segments[-1].lineage_id] = journey.terminal_place_id

    places: dict[str, str] = {}
    for ref, decision in classified:
        segment = getattr(decision, "flight_segment", None)
        if segment is not None:
            place = terminal_lineages.get(segment.lineage_id)
            if place:
                places[ref] = place
            continue
        activity = getattr(decision, "booked_activity", None)
        if activity is not None and activity.place_id:
            places[ref] = activity.place_id
    return places


def handler(event, context):  # noqa: ANN001 - Lambda signature
    """`{user_id, events:[{ref, payload, calendar}]}` in, `{decisions}` out.

    `ref` is the caller's handle for the row — its record fingerprint — and
    comes back untouched, so ingestion never has to rely on ordering to match a
    decision to the row it is about.
    """
    user_id = event["user_id"]
    classifier = classifier_for(user_id)

    decisions: dict[str, Any] = {}
    counts: dict[str, int] = {}

    classified: list[tuple[str, Any]] = []
    for item in event.get("events", []):
        ref = item["ref"]
        payload = item.get("payload") or {}
        decision = classifier.classify(
            legacy_row(payload, item.get("item_id") or ref),
            calendar_metadata=item.get("calendar"),
        )
        # The disposition's own name, for counting only. It is a closed
        # vocabulary from the package and carries nothing about the event.
        counts[str(decision.disposition)] = counts.get(str(decision.disposition), 0) + 1
        classified.append((ref, decision))

    # **Journeys are assembled across the batch, and that is the only place they
    # can be.** A flight is classified one row at a time, and one row cannot know
    # whether its destination was somewhere this person went or somewhere they
    # changed planes. The package has built this since it was written —
    # `build_journeys` chains connections and `Journey.transit_place_ids` records
    # what it passed through — and nothing had ever called it.
    #
    # It matters here more than anywhere: on the library this was measured
    # against, Los Angeles appears twice and everywhere else once, so a naive
    # count makes LA the strongest place signal on the account. Both are legs of
    # the Hong Kong route — CX 880 and CX 883 are the pair — and the terminal
    # rule drops them to zero votes, which is the answer.
    terminal_refs = _terminal_refs(classifier, classified)

    for ref, decision in classified:
        decisions[ref] = project(decision, place_key=terminal_refs.get(ref))

    return {
        "decisions": decisions,
        # Aggregate, not per row. Useful for noticing that a whole calendar
        # classified `excluded_calendar`, and incapable of describing anybody.
        "dispositions": counts,
    }
