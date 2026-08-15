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
                    {"id": "159260351",
                     "attributes": {"name": "Taylor Swift",
                                    "genreNames": ["Pop", "Country"]}},
                    {"id": "", "attributes": {"name": "Nameless"}},
                    {"id": "412778295", "attributes": {"name": ""}},
                    {"attributes": {"name": "No id at all"}},
                ]
            }
        }
    }
    assert module.artists_in(song) == [
        ("159260351", "Taylor Swift", ["Pop", "Country"])
    ]


def test_an_artist_with_no_stated_genre_is_still_returned():
    """It gets no parent, which is a better answer than dropping the artist.

    A creator with no `broader` edge is a floating node, but a creator that was
    never minted is invisible. The first is a gap somebody can see.
    """
    module = tool()
    song = {"relationships": {"artists": {"data": [
        {"id": "1", "attributes": {"name": "Unclassified"}},
    ]}}}
    assert module.artists_in(song) == [("1", "Unclassified", [])]


def test_the_genres_that_give_a_minted_creator_its_parent_are_normalized():
    """**The join that places a new artist in the hierarchy is a string match.**

    `0173` matches `genres_normalized` against `concept_labels.normalized_label`
    to mint the `broader` edge, and SQL cannot reproduce a Unicode-category fold
    — so the fold happens here or the artist is minted parentless with nothing
    saying why. `j pop` is the shape that matters: the vocabulary holds
    `genre:j_pop` under exactly that alias.
    """
    import contextlib
    import io

    module = tool()
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        module.emit_artists({"1": {"name": "Aimer", "genres": ["J-Pop", "Anime"]}})
    emitted = buffer.getvalue()
    assert '"genres_normalized": ["j pop", "anime"]' in emitted


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
        module.emit_artists({"412778295": {"name": "P!nk", "genres": []}})
    emitted = buffer.getvalue()

    assert "'artist'" in emitted
    assert '"normalized": "p nk"' in emitted
    assert "'412778295'" in emitted
    # The apostrophe path, which is the one that would end a migration midway.
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        module.emit_artists({"1": {"name": "O'Brien", "genres": []}})
    assert "'O''Brien'" in buffer.getvalue()


def test_a_game_is_recognised_from_the_album_and_a_composer_is_not():
    """The one signal that separates a game from the person who scored it.

    **Measured 2026-08-15.** Apple answers `Where Winds Meet` with
    `genreNames: ["Video Game"]` — and answers `Yida`, who *composed* that
    soundtrack, with exactly the same genre. Routing on the artist genre would
    have minted a songwriter as a video game, and he is an eligible term on a
    real account at 0.424. Only the album title names the game:

        When the Wind Rises (Where Winds Meet Original Game Soundtrack (Qinghe))

    Both directions are asserted, because a rule that only ever answers one way
    has not been shown to discriminate.
    """
    module = tool()
    album = ("When the Wind Rises "
             "(Where Winds Meet Original Game Soundtrack (Qinghe))")
    assert module.game_titles_in(album) == ["Where Winds Meet"]

    games = {module._folded(t) for t in module.game_titles_in(album)}
    assert module._folded("Where Winds Meet") in games      # the game
    assert module._folded("Yida") not in games              # its composer


def test_the_marker_is_read_in_both_album_shapes_and_never_from_a_film():
    """Two shapes, one degenerate case, and one thing that must never match.

    The marker either opens its own bracket or trails the game inside one, and
    the shorter markers are substrings of the longer — so `Original Video Game
    Soundtrack` searched for `game soundtrack` would leave `Original` as the
    title. A film soundtrack must answer nothing at all.
    """
    module = tool()
    assert module.game_titles_in(
        "Final Fantasy XIV: Endwalker (Original Video Game Soundtrack)"
    ) == ["Final Fantasy XIV: Endwalker"]
    assert module.game_titles_in("Hearthstone Original Game Soundtrack") == ["Hearthstone"]
    assert module.game_titles_in("The Last of Us (Video Game Soundtrack)") == ["The Last of Us"]
    # Names that it is a soundtrack and never says to what.
    assert module.game_titles_in("Original Game Soundtrack") == []
    # Film, and an ordinary album.
    assert module.game_titles_in("Interstellar (Original Motion Picture Soundtrack)") == []
    assert module.game_titles_in("1989 (Taylor's Version)") == []
