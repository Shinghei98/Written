"""Validation for `mention_extract_v2` that JSON Schema cannot express.

## Why two layers

The schema carries everything declarative — enums, lengths, the
status/mentions/abstain_reason agreement, `source_field_index` required for tags
and null otherwise. Four conditions cannot be written in JSON Schema at all,
because each one relates the response to the *request* or relates two mentions to
each other:

  * every requested item appears exactly once, and indices are contiguous;
  * `end > start`, and both within the actual source string;
  * `surface == source[start:end]` by **Unicode code point**;
  * no two mentions in an item share a span and a role.

A response that passes the schema and fails these is well-formed and untrue,
which is the worse of the two failures — so this runs on every response and its
refusals are as final as the schema's.

## Offsets are code points

Python strings index by code point, which is what this validates. A model that
counted UTF-16 units disagrees on any astral character — one emoji shifts every
later offset by one — and a model that counted bytes disagrees on everything
non-ASCII. **The equality check is what catches it**, which is the reason
`surface` is carried during the first evaluation at all.

## Failures are structural, never semantic

Every refusal here raises with a machine-readable code. **None of them is an
abstention**: a malformed response says nothing about whether the item had a
durable subject, and recording it as `no_durable_subject` would put a model's bug
into a person's profile as evidence about them.
"""

from __future__ import annotations

import re

import unicodedata
from dataclasses import dataclass

SCHEMA_VERSION = "mention_extract_v6"

#: The fields a request may offer, mirroring the schema's `source_field` enum.
#: A response naming anything else is refused before its offsets are read.
SOURCE_FIELDS = ("title", "channel_label", "description_excerpt", "tags")

#: The `source_field` an inferred mention carries. It is not a field at all —
#: the value is how the variant is told apart, the same mechanism `mention_tag`
#: uses. Named once so no caller compares the literal itself.
INFERRED_FIELD = "inferred"


#: §2.1's boundary check on the wire: the family a mention claims and the
#: cardinal root it selects must be the same statement. The map mirrors
#: `ontology.cardinal_root_map` for the wire's families; a migration pins the
#: two equal so they cannot drift. 'none' means the family has no root
#: (operational metadata) and no selected cardinal may accompany it.
FAMILY_CARDINAL = {
    "person": "person", "group": "group", "organization": "organization",
    "franchise": "franchise", "work": "work", "anime": "work", "book": "work",
    "game": "work", "music_work": "work", "album": "work",
    # v6 (owner, 2026-09-07): television gets its own families. A reality
    # show or a documentary had been filed as `work` or, whenever a person
    # was said to belong to it, as `franchise`; the enum had no better word.
    "tv_series": "work", "tv_show": "work", "documentary": "work",
    "sport": "activity", "activity": "activity", "art": "concept",
    "field": "concept",
    "place": "none", "culture": "concept", "event": "event", "tour": "event",
}
#: **`cardinal:concept` is reached by exactly two families, and that is the
#: owner's decision of 2026-08-24, not an accident of what has been written.**
#: `idea` was here and is gone: across 10,274 mentions it was emitted **zero
#: times**, and the terms it existed to carry — ASMR, study-with-me, commentary
#: — were ruled out of scope. `art` replaces it for art forms and styles
#: (`art:oil_painting`, `art:impressionism`), and `culture` is redefined as a
#: country and its cultural sphere (`culture:japan`). A person is linked to a
#: style by a relation, never by being typed as one.

#: The explicit stand-in for null inside the closed enums — a null member in
#: an enum is not a grammar shape this stack trusts xgrammar with (measured
#: 2026-08-21: it collapsed generation below 10 tokens/sec). Named once.
NONE_SENTINEL = "none"


def cardinal_of(mention: dict) -> str | None:
    """The selected root, or None — the sentinel never leaves this module."""
    value = mention.get("selected_cardinal")
    return None if value in (None, NONE_SENTINEL) else value


def user_predicate_of(mention: dict) -> str | None:
    value = mention.get("candidate_user_predicate")
    return None if value in (None, NONE_SENTINEL) else value


def is_inferred(mention: dict) -> bool:
    """**The variant is read from `source_field`, never from the absence of a
    key.** A mention missing `start` because the model omitted it and one that
    is inferred are different failures, and a test on absence would call them
    the same thing.
    """
    return mention.get("source_field") == INFERRED_FIELD

#: The characters the wire schema used to refuse by pattern: C0 controls other
#: than tab/LF/CR, and DEL. Tab, LF and CR stay legal, as they were under the
#: pattern's character class.
_REFUSED_CONTROL = frozenset(
    chr(c) for c in (*range(0x00, 0x09), 0x0B, 0x0C, *range(0x0E, 0x20), 0x7F))


class ExtractionInvalid(Exception):
    """A structurally invalid response. Never an abstention."""

    def __init__(self, code: str, detail: str = "") -> None:
        super().__init__(code if not detail else f"{code}: {detail}")
        self.code = code


@dataclass(frozen=True)
class RequestItem:
    """One item as it was sent, which is what the response is checked against."""

    item_index: int
    fields: dict[str, str | list[str]]
    # The exact observed provider action beneath this item (liked_video,
    # subscription, library_song, ...). Contract 8.1: the model must know what
    # kind of fact it is reading, so a like is never dressed up as a watch.
    # Optional with a None default so every existing constructor call — and
    # every request built before the field existed — stays valid.
    source_action: str | None = None
    # The lane the item came from (apple_music, spotify, youtube, apple_calendar
    # ...). Optional for the same reason as `source_action`; when it is absent
    # the lane screen below falls back to the actions that belong to one lane
    # only, and leaves the ambiguous ones (`playlist_item` is both Apple Music
    # and YouTube) alone.
    source_code: str | None = None

    def source_string(self, field: str, index: int | None) -> str:
        if field not in self.fields:
            raise ExtractionInvalid("unknown_source_field", field)
        value = self.fields[field]
        if field == "tags":
            if not isinstance(value, list):
                raise ExtractionInvalid("tags_not_a_list")
            if index is None:
                raise ExtractionInvalid("tag_index_missing")
            if index >= len(value):
                raise ExtractionInvalid("tag_index_out_of_range", str(index))
            return value[index]
        if index is not None:
            raise ExtractionInvalid("index_on_scalar_field", field)
        if not isinstance(value, str):
            raise ExtractionInvalid("scalar_field_not_a_string", field)
        return value


def _validate_text_fields(mention: dict, where: str) -> None:
    """The checks a surface and a label must pass however they arrived.

    Shared by the extracted and inferred paths deliberately: a control
    character or a whitespace-only label is refused for the same reason in
    both, and two copies would be two places to forget one.
    """
    for code, key in (("surface", "surface"),
                      ("label", "canonical_label_hypothesis")):
        value = mention[key]
        if any(ch in _REFUSED_CONTROL for ch in value):
            raise ExtractionInvalid(f"{code}_control_characters", where)
        if not value.strip():
            raise ExtractionInvalid(f"{code}_whitespace_only", where)


def validate_response(response: dict, request: list[RequestItem],
                      parent_candidate_ids: frozenset[str] | None = None) -> None:
    """Raise `ExtractionInvalid` unless the response answers this request.

    Assumes the schema has already passed; this checks only what the schema
    cannot see. `parent_candidate_ids` is the echo set: the ids the request
    supplied, and therefore the only ids a mention may select (§5.2, No model
    IDs). None means the request supplied none — under which every selection
    is an invention and is refused, which is the fail-closed reading.
    """
    if response.get("schema_version") != SCHEMA_VERSION:
        raise ExtractionInvalid("schema_version_mismatch",
                                str(response.get("schema_version")))

    items = response.get("items")
    if not isinstance(items, list):
        raise ExtractionInvalid("items_not_a_list")

    # **Exactly once, and contiguous.** A response covering item 0 twice and
    # item 1 never is a plausible model failure and would otherwise be read as
    # one extraction and one silent loss.
    seen = [item.get("item_index") for item in items]
    expected = [entry.item_index for entry in request]
    if sorted(seen) != sorted(expected):
        raise ExtractionInvalid("item_indices_do_not_match_request",
                                f"{sorted(seen)} vs {sorted(expected)}")
    if len(set(seen)) != len(seen):
        raise ExtractionInvalid("duplicate_item_index")
    if sorted(expected) != list(range(len(expected))):
        raise ExtractionInvalid("request_indices_not_contiguous", str(expected))

    by_index = {entry.item_index: entry for entry in request}
    supplied = parent_candidate_ids or frozenset()
    for item in items:
        _validate_item(item, by_index[item["item_index"]], supplied)


def _validate_cardinal_fields(mention: dict,
                              supplied: frozenset[str]) -> None:
    """The §5.2 checks the schema cannot make, on every mention variant.

    The schema already closes the enums; what it cannot see is the request —
    so the echo rule lives here. An id the request did not supply is an
    invented id whichever field carries it.
    """
    family = mention.get("family_hypothesis")
    cardinal = mention.get("selected_cardinal")
    if cardinal not in (None, NONE_SENTINEL) and family in FAMILY_CARDINAL:
        expected = FAMILY_CARDINAL[family]
        if expected != cardinal:
            # The v6 corpus is the argument: a group filed as anime is a
            # family and a root telling two different stories about one
            # surface, and a stored contradiction cannot be repaired later.
            raise ExtractionInvalid("family_root_mismatch",
                                    f"{family} is not {cardinal}")
    chosen = mention.get("parent_candidate_id")
    proposals = mention.get("missing_parent_proposals") or []
    proposal = proposals[0] if proposals else None
    if chosen is not None and proposal is not None:
        raise ExtractionInvalid("parent_both_chosen_and_proposed")
    if chosen is not None and chosen not in supplied:
        raise ExtractionInvalid("parent_not_in_candidates")
    if proposal is not None:
        label = proposal["label"].strip().lower()
        if not label:
            raise ExtractionInvalid("parent_label_whitespace_only")
        # §5.3: a definition that merely restates the label defines nothing.
        if proposal["definition"].strip().lower() == label:
            raise ExtractionInvalid("parent_definition_circular")
        children = [c.strip().lower() for c in proposal["example_children"]]
        # §5.3: refused when its only example child is the proposed leaf —
        # here the leaf is the mention itself, under either of its names.
        leaf_names = {mention["surface"].strip().lower(),
                      mention["canonical_label_hypothesis"].strip().lower()}
        if len(children) == 1 and children[0] in leaf_names:
            raise ExtractionInvalid("parent_only_example_is_the_leaf")
        broader = proposal["broader_parent_id"]
        if broader is not None and broader not in supplied:
            raise ExtractionInvalid("parent_broader_not_in_candidates")


def _validate_item(item: dict, request_item: RequestItem,
                   supplied: frozenset[str] = frozenset()) -> None:
    spans: set[tuple[str, int | None, int, int, str]] = set()
    asserted: set[tuple[str, str]] = set()
    for mention in item.get("mentions", []):
        _validate_cardinal_fields(mention, supplied)
        if is_inferred(mention):
            # **An inferred mention is checked for everything except its span.**
            # It has none: it was asserted, not read. What still holds is that
            # it says something sayable — no control characters, nothing
            # whitespace-only, and not the same claim twice.
            _validate_text_fields(mention, INFERRED_FIELD)
            key = (mention["surface"], mention["mention_role"])
            if key in asserted:
                raise ExtractionInvalid("duplicate_inferred_claim")
            asserted.add(key)
            continue
        field = mention["source_field"]
        index = mention["source_field_index"]
        start, end = mention["start"], mention["end"]

        if end <= start:
            raise ExtractionInvalid("end_not_after_start", f"{start},{end}")

        source = request_item.source_string(field, index)
        # Code points, deliberately: `len` on a Python string counts them.
        if end > len(source):
            raise ExtractionInvalid("offset_out_of_bounds",
                                    f"{end} > {len(source)}")

        surface = mention["surface"]

        # **The schema carries no `pattern` for these strings on purpose, so
        # both of the pattern's guarantees live here.** xgrammar 0.2.3 — the
        # structured-output backend the serving image compiles the schema with
        # — leaks at the token level on patterned strings: its matcher accepts
        # token paths outside the string language and then admits
        # schema-illegal continuations downstream, which surfaced as the model
        # emitting families outside the enum and running to the token cap.
        # Measured against the live endpoint and reproduced locally with the
        # real tokenizer, 2026-08-19. This is the layer for what the schema
        # cannot safely express: no control characters (C0 or DEL), and not
        # all whitespace.
        _validate_text_fields(mention, f"{field}[{start}:{end}]")

        expected = source[start:end]

        # **The normalisation case is diagnosed first, because after the
        # equality it cannot be diagnosed at all.** This read
        # `if surface != expected: raise` and then asked whether the two differed
        # in normalisation state — of two strings the previous line had just
        # established were equal. `NFC(x) != x and NFC(x) == x` is a
        # contradiction, so `surface_not_normalised_like_source` could never be
        # raised, and the one branch with no test was the one that could not
        # fire. That is the usual signature.
        #
        # Ordered this way the two refusals answer different questions: the model
        # pointed at the right span and disagreed about composition, or it
        # pointed at the wrong span. Both are structural failures and neither is
        # an abstention.
        #
        # **Normalisation is compared, never applied.** Rewriting either side to
        # NFC would make the equality pass for a response that did not agree with
        # the source, which is the whole point of comparing them.
        if surface != expected:
            # The message carries no payload — neither the surface nor the
            # source — because a mismatch is most likely on somebody's title.
            if (unicodedata.normalize("NFC", surface)
                    == unicodedata.normalize("NFC", expected)):
                raise ExtractionInvalid("surface_normalization_mismatch",
                                        f"{field}[{start}:{end}]")
            raise ExtractionInvalid("surface_offset_mismatch",
                                    f"{field}[{start}:{end}]")

        key = (field, index, start, end, mention["mention_role"])
        if key in spans:
            raise ExtractionInvalid("duplicate_span_and_role")
        spans.add(key)


#: **A television family is screened by lane, not prompted away (2026-09-07).**
#: v23 measured the model stretching `tv_show` onto calendar reservations
#: (Hanoi House, Madame Vo NYC) and `tv_series` onto cast recordings and an IU
#: album, and the sentence written to forbid restaurants was the one place the
#: prompt said "restaurant" — the negation became the cue. A manufactured
#: representation is validated, never prompted (§2.20), and this is the rule
#: the lanes state: a bare calendar title is never a programme; a music-lane
#: row names a programme only when its own text carries a series marker (an
#: OST credit, 电视剧《…》, 드라마, a season); the YouTube lane, where the
#: shows actually appear, is left to the definitions.
TV_FAMILIES = frozenset({"tv_series", "tv_show", "documentary"})
CALENDAR_SOURCES = frozenset({"apple_calendar", "google_calendar", "outlook_calendar"})
MUSIC_SOURCES = frozenset({"apple_music", "music_library", "spotify"})
#: Actions that belong to exactly one lane, for requests that carry no source.
CALENDAR_ONLY_ACTIONS = frozenset({"event"})
MUSIC_ONLY_ACTIONS = frozenset({
    "library_song", "library_album", "library_artist", "library_playlist",
    "recently_added", "recently_played", "heavy_rotation", "rating",
    "apple_music_subscription", "followed_artist", "saved_album",
    "saved_track", "top_artist", "top_track",
})
SERIES_MARKER = re.compile(
    r"(?i)\b(ost|soundtrack|original television|tv series|television|drama|season)\b"
    r"|电视剧|電視劇|影集|剧集|劇集|片头曲|片頭曲|片尾曲|插曲|主题曲|主題曲"
    r"|드라마|시즌|ドラマ|主題歌|挿入歌|第.{1,3}[季期]")


#: A YouTube subscription is a channel. The model may not say `channel`
#: (it is one of the six forbidden families), so on a subscription row it
#: reached for `tv_show` — "Professor Dave Explains", "Asmongold TV",
#: "Sanbomics" — on every run measured (v22, v23). A channel's programme is
#: found on its videos, never on the subscription itself.
CHANNEL_ACTIONS = frozenset({"subscription"})


def _lane(item: RequestItem) -> str | None:
    if item.source_action in CHANNEL_ACTIONS:
        return "channel"
    if item.source_code in CALENDAR_SOURCES:
        return "calendar"
    if item.source_code in MUSIC_SOURCES:
        return "music"
    if item.source_code:
        return "other"
    if item.source_action in CALENDAR_ONLY_ACTIONS:
        return "calendar"
    if item.source_action in MUSIC_ONLY_ACTIONS:
        return "music"
    return None


def screen_families(response: dict, request: list[RequestItem]) -> int:
    """Drop television mentions a lane cannot produce; return how many.

    Runs beside `repair_offsets`, before validation, and like it mutates in
    place and counts rather than swallows. An extracted item left with no
    mentions becomes an abstention with `no_durable_subject`, which is the
    answer the model should have given.
    """
    by_index = {item.item_index: item for item in request}
    dropped = 0
    for item in response.get("items", []):
        request_item = by_index.get(item.get("item_index"))
        if request_item is None:
            continue
        lane = _lane(request_item)
        if lane not in ("calendar", "music", "channel"):
            continue
        text = " ".join(
            " ".join(v) if isinstance(v, list) else str(v)
            for v in request_item.fields.values())
        marked = bool(SERIES_MARKER.search(text))
        kept = []
        for mention in item.get("mentions") or []:
            family = mention.get("family_hypothesis")
            if family in TV_FAMILIES and (lane in ("calendar", "channel") or not marked):
                dropped += 1
                continue
            kept.append(mention)
        if len(kept) != len(item.get("mentions") or []):
            item["mentions"] = kept
            if not kept and item.get("status") == "extracted":
                item["status"] = "abstained"
                item["abstain_reason"] = "no_durable_subject"
    return dropped


def repair_offsets(response: dict, request: list[RequestItem]) -> int:
    """Recompute start/end from the surface where that is the only honest read.

    The model names the right entity and miscounts its code points — measured
    2026-08-19 on the live endpoint, where offset arithmetic was the whole of
    the remaining failure class after the grammar bound. When the emitted
    `surface` occurs **exactly once** in the source field the model cited, the
    span is not in doubt: the entity was correctly identified and only the
    arithmetic was off, so the offsets are recomputed from the one place the
    surface exists. Zero occurrences and two-or-more are left alone for
    `validate_response` to refuse — a repair that guessed between two
    occurrences would be inventing a span, which is the thing this condition
    exists to make impossible.

    Mutates the response in place and returns how many mentions were repaired,
    because a repair is a fact about the model worth counting, never
    swallowing. Runs before validation and repairs only the arithmetic —
    every other refusal (enums, guards, span equality where the surface is
    absent or ambiguous) still fires exactly as before.

    The search is over raw code points, deliberately: normalisation is
    compared by the validator, never applied, and a repair that matched an
    NFC-folded surface to a decomposed source would hide the disagreement the
    `surface_normalization_mismatch` refusal exists to surface.
    """
    by_index = {entry.item_index: entry for entry in request}
    repaired = 0
    for item in response.get("items", []):
        request_item = by_index.get(item.get("item_index"))
        if request_item is None:
            continue
        for mention in item.get("mentions", []):
            try:
                source = request_item.source_string(
                    mention.get("source_field"), mention.get("source_field_index"))
            except ExtractionInvalid:
                continue  # validate_response will say why, with its own code
            if is_inferred(mention):
                continue  # no span to repair; it was never read from a field
            surface = mention.get("surface")
            if not isinstance(surface, str) or not surface:
                continue
            start, end = mention.get("start"), mention.get("end")
            # **Bounds before equality, because slicing clamps.** With `end`
            # one past the source, `source[start:end]` silently truncates and
            # can still equal the surface — which read as "arithmetic already
            # right" and left the out-of-bounds end for the validator to
            # refuse. An in-bounds equal slice is the only thing that means
            # nothing needs repairing.
            in_bounds = (isinstance(start, int) and isinstance(end, int)
                         and 0 <= start and end <= len(source))
            if in_bounds and source[start:end] == surface:
                continue  # arithmetic already right; nothing to repair
            occurrences = []
            at = source.find(surface)
            while at != -1:
                occurrences.append(at)
                at = source.find(surface, at + 1)
            if not occurrences:
                continue  # absent: hallucination, and a refusal rather than a repair
            if len(occurrences) == 1:
                found = occurrences[0]
            else:
                # **Repeated surface: the nearest occurrence to what the model
                # said.** Declining here was costing far more than it protected
                # — measured 2026-08-20 on the live lane, 382 of 540 YouTube
                # extractions were refused as `offset_invalid` against 46 of
                # 251 for music, because a long title repeats its own words and
                # every repeat made the span "ambiguous".
                #
                # It was never ambiguous about *the term*. Every candidate span
                # holds the identical string, so whichever is chosen the mention
                # text is the same; only the span differs, and the span is
                # provenance rather than meaning. Choosing the one closest to
                # the model's stated start uses its claim as the hint it is,
                # and still cannot invent: the span always contains the exact
                # surface, and a surface absent from the source is refused
                # above as it always was.
                hint = start if isinstance(start, int) else 0
                found = min(occurrences, key=lambda index: (abs(index - hint), index))
            mention["start"] = found
            mention["end"] = found + len(surface)
            repaired += 1
    return repaired


def validate_with_schema(response: dict, request: list[RequestItem],
                         schema: dict,
                         parent_candidate_ids: frozenset[str] | None = None
                         ) -> None:
    """Both layers, in the order a gateway must run them."""
    import jsonschema

    jsonschema.Draft202012Validator(schema).validate(response)
    validate_response(response, request, parent_candidate_ids)
