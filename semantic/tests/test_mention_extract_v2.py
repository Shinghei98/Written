"""`mention_extract_v2`: the schema, and the four conditions it cannot express.

Every executable condition the 2026-08-18 memo lists has a test here, and each
is exercised **in both directions** — a valid response accepted and an invalid
one refused. A validator observed only accepting is one nobody has tested.
"""

from __future__ import annotations

import json
import pathlib

import pytest

from written_ontology.mention_extract_v2 import (
    ExtractionInvalid,
    RequestItem,
    validate_response,
    validate_with_schema,
)

SCHEMA_PATH = (pathlib.Path(__file__).resolve().parent.parent
               / "contracts" / "mention_extract_v3.schema.json")


@pytest.fixture(scope="module")
def schema() -> dict:
    return json.loads(SCHEMA_PATH.read_text())


def mention(**overrides) -> dict:
    base = {
        "surface": "Midnight",
        "source_field": "title",
        "source_field_index": None,
        "start": 0,
        "end": 8,
        "canonical_label_hypothesis": "Midnight",
        "family_hypothesis": "work",
        "mention_role": "work_or_franchise",
        "conversation_worthy": True,
        # v3: present on every variant, and nullable/empty rather than
        # optional — a model permitted to omit a field omits it, and the
        # English name is the one the owner asked for by name.
        "english_label": None,
        "original_label": None,
        "relation_hypotheses": [],
    }
    base.update(overrides)
    return base


def inferred_mention(**overrides) -> dict:
    """A term the model asserts rather than reads. No span, by construction."""
    base = {
        "surface": "One Piece",
        "source_field": "inferred",
        "canonical_label_hypothesis": "One Piece",
        "family_hypothesis": "franchise",
        "mention_role": "work_or_franchise",
        "conversation_worthy": True,
        "english_label": "One Piece",
        "original_label": "ワンピース",
        "relation_hypotheses": [],
    }
    base.update(overrides)
    return base


def response(items) -> dict:
    return {"schema_version": "mention_extract_v3", "items": items}


def extracted(index=0, mentions=None) -> dict:
    return {"item_index": index, "status": "extracted",
            "mentions": mentions if mentions is not None else [mention()],
            "abstain_reason": None}


REQUEST = [RequestItem(0, {"title": "Midnight", "tags": ["kpop", "ballad"]})]


# ---------------------------------------------------------------------------
# The schema's own conditions
# ---------------------------------------------------------------------------

def test_a_valid_response_passes_both_layers(schema):
    validate_with_schema(response([extracted()]), REQUEST, schema)


def test_music_recording_is_not_a_family(schema):
    """`0221` removed recordings from the versioned ontology. A model emitting
    that family would reopen the minting route it closed."""
    import jsonschema

    # The schema now carries two mention variants (the tags/index conditional
    # became anyOf variants because xgrammar cannot compile if/then); the rule
    # must hold in both, or one door refuses what the other admits.
    for variant in ("mention_text", "mention_tag"):
        families = schema["$defs"][variant]["properties"]["family_hypothesis"]["enum"]
        assert "music_recording" not in families
        assert "music_work" in families, "music_work is a composition and stays"

    bad = response([extracted(mentions=[mention(family_hypothesis="music_recording")])])
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.Draft202012Validator(schema).validate(bad)


def test_removed_fields_are_refused(schema):
    """`additionalProperties: false` is what makes the removal real."""
    import jsonschema

    # **`relation_hypotheses` is no longer among them.** v3 restored it, so a
    # term can arrive with its predicate attached — "Luffy part_of_franchise
    # One Piece". The other two stay removed because nothing reads them, which
    # was always the reason.
    for field, value in (("evidence_fields", ["title"]),
                         ("lookup_queries", ["q"])):
        bad = response([extracted(mentions=[mention(**{field: value})])])
        with pytest.raises(jsonschema.ValidationError):
            jsonschema.Draft202012Validator(schema).validate(bad)


def test_the_batch_is_bounded_by_the_wire_maximum(schema):
    """The bound is the workbook's, and one past it is refused.

    It was pinned at two through the grammar shakedown, then raised to eight
    against measured output: 114 real two-item calls averaged 307 output
    tokens and peaked at 787, against a per-item reserve of 1280. The number
    is read from the schema rather than written here twice — a test asserting
    its own copy of the bound can only ever agree with itself.
    """
    import jsonschema

    wire = schema["properties"]["items"]["maxItems"]
    assert wire >= 2
    over = response([extracted(index % wire) for index in range(wire + 1)])
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.Draft202012Validator(schema).validate(over)


@pytest.mark.parametrize("item,ok", [
    ({"item_index": 0, "status": "extracted", "mentions": [], "abstain_reason": None}, False),
    ({"item_index": 0, "status": "extracted", "mentions": [],
      "abstain_reason": "ambiguous"}, False),
    ({"item_index": 0, "status": "abstained", "mentions": [],
      "abstain_reason": "ambiguous"}, True),
    ({"item_index": 0, "status": "abstained", "mentions": [], "abstain_reason": None}, False),
])
def test_status_mentions_and_reason_must_agree(schema, item, ok):
    """Three fields that can disagree three ways, made executable."""
    import jsonschema

    validator = jsonschema.Draft202012Validator(schema)
    if ok:
        validator.validate(response([item]))
    else:
        with pytest.raises(jsonschema.ValidationError):
            validator.validate(response([item]))


def test_tag_index_required_for_tags_and_null_otherwise(schema):
    import jsonschema

    validator = jsonschema.Draft202012Validator(schema)
    validator.validate(response([extracted(mentions=[
        mention(surface="kpop", source_field="tags", source_field_index=0, end=4)])]))
    with pytest.raises(jsonschema.ValidationError):
        validator.validate(response([extracted(mentions=[
            mention(source_field="tags", source_field_index=None)])]))
    with pytest.raises(jsonschema.ValidationError):
        validator.validate(response([extracted(mentions=[
            mention(source_field="title", source_field_index=2)])]))


@pytest.mark.parametrize("bad", ["   ", "\t", "a\x00b", "a\x1fb", "a\x7fb",
                                 "\u00a0", "\u3000", " \u2003 "])
def test_whitespace_only_and_control_characters_are_refused(schema, bad):
    """These moved from the schema's `pattern` to the second layer.

    xgrammar 0.2.3's token matcher leaks on patterned strings — it accepts
    token paths outside the string language and then admits schema-illegal
    continuations downstream — so the schema carries no pattern and the
    refusal lives in `validate_response`, which also covers the non-ASCII
    whitespace the old pattern's ASCII classes never could. The refusal fires
    before the surface/offset equality, so it needs no matching source.
    """
    with pytest.raises(ExtractionInvalid) as caught:
        validate_response(response([extracted(mentions=[mention(surface=bad)])]),
                          REQUEST)
    assert caught.value.code in ("surface_whitespace_only",
                                 "surface_control_characters")


@pytest.mark.parametrize("bad", ["   ", "a\x00b"])
def test_label_gets_the_same_guards(schema, bad):
    with pytest.raises(ExtractionInvalid) as caught:
        validate_response(response([extracted(mentions=[
            mention(canonical_label_hypothesis=bad)])]), REQUEST)
    assert caught.value.code in ("label_whitespace_only",
                                 "label_control_characters")


# ---------------------------------------------------------------------------
# What the schema cannot see
# ---------------------------------------------------------------------------

def test_every_request_item_appears_exactly_once():
    with pytest.raises(ExtractionInvalid) as caught:
        validate_response(response([extracted(0), extracted(0)]), REQUEST)
    assert caught.value.code in {"item_indices_do_not_match_request",
                                 "duplicate_item_index"}

    two = [RequestItem(0, {"title": "Midnight"}), RequestItem(1, {"title": "Neon"})]
    with pytest.raises(ExtractionInvalid) as caught:
        validate_response(response([extracted(0)]), two)
    assert caught.value.code == "item_indices_do_not_match_request"


def test_end_must_be_after_start():
    with pytest.raises(ExtractionInvalid) as caught:
        validate_response(response([extracted(mentions=[mention(start=4, end=4)])]),
                          REQUEST)
    assert caught.value.code == "end_not_after_start"


def test_offsets_must_be_in_bounds():
    with pytest.raises(ExtractionInvalid) as caught:
        validate_response(response([extracted(mentions=[mention(end=99)])]), REQUEST)
    assert caught.value.code == "offset_out_of_bounds"


def test_surface_must_equal_the_source_slice():
    with pytest.raises(ExtractionInvalid) as caught:
        validate_response(response([extracted(mentions=[mention(surface="Midnigh")])]),
                          REQUEST)
    assert caught.value.code == "surface_offset_mismatch"


# ---------------------------------------------------------------------------
# Normalisation, which is compared and never applied
# ---------------------------------------------------------------------------
#
# `é` has two legal spellings: one code point (NFC, U+00E9) and two (NFD, e +
# U+0301). A model that echoes the composed form against a decomposed source has
# not pointed at the wrong text — it has disagreed about composition, and saying
# so is the difference between a bug report and a shrug. The refusal used to be
# unreachable: it was asked after an equality check had already established the
# two strings were identical.

NFD_SOURCE = "Beyonce\u0301"      # 8 code points: "Beyonce" + combining acute
NFC_SURFACE = "Beyonc\u00e9"      # 7 code points: "Beyonc" + precomposed é


def test_a_decomposed_surface_matching_a_decomposed_source_is_accepted():
    """Equality first, and no rewriting on either side.

    The source is NFD and the surface is the same NFD text. Nothing here needs
    normalising and nothing is normalised — a validator that folded both to NFC
    would accept this too, and would also accept the case below, which is what
    makes folding wrong rather than merely lenient.
    """
    request = [RequestItem(0, {"title": NFD_SOURCE})]
    validate_response(
        response([extracted(mentions=[mention(surface=NFD_SOURCE, start=0,
                                              end=len(NFD_SOURCE))])]),
        request)


def test_a_composed_surface_against_a_decomposed_source_is_a_normalisation_mismatch():
    """The refusal that could never fire.

    Same characters, different composition, and the span is right — so the
    diagnosis is about normalisation rather than about offsets. It is still a
    structural failure and still not an abstention: the model misbehaved, it did
    not report that the item had no durable subject.
    """
    request = [RequestItem(0, {"title": NFD_SOURCE})]
    with pytest.raises(ExtractionInvalid) as caught:
        validate_response(
            response([extracted(mentions=[mention(surface=NFC_SURFACE, start=0,
                                                  end=len(NFD_SOURCE))])]),
            request)
    assert caught.value.code == "surface_normalization_mismatch"


def test_genuinely_different_text_is_still_an_offset_mismatch():
    """Ordering the normalisation case first must not swallow the general one.

    "Beyonce!" is not a normalisation variant of anything in the source, so it
    falls through to the offset diagnosis — which is the check that catches a
    model pointing at the wrong span.
    """
    request = [RequestItem(0, {"title": NFD_SOURCE})]
    with pytest.raises(ExtractionInvalid) as caught:
        validate_response(
            response([extracted(mentions=[mention(surface="Beyonce!", start=0,
                                                  end=len(NFD_SOURCE))])]),
            request)
    assert caught.value.code == "surface_offset_mismatch"


def test_offsets_are_code_points_not_utf16():
    """**The check `surface` exists for.**

    "🎵ab" is three code points and four UTF-16 units. A model counting UTF-16
    reports the "ab" span as 2..4; by code point that is one past the end of a
    three-character string, so the mismatch is caught rather than silently
    slicing the wrong text.
    """
    request = [RequestItem(0, {"title": "🎵ab"})]
    validate_response(
        response([extracted(mentions=[mention(surface="ab", start=1, end=3)])]),
        request)

    with pytest.raises(ExtractionInvalid) as caught:
        validate_response(
            response([extracted(mentions=[mention(surface="ab", start=2, end=4)])]),
            request)
    assert caught.value.code in {"offset_out_of_bounds", "surface_offset_mismatch"}


def test_duplicate_span_and_role_is_refused():
    doubled = [mention(), mention()]
    with pytest.raises(ExtractionInvalid) as caught:
        validate_response(response([extracted(mentions=doubled)]), REQUEST)
    assert caught.value.code == "duplicate_span_and_role"


def test_the_same_span_under_a_different_role_is_allowed():
    """A title can be both the work and the primary subject. Only the pair is
    a duplicate, and refusing the span alone would lose real structure."""
    pair = [mention(), mention(mention_role="primary_subject")]
    validate_response(response([extracted(mentions=pair)]), REQUEST)


def test_a_tag_index_beyond_the_request_is_refused():
    with pytest.raises(ExtractionInvalid) as caught:
        validate_response(response([extracted(mentions=[
            mention(surface="kpop", source_field="tags",
                    source_field_index=9, end=4)])]), REQUEST)
    assert caught.value.code == "tag_index_out_of_range"


def test_no_refusal_is_an_abstention():
    """**Structural failure must never become evidence about a person.**

    An abstention says the item had no durable subject. A malformed response
    says the model misbehaved. Recording the second as the first would put a
    bug into somebody's profile.
    """
    reasons = {"no_durable_subject", "hard_suppressed", "ambiguous",
               "insufficient_context", "invalid_input"}
    # Each case carries its own request. The normalisation refusal cannot be
    # reached against `REQUEST` — "Midnight" has no composed form to disagree
    # about — so a case appended to a fixed-request sweep would have raised
    # `surface_offset_mismatch`, passed, and tested nothing.
    nfd = [RequestItem(0, {"title": NFD_SOURCE})]
    seen = set()
    for bad, request in (
        (response([extracted(mentions=[mention(end=99)])]), REQUEST),
        (response([extracted(mentions=[mention(surface="wrong")])]), REQUEST),
        (response([extracted(mentions=[mention(surface=NFC_SURFACE, start=0,
                                               end=len(NFD_SOURCE))])]), nfd),
        (response([extracted(0), extracted(0)]), REQUEST),
    ):
        with pytest.raises(ExtractionInvalid) as caught:
            validate_response(bad, request)
        assert caught.value.code not in reasons
        seen.add(caught.value.code)

    # And the normalisation refusal was actually among them, rather than a case
    # that quietly fell through to a different diagnosis.
    assert "surface_normalization_mismatch" in seen


# ---------------------------------------------------------------------------
# The offset repair: arithmetic fixed, spans never invented
# ---------------------------------------------------------------------------

def test_repair_fixes_a_unique_surface_with_wrong_offsets():
    """The entity was correctly identified; only the arithmetic was off."""
    from written_ontology.mention_extract_v2 import repair_offsets

    resp = response([extracted(mentions=[mention(start=1, end=6)])])
    repaired = repair_offsets(resp, REQUEST)
    assert repaired == 1
    m = resp["items"][0]["mentions"][0]
    assert (m["start"], m["end"]) == (0, 8)
    validate_response(resp, REQUEST)  # and the repaired span now validates


def test_repair_leaves_correct_offsets_alone():
    from written_ontology.mention_extract_v2 import repair_offsets

    resp = response([extracted()])
    assert repair_offsets(resp, REQUEST) == 0


def test_repair_chooses_between_two_occurrences_by_the_stated_offset(schema):
    """**This reverses a rule, and the reversal is the point.**

    Refusing a repeated surface was written to make inventing a span
    impossible. It does not: every occurrence holds the identical string, so
    the mention text is the same whichever is chosen and only the provenance
    span moves. What it did do was refuse 382 of 540 YouTube extractions as
    `offset_invalid` against 46 of 251 for music — long titles repeat their own
    words, so the lane whose whole purpose is discovery lost 71% of it to a
    guard protecting nothing. The stated offset picks between them.
    """
    from written_ontology.mention_extract_v2 import repair_offsets

    request = [RequestItem(0, {"title": "Midnight to Midnight"})]
    resp = response([extracted(mentions=[mention(start=3, end=11)])])
    assert repair_offsets(resp, request) == 1
    repaired = resp["items"][0]["mentions"][0]
    assert request[0].fields["title"][repaired["start"]:repaired["end"]] == "Midnight"
    # 0 and 12 both hold it; the stated 3 is nearer 0.
    assert repaired["start"] == 0


def test_repair_leaves_an_absent_surface_for_the_validator():
    from written_ontology.mention_extract_v2 import repair_offsets

    resp = response([extracted(mentions=[mention(surface="Noon")])])
    assert repair_offsets(resp, REQUEST) == 0
    with pytest.raises(ExtractionInvalid) as caught:
        validate_response(resp, REQUEST)
    assert caught.value.code == "surface_offset_mismatch"


def test_repair_works_inside_tags():
    from written_ontology.mention_extract_v2 import repair_offsets

    resp = response([extracted(mentions=[mention(
        surface="kpop", source_field="tags", source_field_index=0,
        start=1, end=3, canonical_label_hypothesis="kpop")])])
    assert repair_offsets(resp, REQUEST) == 1
    m = resp["items"][0]["mentions"][0]
    assert (m["start"], m["end"]) == (0, 4)


def test_repair_catches_a_clamped_slice_whose_end_is_out_of_bounds():
    """`source[start:end]` clamps when `end` overruns, so the slice can equal
    the surface while the offsets are still wrong — measured on fx_001/fx_002,
    where the model cited an end one past the title. Bounds are checked before
    the equality, so this repairs instead of skipping."""
    from written_ontology.mention_extract_v2 import repair_offsets

    resp = response([extracted(mentions=[mention(start=0, end=9)])])  # len is 8
    assert repair_offsets(resp, REQUEST) == 1
    m = resp["items"][0]["mentions"][0]
    assert (m["start"], m["end"]) == (0, 8)
    validate_response(resp, REQUEST)


def test_a_repeated_surface_is_repaired_to_the_nearest_occurrence(schema):
    """It was refused, and refusing cost 71% of the YouTube lane.

    Every occurrence of a repeated surface holds the identical string, so the
    term extracted is the same whichever is chosen; only the provenance span
    differs. The model's stated start picks between them.
    """
    from written_ontology.mention_extract_v2 import RequestItem, repair_offsets

    source = "Live at Wembley (Live) [Live Version]"
    item = RequestItem(0, {"title": source})
    # Three occurrences of "Live"; the model meant the third and miscounted.
    response = {"items": [{"item_index": 0, "status": "extracted",
                           "abstain_reason": None,
                           "mentions": [{"surface": "Live", "start": 26, "end": 30,
                                         "source_field": "title",
                                         "source_field_index": None,
                                         "mention_role": "primary_subject",
                                         "type_hint": "work",
                                         "evidence_fields": ["title"]}]}]}
    assert repair_offsets(response, [item]) == 1
    mention = response["items"][0]["mentions"][0]
    assert source[mention["start"]:mention["end"]] == "Live"
    # Three occurrences — 0, 17, 24 — and the stated 26 names the last.
    assert mention["start"] == 24


def test_a_surface_absent_from_the_source_is_still_refused(schema):
    """The widening must not reach the case it exists to catch."""
    from written_ontology.mention_extract_v2 import RequestItem, repair_offsets

    item = RequestItem(0, {"title": "Live at Wembley"})
    response = {"items": [{"item_index": 0, "status": "extracted",
                           "abstain_reason": None,
                           "mentions": [{"surface": "Glastonbury", "start": 0, "end": 11,
                                         "source_field": "title",
                                         "source_field_index": None,
                                         "mention_role": "primary_subject",
                                         "type_hint": "work",
                                         "evidence_fields": ["title"]}]}]}
    assert repair_offsets(response, [item]) == 0


# ---------------------------------------------------------------------------
# The inferred variant
# ---------------------------------------------------------------------------

def test_an_inferred_mention_needs_no_span(schema):
    """**The change the dictionary exists for.** "One Piece" is not in a title
    that says 路飛, so under v2 it could not be emitted at all: every mention
    required `source_field`, `start` and `end`, and the surface had to equal
    the slice. Dictionary building does not need that guard — users validate,
    and the weight decides what survives.
    """
    request = [RequestItem(0, {"title": "路飛の冒険"})]
    validate_with_schema(
        response([extracted(mentions=[inferred_mention()])]), request, schema)


def test_an_inferred_mention_may_carry_its_relation(schema):
    """Luffy is a character in One Piece — `part_of_franchise`, from the closed
    predicate list the grammar has always carried and nothing has ever used."""
    request = [RequestItem(0, {"title": "路飛の冒険"})]
    resp = response([extracted(mentions=[inferred_mention(
        relation_hypotheses=[{"predicate": "part_of_franchise",
                              "object_label_hypothesis": "One Piece"}])])])
    validate_with_schema(resp, request, schema)


def test_an_inferred_mention_may_not_invent_a_predicate(schema):
    """The grammar is closed even where the nouns are open."""
    import jsonschema

    resp = response([extracted(mentions=[inferred_mention(
        relation_hypotheses=[{"predicate": "is_vibes_with",
                              "object_label_hypothesis": "One Piece"}])])])
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.Draft202012Validator(schema).validate(resp)


def test_an_extracted_mention_is_still_held_to_its_source(schema):
    """**The half that must not move.** Inference is permitted; a *claim to
    have read something* that was not there is still a refusal, because that is
    a different lie and the dictionary cannot tell them apart afterwards.
    """
    request = [RequestItem(0, {"title": "Midnight"})]
    with pytest.raises(ExtractionInvalid) as refusal:
        validate_response(
            response([extracted(mentions=[mention(surface="Daybreak")])]), request)
    assert refusal.value.code == "surface_offset_mismatch"


def test_the_same_inferred_claim_twice_is_refused(schema):
    request = [RequestItem(0, {"title": "路飛の冒険"})]
    with pytest.raises(ExtractionInvalid) as refusal:
        validate_response(
            response([extracted(mentions=[inferred_mention(), inferred_mention()])]),
            request)
    assert refusal.value.code == "duplicate_inferred_claim"


def test_repair_leaves_an_inferred_mention_alone(schema):
    """It has no span to repair, and inventing one would be a fabricated
    provenance rather than a corrected arithmetic."""
    from written_ontology.mention_extract_v2 import repair_offsets

    request = [RequestItem(0, {"title": "路飛の冒険"})]
    resp = response([extracted(mentions=[inferred_mention()])])
    assert repair_offsets(resp, request) == 0
    assert "start" not in resp["items"][0]["mentions"][0]
