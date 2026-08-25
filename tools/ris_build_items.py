#!/usr/bin/env python3
"""Build the extraction work list from the full distillation, for a lab GPU.

**The complete distillation, unredacted.** `public.distilled_records` is what
the device sent — `name`, `creator`, `detail`, `extra` — and it is plaintext
at rest (`0001_initial.sql:43-70`), so it needs no vault key. It is also more
complete than the promoted projection, which strips calendar titles and
excludes YouTube titles by design. The owner authorised using it whole, for
testing on RIS; the AWS lane is untouched and still reads the vault through
KMS with the lineage guarantees that come with it.

**This file holds the credentials and the GPU does not.** It runs where the
database is already reachable, writes JSONL, and that JSONL is all that
crosses to the cluster. A shared machine never sees a connection string.

    python3 tools/ris_build_items.py out/items.jsonl [--limit N]
"""
from __future__ import annotations

import datetime
import hashlib
import json
import pathlib
import re
import subprocess
import urllib.parse
import sys

REPOSITORY = pathlib.Path(__file__).resolve().parents[1]

#: Which source profile the contract knows for each distilled source. The
#: request schema's enum is closed, so a source with no profile is not sent
#: rather than being described by somebody else's rules.
SOURCE_PROFILE = {
    "youtube": "youtube",
    "apple_music": "apple_music",
    "music_library": "apple_music",
    "spotify": "spotify",
    "apple_calendar": "calendar",
    "google_calendar": "calendar",
    "outlook_calendar": "calendar",
    "podcast": "podcast",
}

#: Sources that carry no extractable text. `health` is quantities and
#: `user` is what somebody typed about themselves; neither is a title, and
#: sending them would be asking a language model to read a number.
NO_TEXT = {"health", "user"}

#: **`(source, data_type)` pairs this project has already decided mint nothing.**
#: `apple_music/recommendation` carries `action_weight` 0.000 — Apple's
#: suggestion rather than the person's act — and the standing rule is *mint no
#: vocabulary from recommendation rows*. The RIS lane sent all 250 of them, and
#: what came back was Apple's shelf furniture: `New Music`, `Heavy Rotation`,
#: `Chill`, `Get Up!`, and — through `Apple Music for Shing Hei` and
#: `Shing Hei Mok's Station` — **the account holder's own name as a `person`**.
#: A row the scorer weighs at zero is a row the extractor should never have been
#: shown.
NO_VOCABULARY = {("apple_music", "recommendation")}

#: The calendars, which are the one source that must be *positively recognised*
#: before its text may travel.
CALENDAR = {"apple_calendar", "google_calendar", "outlook_calendar"}

#: **The only two verdicts that admit a calendar row.** Everything else the
#: classifier returns is an exclusion, and its eleven dispositions are ordered
#: so a hard exclusion beats a valid-looking ticket: removed, cancelled,
#: subscribed-holiday-calendar, sensitive, personal, work, ownership — then
#: the two below, then `excluded_unknown` for anything that matched no
#: allowlist at all.
ADMITTED = {"flight_segment", "booked_activity"}


def _parse_horizon(stamp: str | None):
    """The last moment this account's calendar knows anything about.

    Read from every calendar row the classifier was shown, admitted or not: a
    dentist appointment is no use as a term and is perfectly good evidence that
    somebody was not still in Doha.
    """
    if not stamp:
        return None
    try:
        return datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    except ValueError:
        return None


#: **Apple's own parsed-booking prefixes.** `Ticket:`, `Stay:` and
#: `Reservation at` are written by the exporter when it parses a confirmation
#: email — they are not a person's prose. A title in that shape *is* the booking
#: artifact that `booked=1` was standing in for, and it is the structural
#: alternative to a list of vendor names.
#: The separator is what makes it the exporter's, not a person's. `Stay at X`
#: and `Stay: X` are both written by the parser; `Hotel check-in`,
#: `check out+shuttle pick up` and `reservation-black lamb Timi` are somebody
#: typing, and admitting those put `check-in` in the dictionary as a term.
_STRUCTURED_BOOKING_PREFIX_RE = re.compile(
    r"^\s*(?:Ticket|Stay|Reservation)\s*(?::|\s+at\b)\s*\S",
    re.IGNORECASE,
)

#: The same prefix, as something to remove rather than to test for.
_STRUCTURED_BOOKING_PREFIX_STRIP = re.compile(
    r"^\s*(?:Ticket|Stay|Reservation)\s*(?::|\s+at\b)\s*",
    re.IGNORECASE,
)

#: The second flight title the same exporter writes, carrying both airport codes
#: where the first carries a destination city and a bracketed flight number.
_FLIGHT_CODE_TITLE_RE = re.compile(
    r"^\s*Flight\s*:\s*(?P<carrier>[A-Z0-9]{2,3})\s*(?P<number>\d{1,4}[A-Z]?)"
    r"\s+from\s+(?P<origin>[A-Z]{3})\s+to\s+(?P<destination>[A-Z]{3})\s*$",
    re.IGNORECASE,
)

#: `<City> <CODE>` — how the *first* format writes its origin, and therefore how
#: this corpus states what an airport code means without anybody typing a table.
_CITY_CODE_DETAIL_RE = re.compile(r"^\s*(?P<city>.+?)\s+(?P<code>[A-Z]{3})\s*$")

#: **Apple's own machine-readable statement of what a row is.** A parsed
#: booking carries `…?c=<id>&k=|ticket\|…`, `|hotel\|`, `|food\|`, `|movie\|`
#: or `|flight<carrier>\|` in its `url`. That marker is written by the
#: exporter, is not prose, and — the point — **is not translated**, while the
#: title prefix is: the same calendar writes `Ticket:` on one device and
#: `票券：` on another, `Stay:` and `住宿：`, `Reservation at` and `预订：`.
#: Measured on this corpus, **every one of the ten localised bookings carries
#: `booked=1` and one of these markers, and every one was refused** — the
#: entire Chinese-locale family of a person's bookings was invisible, including
#: a Taylor Swift ticket and six flights. Keying on a list of translations
#: would be the vendor catalogue again in another alphabet; keying on the
#: marker is reading what the source states.
_APPLE_BOOKING_KIND_RE = re.compile(r"[?&]k=%?7?C?\|?([a-z]+)", re.IGNORECASE)

#: A prefix in any language, recognised by its punctuation rather than its
#: words. Apple writes a fullwidth colon in the CJK locales, and a short token
#: before one is the exporter labelling the row — never a sentence.
_LOCALISED_PREFIX_RE = re.compile(r"^\s*\S{1,6}：\s*")

#: Once the marker has said the row is a flight, the title only has to give up
#: its parts. Permissive on purpose — it never runs unless Apple already said
#: what this is — which is what lets one pattern read `航班：DL 552 LAX－BOS`,
#: `Flight  UA1410 BDL to ORD` and `United Airlines Flight UA 2403 EWR to LAX
#: at 15:00 PM` without a shape for each.
_FLIGHT_PARTS_RE = re.compile(
    r"\b(?P<carrier>[A-Z]{2}|[A-Z]\d|\d[A-Z])\s*(?P<number>\d{1,4}[A-Z]?)\b"
    r"[^A-Z0-9]*?\b(?P<origin>[A-Z]{3})\b\s*(?:-|to|→|;|,)?\s*\b(?P<destination>[A-Z]{3})\b"
)


def apple_booking_kind(extra) -> str | None:
    """What Apple says this row is, read from its own url marker."""
    raw = str((extra or {}).get("url") or "")
    if not raw:
        return None
    decoded = raw
    for _ in range(2):
        decoded = urllib.parse.unquote(decoded)
    match = re.search(r"[?&]k=\\?\|([a-z]+)", decoded, re.IGNORECASE)
    return match.group(1).lower() if match else None


def _flight_title_re():
    """The shared module's own flight-title pattern, borrowed rather than copied.

    Two patterns for one format are two things that must agree, and this file
    has already paid for that once.
    """
    from written_ontology.calendar_semantics import (  # noqa: PLC0415
        _FLIGHT_TITLE_RE)
    return _FLIGHT_TITLE_RE


def airport_cities(rows) -> dict:
    """An IATA code to city map the corpus states about itself.

    **Derived, never typed.** Every `Flight to <City> (<CC> <N>)` row carries
    its origin as `<City> <CODE>` in `detail`, so reading those pairs yields the
    codes this calendar actually uses — 26 of them, covering seven of the nine
    the second title format needs. The two it does not cover stay as bare codes
    and become their own terms; guessing them here is the gazetteer growing back
    one holiday at a time, which is the thing `aws/classifier/handler.py` says
    in its own words it does not want.
    """
    learned: dict = {}
    named: dict = {}
    coded: dict = {}
    for row in rows:
        if row.get("source") not in CALENDAR:
            continue
        started = str((row.get("extra") or {}).get("start") or "")[:10]
        title = str(row.get("name") or "")
        flight = _flight_title_re().fullmatch(title)

        # **An origin states itself, but only on a row that is a flight.**
        # `<City> <CODE>` also matches a street address ending in a country —
        # `…, Athens, GA 30602, USA` taught `USA` to mean a conference hotel.
        # A pattern is not evidence on its own; what makes this pair a code and
        # a city is the row it sits on.
        if flight:
            match = _CITY_CODE_DETAIL_RE.fullmatch(str(row.get("detail") or ""))
            if match:
                learned.setdefault(match.group("code").upper(),
                                   match.group("city").strip())

        # **The same flight written twice teaches the destination too.** One
        # locale writes `Flight to Frankfurt (LH 235)` and another writes
        # `航班：LH 235 FCO－FRA`; joined on carrier, number and day they are
        # one leg, and the join says `FRA` is Frankfurt. Without it the two
        # spellings become two places, and the leg that departs the code never
        # meets the leg that arrives at the name — which is how `Fra` came out
        # a destination while `Frankfurt` came out a connection.
        if flight and started:
            named.setdefault(
                (flight.group("carrier").upper(),
                 flight.group("number").upper(), started),
                flight.group("destination").strip())
            continue
        parts = _FLIGHT_PARTS_RE.search(
            _LOCALISED_PREFIX_RE.sub("", title, count=1)
            .translate(str.maketrans("－—–", "---")).upper())
        if parts and started:
            coded.setdefault(
                (parts.group("carrier"), parts.group("number"), started),
                parts.group("destination"))

    for leg, code in coded.items():
        city = named.get(leg)
        if city:
            learned.setdefault(code, city)
    return learned


def _widen_for_the_lab(classifier):
    """Two catalogue gates lifted for the lab, and only on this lane.

    **The rule that decides travel needs no gazetteer; the gates in front of it
    do.** `classify_place_roles` asks whether somebody departed from a place and
    whether they left it again, which is a question about the shape of an
    itinerary — but a flight is refused before that question is ever put if the
    destination is missing from a 26-alias table or the carrier from a 20-code
    one. Measured over one labelled itinerary of 36 flights: **24 refused for an
    unknown destination and 6 for an unknown carrier, and the refusals fall
    disproportionately on *return* legs**, so the rule saw six one-way trips and
    correctly concluded nobody came back. It judged 5 cities and got 1 right.
    With both gates lifted it judges 26 and gets 25 — the miss being `Chicago`
    against `Chicago O'Hare`, two strings for one city, which is the
    dictionary's merge to make and not this rule's.

    **Neither widening is a list.**

    - *A carrier code is accepted on its shape.* `_FLIGHT_TITLE_RE` already
      requires the two-or-three-character IATA form inside brackets after a
      flight number, and a table of twenty codes adds nothing to that but a
      reason to lose Japan Airlines. Anything the title validates is a carrier.
    - *A destination is read from the title that states it.* "Flight to Boston
      (B6 497)" names Boston; `_continuity_key` gives it a stable identity
      without a catalogue knowing it exists. This is reading a label the source
      supplies, not inferring one — the same move as taking YouTube's own topic
      instead of computing a category. Where the catalogue *does* know a place,
      it still wins, so it becomes a preferred-label table rather than a
      vocabulary.

    **This must never travel to AWS.** There the classifier's stored payload is
    capped at four keys and a test asserts no fragment of a title, address,
    organiser or email domain survives into it — the guard that stops calendar
    text escaping. Putting a parsed destination in a place label breaks exactly
    that guard, which is why the widening lives here, in the lane the owner
    lifted the privacy projection for, and is applied to an instance rather than
    to the shared catalogues the Lambda reads.
    """
    from written_ontology import calendar_semantics as semantics  # noqa: PLC0415

    class _AnyWellFormedCarrier(frozenset):
        def __contains__(self, code: object) -> bool:  # noqa: D105
            return bool(re.fullmatch(r"[A-Z0-9]{2,3}", str(code)))

    classifier._carrier_codes = _AnyWellFormedCarrier()

    catalogue_resolve = classifier._resolve_place

    # **A `FlightSegment` keeps its destination's label and throws its origin's
    # away.** Only the destination is a candidate on the AWS lane, so only the
    # destination needed naming. Here both ends are terms, so every name this
    # resolver produces is remembered against the id it produced it for — the
    # one place a caller can recover an origin's label from.
    classifier.ris_place_labels = {}

    def resolve(*references):
        known = catalogue_resolve(*references)
        if known is not None:
            classifier.ris_place_labels.setdefault(known[0], known[1])
            return known
        for reference in references:
            key = semantics._continuity_key(reference)
            if key:
                label = _place_label(reference)
                classifier.ris_place_labels.setdefault(key, label)
                return key, label
        return None

    classifier._resolve_place = resolve

    # **The booking gate reads structure instead of a vendor catalogue.**
    # `_parse_booked_activity` wants `vendor or strong_title` *and* a booking
    # artifact, and both halves are catalogue-shaped. Measured over 39
    # structured bookings, 2 were admitted, and the failures were one-sided in
    # opposite directions: `Reservation at Krasi` matched the leisure title and
    # carried no artifact, while `Stay: Hyatt Place Princeton` carried
    # `booked=1` and a url saying `|hotel|` and matched no title. The only
    # hotel that got through was the one with the word "Hotel" in its name.
    #
    # `_TICKET_PREFIX_RE` is read for **both** halves, so widening it from
    # `Ticket:` alone to the exporter's whole prefix family answers both. The
    # seven-vendor list is untouched and keeps its meaning — a *recognised*
    # vendor — it is simply no longer the only door.
    #
    # **This rebinding is process-local.** It names a module global inside a
    # tool that runs on its own; the Lambda imports its own copy of
    # `calendar_semantics` in its own process and never executes this file. The
    # file on disk is unchanged, which is what keeps the AWS payload test —
    # four keys, no fragment of a title — meaning what it means.
    semantics._TICKET_PREFIX_RE = _STRUCTURED_BOOKING_PREFIX_RE

    classifier.ris_airport_cities = {}
    catalogue_classify = classifier.classify

    def classify(row):
        decision = catalogue_classify(row)
        verdict = getattr(getattr(decision, "disposition", None), "value", None)
        if verdict in ADMITTED:
            return decision
        title = str(row.get("name") or "")

        # **The second flight format, answered by rewriting rather than by a
        # second parser.** `Flight: B6 254 from DCA to BOS` states both ends as
        # codes where `Flight to Boston (B6 254)` states a city and a bracketed
        # number. Reshaping the row into the format the existing parser already
        # validates means one flight parser rather than two that must agree —
        # and the codes resolve through what this corpus says about itself.
        if getattr(decision, "reason", None) == "generic_or_malformed_flight_title":
            match = _FLIGHT_CODE_TITLE_RE.fullmatch(title)
            if match is not None:
                cities = getattr(classifier, "ris_airport_cities", {})
                origin_code = match.group("origin").upper()
                target_code = match.group("destination").upper()
                reshaped = dict(row)
                reshaped["name"] = (
                    f"Flight to {cities.get(target_code, target_code)} "
                    f"({match.group('carrier').upper()} {match.group('number')})"
                )
                reshaped["detail"] = (
                    f"{cities.get(origin_code, origin_code)} {origin_code}"
                )
                rewritten = catalogue_classify(reshaped)
                if getattr(getattr(rewritten, "disposition", None),
                           "value", None) in ADMITTED:
                    return rewritten

        # **What Apple says the row is, when the title is in a language the
        # prefix test does not read.** The marker is not translated and the
        # title is, so a row the exporter itself labelled a ticket, a hotel, a
        # restaurant or a flight is reshaped into the English structured form
        # the parsers already validate and put back to them. The kind decides
        # the shape; the title supplies the parts. No list of translations, and
        # no second parser to keep in agreement with the first.
        kind = apple_booking_kind(row.get("extra"))
        if kind and verdict not in ADMITTED:
            # The exporter's own label comes off first, in either alphabet, so
            # what is tested below is the name and not the word "Movie".
            rest = _LOCALISED_PREFIX_RE.sub("", title, count=1)
            rest = re.sub(r"^\s*[A-Za-z]{2,12}\s*:\s*", "", rest, count=1).strip()
            reshaped = dict(row)
            if kind.startswith("flight"):
                # Fullwidth dashes are how the CJK locale writes a leg.
                parts = _FLIGHT_PARTS_RE.search(
                    rest.translate(str.maketrans("－—–", "---")).upper())
                if parts is not None:
                    cities = getattr(classifier, "ris_airport_cities", {})
                    origin_code = parts.group("origin")
                    target_code = parts.group("destination")
                    reshaped["name"] = (
                        f"Flight to {cities.get(target_code, target_code)} "
                        f"({parts.group('carrier')} {parts.group('number')})")
                    reshaped["detail"] = (
                        f"{cities.get(origin_code, origin_code)} {origin_code}")
                else:
                    reshaped = None
            elif kind in ("ticket", "movie", "event"):
                # **A booking id is not a name.** Cinemark writes
                # `Movie: 3215231028718`, and admitting it would put a booking
                # reference in the dictionary as a term. A row whose title
                # carries no letters names nothing, whatever it was booked for.
                reshaped = (dict(row, name=f"Ticket: {rest}")
                            if any(c.isalpha() for c in rest) else None)
            elif kind in ("hotel", "lodging"):
                reshaped = dict(row, name=f"Stay: {rest}")
            elif kind in ("food", "restaurant", "dining"):
                reshaped = dict(row, name=f"Reservation at {rest}")
            else:
                reshaped = None
            if reshaped is not None:
                relabelled = catalogue_classify(reshaped)
                if getattr(getattr(relabelled, "disposition", None),
                           "value", None) in ADMITTED:
                    return relabelled

        # **A cancelled ticket is still evidence; a cancelled stay is not.**
        # Buying a ticket to the Final Fantasy VII orchestra named something
        # somebody wanted, and not going is a separate fact — source-action
        # integrity cuts this way as much as it cuts against calling a booking
        # an attendance. A cancelled hotel is only a place, and a place nobody
        # went to says nothing. The ladder refuses cancelled rows before any
        # parser runs, so the ticket is re-put to it without that flag.
        if verdict == "excluded_cancelled" and re.match(r"^\s*Ticket\s*:", title,
                                                        re.IGNORECASE):
            uncancelled = dict(row)
            extra = dict(uncancelled.get("extra") or {})
            extra.pop("cancelled", None)
            extra.pop("status", None)
            uncancelled["extra"] = extra
            revived = catalogue_classify(uncancelled)
            if getattr(getattr(revived, "disposition", None),
                       "value", None) in ADMITTED:
                return revived

        return decision

    classifier.classify = classify
    return classifier


def _place_label(reference: object) -> str:
    """The place as the source wrote it, less the airport code beside it.

    `Boston BOS` and `Boston` are one place, and the trailing IATA code is the
    only systematic difference between how an origin and a destination are
    written. Nothing else is normalised: guessing that `Chicago O'Hare` is
    `Chicago` is a merge, and merges belong to the dictionary.
    """
    text = re.sub(r"\s+[A-Za-z]{3}$", "", str(reference or "").strip()).strip()
    # A calendar that shouts `DALIAN` is writing the same city as one that
    # writes `Dalian`. Case is presentation, not identity, so folding it is not
    # the merge above — `PU DONG` still arrives as its own term and it is the
    # dictionary's job, not this function's, to decide it is Shanghai.
    if text and text == text.upper() and any(c.isalpha() for c in text):
        text = text.title()
    return text[:256] or str(reference or "")[:256]


def calendar_gate():
    """The same classifier the AWS lane runs, built the same way.

    **This lane skipped it entirely, and that is what this repairs.** The RIS
    lane was licensed to bypass the privacy *projection* on the owner's own
    data for internal testing; it also bypassed the *allowlist*, which was
    never the intent. The result was 1,988 calendar mentions producing 915
    dictionary terms — 123 of them other people's names, fifteen of them email
    addresses — in a table with no `user_id`.

    `tools/calendar_review.py:classifier_for` already builds this offline with
    the four catalogues the Lambda uses, and a test pins those arguments
    because constructing without one would silently reclassify. It is imported
    rather than rebuilt: two constructions of the same classifier are two
    places to forget a catalogue.

    Returns `None` when the classifier cannot be built, and the caller then
    admits nothing — **an absent verdict excludes**, which is the ladder's own
    shape and the opposite of what a missing filter did here.
    """
    try:
        sys.path.insert(0, str(REPOSITORY / "tools"))
        sys.path.insert(0, str(REPOSITORY / "semantic" / "src"))
        from calendar_review import classifier_for  # noqa: PLC0415

        return _widen_for_the_lab(classifier_for("ris-lane"))
    except Exception as error:  # noqa: BLE001 — named, never silent
        print(json.dumps({"calendar_classifier": "unavailable",
                          "detail": f"{type(error).__name__}: {error}"[:200]}),
              file=sys.stderr)
        return None


def query(sql: str) -> list[dict]:
    """Run a read through the linked project and return its rows.

    **The format is asked for, not assumed, and that cost a run.** `text` is
    the CLI's default; it answered JSON anyway whenever stdout was not a
    terminal, so every call here worked until one was made from a real shell
    and came back as an ASCII table. `--output-format json` makes the answer
    the same wherever it is run.

    **And the answer is found by decoding, not by slicing.** The CLI prefixes
    its output with whatever warnings it has — the Docker "Mounts denied" one
    carries braces of its own — and the payload is an object without the flag
    and a bare array with it. So every `[` or `{` is offered to a real decoder
    and the first that yields rows wins.
    """
    result = subprocess.run(
        ["supabase", "db", "query", "--linked", "--output-format", "json", sql],
        capture_output=True, text=True, cwd=REPOSITORY)
    if result.returncode != 0:
        raise SystemExit(f"query failed: {result.stderr[:400]}")
    decoder = json.JSONDecoder()
    text = result.stdout
    for index, character in enumerate(text):
        if character not in "[{":
            continue
        try:
            value, _ = decoder.raw_decode(text[index:])
        except ValueError:
            continue
        # **Two shapes, because the flag changes it.** Without
        # `--output-format json` the CLI wraps the rows in an object beside a
        # `warning` key; with it the answer is the bare array. Accepting both
        # means this keeps working whichever the CLI decides to send.
        if isinstance(value, list):
            return value
        if isinstance(value, dict) and isinstance(value.get("rows"), list):
            return value["rows"]
    raise SystemExit(f"no json in the answer: {text[:400]}")


#: **Dunbar's number, and it is not read off this library.** A channel whose
#: audience is no larger than one person's own social circle is a personal
#: account, not a public figure — the same kind of external anchor as IATA's
#: twenty-four hours, chosen so the bar is a rule rather than a line drawn
#: around the data it was first applied to.
#:
#: What it separates here, from YouTube's own `statistics`: 阮育志 at 2
#: subscribers and 14 videos, 郭冠麟 at 3 with one video, 姚丞徽 at 14 with
#: one — the owner's acquaintances, named as such — against `sherenehaha` at
#: 235 and everything above. **The measure had to be the channel and not the
#: video**: median views separate nothing, since a fan repost in this corpus
#: draws 3.5 million while Smith College's own upload draws 2,084.
PUBLIC_CHANNEL_MIN_SUBSCRIBERS = 150

#: `channel_id -> subscriber_count`, for the channels YouTube has told us the
#: size of. Filled once per run from the subscription rows, which carry the
#: channel id as their `item_id`.
KNOWN_CHANNEL_SIZE: dict = {}

#: The row types whose `creator` is the account holder rather than anybody the
#: account holder listens to. **Measured, not assumed**: across every
#: `playlist` and `playlist_item` row, `creator` holds exactly one value per
#: account — `Tianmei Zhu` for one, `柔理柔理世界第一` for the other. A field
#: that is constant over an account is describing the account, and sending it
#: as a performer is what made the owner's own name a `person`, an
#: `organization` and a `franchise` in a dictionary shared across every user.
#: It is the same defect as the calendar's `creator`, which named the calendar.
OWNER_NAMED_TYPES = {"playlist", "playlist_item"}


def channel_sizes(rows) -> dict:
    """How many subscribers YouTube says each channel has.

    A `subscription` row **is** the channel, and its `item_id` is the channel
    id — the same id a `liked_video` carries in `extra`. That join is the only
    route to a liked video's channel size, and it reaches 9 of 210 uploaders:
    the rest are channels nobody in this corpus subscribes to, so nothing
    states who they are.
    """
    sizes: dict = {}
    for row in rows:
        if row.get("source") != "youtube" or row.get("data_type") != "subscription":
            continue
        raw = (row.get("extra") or {}).get("subscriber_count")
        try:
            sizes[str(row.get("item_id"))] = int(str(raw))
        except (TypeError, ValueError):
            continue
    return sizes


def fields_for(row: dict) -> dict:
    """The source fields the request schema admits, and nothing else.

    Absent keys are omitted rather than sent empty: `minProperties` is
    satisfied by the title, and the schema refuses nothing it never saw.
    """
    fields: dict = {}
    # **A subscription to somebody you know is not vocabulary.** The row *is*
    # the channel, so if the channel is not a public one there is no term in
    # the row at all and it is not sent — the title is the acquaintance's own
    # name. Returning nothing here is what the caller already reads as "no
    # extractable text", the same answer a `health` row gives.
    if (row.get("source") == "youtube"
            and str(row.get("data_type") or "") == "subscription"):
        size = KNOWN_CHANNEL_SIZE.get(str(row.get("item_id")))
        if size is None or size < PUBLIC_CHANNEL_MIN_SUBSCRIBERS:
            return {}
    if row.get("name"):
        title = str(row["name"])
        # **The prefix is the exporter's word, not the person's.** `Reservation
        # at Krasi` is a booking at Krasi, and the term is Krasi — a restaurant
        # whose cuisine is a real thing to know about somebody. Left on, the
        # dictionary fills with `Reservation At …` as its own family of terms,
        # which is the plumbing showing through the way `Calendar` did.
        # The address never travels: `detail` is already emptied for calendars
        # below, because a street is not a thing a sentence is about.
        if row.get("source") in CALENDAR:
            title = _LOCALISED_PREFIX_RE.sub("", title, count=1)
            title = _STRUCTURED_BOOKING_PREFIX_STRIP.sub("", title, count=1)
        fields["title"] = (title.strip() or str(row["name"]))[:256]
    if row.get("creator"):
        # A channel for YouTube, a performer for music: the same column
        # carries both, and the profile tells the model which it is reading.
        if row.get("source") == "youtube":
            # **Three row types, three different things in one column, and
            # only one of them is somebody the account holder chose to hear.**
            #
            # On a `playlist` or `playlist_item` it is the account holder — a
            # constant per account, never an artist.
            #
            # On a `subscription` it is the channel's own title, byte for byte
            # equal to `name` on all 128 rows, so sending it says the same
            # thing twice and invites the model to mint the channel again as a
            # performer of itself.
            #
            # On a `liked_video` it is the uploader, and **usually a reposter**
            # — this file's standing finding is that on a repost row the
            # channel name is meaningless and the title carries everything.
            # It travels only where YouTube states who that channel is, which
            # is where the same channel is also subscribed. `IDVE`, `비몽`,
            # `나예최예나`, `九尾` and `따라해볼레이` all became `person` or
            # `group` terms, several with invented romanisations, and not one
            # of them is a channel anybody here follows.
            data_type = str(row.get("data_type") or "")
            if data_type in OWNER_NAMED_TYPES or data_type == "subscription":
                pass
            else:
                size = KNOWN_CHANNEL_SIZE.get(
                    str((row.get("extra") or {}).get("channel_id") or ""))
                if size is not None and size >= PUBLIC_CHANNEL_MIN_SUBSCRIBERS:
                    fields["channel_label"] = str(row["creator"])[:128]
        elif row.get("source") in CALENDAR:
            # **A calendar row has no performer.** `creator` there is the
            # calendar's own name or the organiser — `日历`, `日曆`,
            # `szhu@smith.edu` — and sending it as a performer is what put
            # `Calendar` into the dictionary 165 times, typed variously as a
            # person, a work and a franchise. The organiser of a ticketed event
            # is a real fact and would need its own field with its own
            # decision; it is not a performer.
            pass
        else:
            fields["performer"] = str(row["creator"])[:256]
    # **`name_the_composer_for_classical` has been a rule with no input.** The
    # distiller stores `composer=` in `extra` and the request schema admits a
    # `composer` field, and nothing has ever put one in it — so the model was
    # asked to name a composer while being handed only the *performer*, under
    # the label `performer`. On a Bach library that is most of the corpus:
    # "Raphaël Pichon, Tim Mead & Pygmalion" is who played it, not who wrote it.
    #
    # Sent only when it differs from the performer, since Apple repeats the
    # artist into the composer slot for popular music and a field saying the
    # same thing twice invites the same term to be minted twice.
    composer = str((row.get("extra") or {}).get("composer") or "").strip()
    if composer and composer.casefold() != str(row.get("creator") or "").strip().casefold():
        fields["composer"] = composer[:256]
    # **`detail` is not one field, it is four.** Measured against the real
    # rows: `library_song` carries the album ("J.S. Bach: Matthäus-Passion"),
    # `playlist_item` carries `playlist=<name>`, `recommendation` carries
    # `shelf=<name>`, and `rating` carries the rating word. Sending all of it
    # as `album` told the model that "playlist=周杰伦" was an album, and it
    # dutifully merged that surface into Jay Chou — 190 such surfaces.
    #
    # A playlist name is still real context (a playlist called 周杰伦 says
    # something), so it travels as `description_excerpt` where it belongs
    # rather than being thrown away.
    detail = (row.get("detail") or "").strip()
    # **A calendar event's `detail` is its location, and a location is not a
    # term.** For a flight it is the *origin* airport — `Flight to Los Angeles`
    # carries `聖路易斯 STL` — and for anything else it is a room number, a
    # street address or a meeting URL. Sent as `album` it produced `Boston BOS`,
    # `Hartford BDL` and `Newark EWR` as *franchises*, plus `Seelye 101`,
    # `Bass 307` and `40 Trumbull Rd`. The destination is already in the title.
    if row.get("source") in CALENDAR:
        detail = ""
    if detail:
        lowered = detail.lower()
        if lowered.startswith("playlist="):
            context = detail.split("=", 1)[1].strip()
            if context and context.lower() not in ("public", "private"):
                fields["description_excerpt"] = f"from the playlist {context}"[:512]
        elif lowered.startswith(("shelf=", "station=")):
            pass  # a shelf is Apple's own merchandising, not the user's act
        elif "=" in detail.split(" ", 1)[0]:
            pass  # any other key=value metadata is plumbing, not a title
        elif len(detail) <= 24 and " " not in detail:
            pass  # a bare rating word; the action already carries it
        elif row.get("source") != "youtube":
            fields["album"] = detail[:256]
    return fields


def main() -> int:
    out_path = pathlib.Path(sys.argv[1])
    limit = None
    if "--limit" in sys.argv:
        limit = int(sys.argv[sys.argv.index("--limit") + 1])

    # **Read through the summary view, never the table.** `distilled_records`
    # is append-only and stores only changes, so the raw table holds every
    # historical version of a row; the view returns the latest per item. It
    # also has no surrogate key — identity is (user, source, data_type,
    # item_id) — which is what `row_id` is built from below.
    sources = ", ".join(f"'{s}'" for s in SOURCE_PROFILE)
    rows = query(f"""
        select d.user_id::text as user_id,
               d.source, d.data_type, d.name, d.creator, d.detail,
               d.item_id,
               -- **`extra` is what the classifier decides on**, and leaving it
               -- out starved it: a flight row without `booked`, `all_day` and
               -- its start time reads as `excluded_unknown`, so 24 genuine
               -- flight segments were refused while the two vendor bookings —
               -- which need no `extra` — got through. The gate looked strict
               -- and was simply blind.
               d.extra
          from public.summary_distilled_records d
         where d.source in ({sources})
           and coalesce(d.name, '') <> ''
           and d.removed_at is null
           -- `markedRemoved` is dead: the app writes `removed_by_user` into
           -- `extra` and `SyncService` lifts it into the `removed_at` column,
           -- which the line above is what actually filters on. Kept because a
           -- future writer of that key would otherwise pass silently.
           and coalesce(d.extra ->> 'markedRemoved', '') <> '1'
         order by d.source, d.item_id
         {f'limit {limit}' if limit else ''}
    """)

    # The parents the model may echo, exactly as the worker supplies them:
    # ids and labels only, axes excluded. **Every hub is always offered; the
    # rest go by child count** — mirrors `_SELECT_PARENT_CANDIDATES` in
    # aws/worker/overlay.py, whose comment carries the reasoning (pure
    # count-ordering starved `hub:film_video` at rank 43 and kept zero-child
    # headings unreachable forever). If the two ever disagree, the worker's
    # is the one that governs.
    parents = query("""
        with published as (
          select id from ontology.versions where status = 'published'
        ),
        hubs as (
          select c.concept_key as term_id, cr.preferred_label as label,
                 0 as tier, 0::bigint as children
            from ontology.concepts c
            join ontology.concept_revisions cr
              on cr.concept_id = c.id
             and cr.ontology_version_id = (select id from published)
           where c.concept_key like 'hub:%' and c.retired_at is null
        ),
        earned as (
          select c.concept_key as term_id, cr.preferred_label as label,
                 1 as tier, count(distinct e.subject_concept_id) as children
            from ontology.concept_edges e
            join ontology.concepts c on c.id = e.object_concept_id
            join ontology.concept_revisions cr
              on cr.concept_id = e.object_concept_id
             and cr.ontology_version_id = e.ontology_version_id
           where e.predicate_key = 'broader' and e.status = 'active'
             and e.ontology_version_id = (select id from published)
             and c.concept_key !~ '^(era|sphere|scene|hub):'
           group by c.concept_key, cr.preferred_label
           order by count(distinct e.subject_concept_id) desc, c.concept_key
           limit 25
        )
        select term_id, label
          from (select * from hubs union all select * from earned) pool
         order by tier, children desc, term_id
         limit 40
    """)
    candidates = [{"term_id": p["term_id"][:128], "label": p["label"][:128]}
                  for p in parents]

    # Read before anything is judged: a liked video's channel size is only
    # knowable from the subscription rows in the same distillation.
    KNOWN_CHANNEL_SIZE.update(channel_sizes(rows))

    classifier = calendar_gate()
    if classifier is not None:
        # Read before anything is classified: the map comes from the first
        # flight format's own `detail` strings, and the second format needs it.
        classifier.ris_airport_cities = airport_cities(rows)
    verdicts: dict[str, int] = {}
    # **Per account, never pooled.** One list for everybody chains one person's
    # arrival to another's departure and reads two diaries as one itinerary —
    # and it is how a place somebody has never been becomes their term. The
    # horizon is per account for the same reason: it answers "does this diary
    # carry on past that arrival", which is a question about one person.
    segments: dict[str, list] = {}
    horizons: dict[str, str] = {}

    written, skipped = 0, 0
    by_source: dict[str, int] = {}
    with out_path.open("w") as out:
        for row in rows:
            source = row["source"]
            if source in NO_TEXT:
                skipped += 1
                continue
            if (source, row.get("data_type")) in NO_VOCABULARY:
                skipped += 1
                continue
            if source in CALENDAR:
                # **Positively recognised, or not sent.** The allowlist is the
                # design, not a gap: the AWS lane promotes 5 of 101 and this
                # lane sent 1,029 of 1,029. A row the classifier cannot judge
                # is excluded like any other — the fallthrough disposition is
                # `excluded_unknown`, and it is the modal outcome by design.
                started = str((row.get("extra") or {}).get("start") or "")
                if started:
                    owner = row["user_id"]
                    if started > horizons.get(owner, ""):
                        horizons[owner] = started
                decision = classifier.classify(row) if classifier else None
                verdict = (getattr(getattr(decision, "disposition", None),
                                   "value", None)
                           or "classifier_unavailable")
                verdicts[verdict] = verdicts.get(verdict, 0) + 1
                if verdict == "flight_segment":
                    # **A segment is not a destination.** Sending each leg as
                    # its own item makes a connection indistinguishable from
                    # somewhere you went: Atlanta is a term because you changed
                    # planes there. `build_journeys` chains legs and keeps
                    # `transit_place_ids` apart from `terminal_place_id`, and
                    # `derive_travel_candidates` groups by terminal alone — one
                    # vote per journey, nothing for a connection. The segments
                    # are collected here and resolved after the whole calendar
                    # is read, because a journey cannot be recognised from one
                    # leg.
                    segments.setdefault(row["user_id"], []).append(
                        decision.flight_segment)
                    skipped += 1
                    continue
                if verdict not in ADMITTED:
                    skipped += 1
                    continue
            fields = fields_for(row)
            if not fields:
                skipped += 1
                continue
            # Identity without a surrogate key: the four columns that
            # uniquely name an item, hashed so it fits the request schema's
            # 64-character opaque id and carries nothing about whose it is.
            row_id = hashlib.sha256(
                "|".join([row["user_id"], source, str(row.get("data_type")),
                          str(row.get("item_id"))]).encode()).hexdigest()[:40]
            out.write(json.dumps({
                "row_id": row_id,
                "user_id": row["user_id"],
                "source_code": source,
                "data_type": row.get("data_type"),
                "item_id": row.get("item_id"),
                "source_profile": SOURCE_PROFILE[source],
                "source_action": row.get("data_type"),
                "fields": fields,
                "parent_candidates": candidates,
            }, ensure_ascii=False) + "\n")
            written += 1
            by_source[source] = by_source.get(source, 0) + 1

        # ---------------------------------------------------------------------
        # Journeys, once the whole calendar has been read
        # ---------------------------------------------------------------------
        #
        # **A destination is a place you went; a connection is a place you changed
        # planes.** `derive_travel_candidates` groups journeys by
        # `terminal_place_id` alone, so a transit airport produces no candidate at
        # all — which is the rule, expressed by the code that already knew it.
        # One vote per journey, not per leg, so a three-leg trip to Hong Kong is
        # one piece of evidence rather than three.
        #
        # These are emitted as items with a place label and nothing else. A place
        # the classifier resolved needs no model to name it, but it travels the
        # same lane so the term reaches the dictionary by one route rather than two.
        travel = 0
        for owner, owned in sorted(segments.items()):
            if classifier is None:
                break
            try:
                journeys = classifier.build_journeys(owned)
                calendar_horizon = _parse_horizon(horizons.get(owner))
                # **Terminals, not travel candidates.** `derive_travel_candidates`
                # applies a further product judgement — recency and recurrence, for
                # `scheduled_travel_to` — and over this corpus it answers with one
                # place, because the trips are years old. That is the right answer
                # to "where is this person going"; it is the wrong one to "which
                # places are terms". The journey already carries the split this
                # needs: `terminal_place_id` is where the trip ended and
                # `transit_place_ids` is where planes were changed, and only the
                # first is asked for here.
                # **Both ends of a journey count; only transit does not.**
                # Flying *from* Milan and flying *to* London are each a place in
                # somebody's life, so an origin is a term as much as a terminal
                # — a trip need not be complete to say something. What is
                # refused is the middle, and `classify_place_roles` is where
                # that judgement lives: a departure proves presence, an arrival
                # proves it once a later departure or a long enough gap shows a
                # stay, and everything else was a change of planes.
                #
                # The verdict is per place across the whole record, so a city
                # connected through once and flown to another time is a
                # destination on the strength of the second. Checked against a
                # labelled itinerary of 36 flights: 26 of 26 cities agreed.
                #
                # `record_ends_at` is the last calendar row of any kind, not the
                # last flight, so an arrival with no return is read as transit
                # only where the diary carries on past it. At the edge of what
                # was captured we stopped looking rather than found nothing.
                from written_ontology.calendar_semantics import (  # noqa: PLC0415
                    classify_place_roles)
                from written_ontology.export_adapter import (  # noqa: PLC0415
                    _OFFLINE_CALENDAR_PLACE_LABELS as PLACE_LABELS)

                roles = classify_place_roles(
                    journeys, record_ends_at=calendar_horizon)
                names = dict(getattr(classifier, "ris_place_labels", {}))
                terminals = {}
                for journey in journeys:
                    origin = journey.origin_place_id or ""
                    for place_id, label in (
                        (journey.terminal_place_id, journey.terminal_label),
                        (journey.origin_place_id,
                         PLACE_LABELS.get(origin) or names.get(origin)),
                    ):
                        if not place_id or not label:
                            continue
                        if roles.get(place_id) != "destination":
                            continue
                        terminals.setdefault(place_id, label)
                for place_id, place_label in sorted(terminals.items()):
                    row_id = hashlib.sha256(
                        f"journey|{owner}|{place_id}".encode()).hexdigest()[:40]
                    out.write(json.dumps({
                        "row_id": row_id,
                        "user_id": owner,
                        "source_code": "apple_calendar",
                        "data_type": "event",
                        "item_id": place_id,
                        "source_profile": "calendar",
                        "source_action": "event",
                        "fields": {"title": place_label[:256]},
                        "parent_candidates": candidates,
                    }, ensure_ascii=False) + "\n")
                    travel += 1
                    written += 1
            except Exception as error:  # noqa: BLE001 — named, never silent
                print(json.dumps({"journeys": "failed",
                                  "detail": f"{type(error).__name__}: {error}"[:200]}),
                      file=sys.stderr)


    # **Per source, against what the database holds.** A source that quietly
    # contributed nothing is the failure this count exists to make visible.
    # **The calendar verdicts are reported, not merely applied.** A filter
    # whose refusals are invisible is how the last version of this looked
    # healthy while sending a diary: the counts are what make an allowlist
    # checkable, and `excluded_unknown` dominating is the rule working.
    print(json.dumps({"written": written, "skipped": skipped,
                      "by_source": by_source,
                      "travel_destinations": travel,
                      "calendar_verdicts": dict(sorted(
                          verdicts.items(), key=lambda kv: -kv[1])),
                      "out": str(out_path)},
                     ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
