"""The catalogue tool must mint aliases the resolver can actually match.

**All three failures this covers are silent.** A concept whose `normalized_label`
was computed the wrong way is present, correct by every count, and matches
nothing; a label that collides with another concept downgrades *both* to
`candidate`, which the scorer does not count; and an artist with no id would be
keyed on a name, which is the fragmentation the whole design exists to avoid.
None of them raises, and `0096` is the precedent — 35 concepts minted at once,
every one unresolvable, caught by nobody until somebody went looking.

The normalisation test is the load-bearing one. `tools/seed_from_csv.py:179`
stores `alias.strip().lower()`, while the resolver matches on `normalize_text`,
which folds punctuation and symbols to spaces. For the hand-authored families
that trap was survivable because somebody chose the aliases; catalogue names
arrive verbatim from Apple and are full of punctuation, so a second
implementation here would mint every `P!nk` and `A$AP Rocky` unmatchable.

Skipped when `WRITTEN_REPOSITORY_PATH` is unset, like the rest of the suite.
"""

from __future__ import annotations

import importlib.util
import os
import pathlib

import pytest

REPOSITORY = os.environ.get("WRITTEN_REPOSITORY_PATH")

pytestmark = pytest.mark.skipif(
    not REPOSITORY, reason="WRITTEN_REPOSITORY_PATH is unset"
)


def tool():
    """`tools/apple_catalog.py`, loaded by path.

    It is a script rather than a package and needs no credentials to import —
    every environment read happens inside `main()`.
    """
    path = pathlib.Path(REPOSITORY) / "tools" / "apple_catalog.py"
    spec = importlib.util.spec_from_file_location("apple_catalog", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_the_tool_uses_the_resolvers_own_normalizer():
    """Not a copy of it, and not `str.lower()`.

    Asserted through behaviour rather than by reading the import, because the
    import could be right while a local helper shadowed it.
    """
    from written_ontology.normalize import normalize_text

    module = tool()
    assert module.normalize_text is normalize_text


@pytest.mark.parametrize(
    "name, normalized",
    [
        ("P!nk", "p nk"),
        ("Tyler, The Creator", "tyler the creator"),
        ("A$AP Rocky", "a ap rocky"),
        ("BLACKPINK", "blackpink"),
        # Non-Latin scripts survive whole: `normalize_text` keeps every
        # character in categories L and N, which is why it is used instead of an
        # ASCII fold that would strip these to nothing.
        ("王力宏", "王力宏"),
        ("宇多田ヒカル", "宇多田ヒカル"),
    ],
)
def test_punctuation_folds_the_way_the_resolver_folds_it(name, normalized):
    """`.lower()` would keep the punctuation and never match."""
    module = tool()
    assert module.normalize_text(name) == normalized
    assert name.strip().lower() != normalized or "!" not in name


def test_an_artist_without_an_id_is_refused():
    """The id is the identity; a name is only a label.

    A credit with no id would have to be keyed on its name, which is exactly the
    fragmentation — `Leehom Wang` / `王力宏` / `Wang Leehom` as three concepts —
    that keying on Apple's id exists to prevent.
    """
    module = tool()
    song = {
        "relationships": {
            "artists": {
                "data": [
                    {"id": "159260351", "attributes": {"name": "Taylor Swift"}},
                    {"id": "", "attributes": {"name": "Nameless"}},
                    {"id": "412778295", "attributes": {"name": ""}},
                    {"attributes": {"name": "No id at all"}},
                ]
            }
        }
    }
    assert module.artists_in(song) == [("159260351", "Taylor Swift")]


def test_a_song_with_no_artist_relationship_is_not_an_error():
    """`include=artists` is a request, not a guarantee.

    A song Apple answers for without the relationship must yield nothing rather
    than raise, or one malformed row ends a run that had already paid for every
    request in it.
    """
    module = tool()
    assert module.artists_in({}) == []
    assert module.artists_in({"relationships": {}}) == []
    assert module.artists_in({"relationships": {"artists": {}}}) == []


def test_the_request_asks_for_artists_and_never_for_albums():
    """`include=albums` answers 504 against a `filter[isrc]` query.

    Pinned because the two look interchangeable and the failure is a dead run
    rather than a wrong answer.
    """
    path = pathlib.Path(REPOSITORY) / "tools" / "apple_catalog.py"
    source = path.read_text(encoding="utf-8")
    body = source[source.index("def catalogue("):source.index("def artists_in(")]
    # The request parameter itself, not the prose around it — the docstring
    # names `include=albums` precisely to record why it is not asked for.
    assert '"include": "artists"' in body
    assert '"include": "albums"' not in body


def test_emitted_artist_rows_carry_the_normalized_label():
    """The migration mints from `raw_payload->>'normalized'`.

    SQL cannot reproduce a Unicode-category fold, so if the tool stops writing
    this the minting migration silently refuses every row — it skips anything
    whose `normalized` is empty. That refusal is the safe direction and is
    exactly why it must be tested from this end.
    """
    import contextlib
    import io

    module = tool()
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        module.emit_artists({"412778295": "P!nk"})
    emitted = buffer.getvalue()

    assert "'artist'" in emitted
    assert '"normalized": "p nk"' in emitted
    assert "'412778295'" in emitted
    # The apostrophe path, which is the one that would end a migration midway.
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        module.emit_artists({"1": "O'Brien"})
    assert "'O''Brien'" in buffer.getvalue()
