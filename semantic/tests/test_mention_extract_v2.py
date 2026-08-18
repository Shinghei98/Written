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
               / "contracts" / "mention_extract_v2.schema.json")


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
    }
    base.update(overrides)
    return base


def response(items) -> dict:
    return {"schema_version": "mention_extract_v2", "items": items}


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

    families = schema["$defs"]["mention"]["properties"]["family_hypothesis"]["enum"]
    assert "music_recording" not in families
    assert "music_work" in families, "music_work is a composition and stays"

    bad = response([extracted(mentions=[mention(family_hypothesis="music_recording")])])
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.Draft202012Validator(schema).validate(bad)


def test_removed_fields_are_refused(schema):
    """`additionalProperties: false` is what makes the removal real."""
    import jsonschema

    for field, value in (("evidence_fields", ["title"]),
                         ("lookup_queries", ["q"]),
                         ("relation_hypotheses", [])):
        bad = response([extracted(mentions=[mention(**{field: value})])])
        with pytest.raises(jsonschema.ValidationError):
            jsonschema.Draft202012Validator(schema).validate(bad)


def test_batch_stays_two(schema):
    import jsonschema

    assert schema["properties"]["items"]["maxItems"] == 2
    three = response([extracted(0), extracted(1),
                      {"item_index": 1, "status": "abstained", "mentions": [],
                       "abstain_reason": "ambiguous"}])
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.Draft202012Validator(schema).validate(three)


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


@pytest.mark.parametrize("bad", ["   ", "\t", "a\x00b", "a\x1fb", "a\x7fb"])
def test_whitespace_only_and_control_characters_are_refused(schema, bad):
    import jsonschema

    with pytest.raises(jsonschema.ValidationError):
        jsonschema.Draft202012Validator(schema).validate(
            response([extracted(mentions=[mention(surface=bad)])]))


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
