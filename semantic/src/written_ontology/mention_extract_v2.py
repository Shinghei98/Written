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

import unicodedata
from dataclasses import dataclass

SCHEMA_VERSION = "mention_extract_v2"

#: The fields a request may offer, mirroring the schema's `source_field` enum.
#: A response naming anything else is refused before its offsets are read.
SOURCE_FIELDS = ("title", "channel_label", "description_excerpt", "tags")


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


def validate_response(response: dict, request: list[RequestItem]) -> None:
    """Raise `ExtractionInvalid` unless the response answers this request.

    Assumes the schema has already passed; this checks only what the schema
    cannot see.
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
    for item in items:
        _validate_item(item, by_index[item["item_index"]])


def _validate_item(item: dict, request_item: RequestItem) -> None:
    spans: set[tuple[str, int | None, int, int, str]] = set()
    for mention in item.get("mentions", []):
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


def validate_with_schema(response: dict, request: list[RequestItem],
                         schema: dict) -> None:
    """Both layers, in the order a gateway must run them."""
    import jsonschema

    jsonschema.Draft202012Validator(schema).validate(response)
    validate_response(response, request)
