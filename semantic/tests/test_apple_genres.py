"""Apple's genre tree, and the three things that were wrong before it worked.

Every case here is a mistake this file's subject actually made against the live
API on 2026-08-15, kept so it cannot be made again:

* crawling ids on one storefront finds 22 genres and none of J-Pop, Bollywood or
  Afrobeats — the tree is per storefront;
* an ancestry test that keeps only genres chaining to Music drops eleven real
  ones, because Apple names two parents (`1122` Brazilian, `1262` Indian) that it
  exposes nowhere;
* the stored `normalized` form has to be `normalize_text`'s, not `str.lower()`,
  or every alias is minted unmatchable — `0184` is what that cost.

Skipped when `WRITTEN_REPOSITORY_PATH` is unset, like the rest of the suite.
"""

from __future__ import annotations

import importlib.util
import json
import os

import pytest

REPOSITORY = os.environ.get("WRITTEN_REPOSITORY_PATH")


@pytest.fixture(scope="module")
def genres():
    if not REPOSITORY:
        pytest.skip("WRITTEN_REPOSITORY_PATH is unset")
    path = os.path.join(REPOSITORY, "tools", "apple_genres.py")
    spec = importlib.util.spec_from_file_location("apple_genres", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# Apple's own answers, trimmed to the rows that matter. `1262` and `1122` are
# deliberately absent: they are named as parents and exposed by no storefront.
TREE = {
    "34": {"name": "Music", "parent_id": None},
    "14": {"name": "Pop", "parent_id": "34"},
    "21": {"name": "Rock", "parent_id": "34"},
    "51": {"name": "K-Pop", "parent_id": "14"},
    "1153": {"name": "Metal", "parent_id": "21"},
    "1203": {"name": "African", "parent_id": "34"},
    "1206": {"name": "Afrobeats", "parent_id": "1203"},
    "1264": {"name": "Bollywood", "parent_id": "1262"},
    "1301": {"name": "Samba", "parent_id": "1122"},
}


def test_music_is_excluded_and_a_dangling_parent_is_not(genres):
    """The ancestry test that dropped eleven real genres.

    `Bollywood` and `Samba` cannot reach Music however far their parents are
    walked, because `1262` and `1122` answer 404 from every storefront. Keeping
    only what chains to `34` therefore discarded them — silently, which is the
    part that mattered. Everything the *music* catalogue returns is a music
    genre by construction, so the only thing excluded is Music itself.
    """
    kept = genres.music_genres(TREE)

    assert "34" not in kept, "Music is hub:music, not a genre anybody is"
    assert kept["1264"]["name"] == "Bollywood"
    assert kept["1301"]["name"] == "Samba"
    assert len(kept) == len(TREE) - 1


def test_dangling_parents_are_reported_and_music_is_not(genres):
    """A family about to parent to `hub:music` is a thing to know.

    Reported rather than swallowed: a new unexposed parent means a group of
    genres stops parenting to each other, and finding that from a heading is the
    expensive way. Music must never appear here — it is substituted, not
    missing.
    """
    orphans = genres.dangling_parents(genres.music_genres(TREE))

    assert set(orphans) == {"1122", "1262"}
    assert orphans["1262"] == ["Bollywood"]
    assert "34" not in orphans


def test_the_stored_form_is_the_resolvers_fold(genres):
    """`normalize_text`, never `str.lower()`.

    An alias only matches if its stored form is byte-identical to what the
    resolver computes, and genre names are full of the punctuation that
    separates the two — `Hip-Hop/Rap`, `R&B/Soul`, `Children’s Music` with a
    typographic apostrophe.
    """
    rows = genres.shaped({
        "18": {"name": "Hip-Hop/Rap", "parent_id": "34"},
        "15": {"name": "R&B/Soul", "parent_id": "34"},
        "4": {"name": "Children’s Music", "parent_id": "34"},
    })
    by_id = {row["external_id"]: row for row in rows}

    assert by_id["18"]["normalized"] == "hip hop rap"
    assert by_id["15"]["normalized"] == "r b soul"
    assert by_id["4"]["normalized"] == "children s music"
    # Not the naive fold, which would keep the punctuation and match nothing.
    assert by_id["18"]["normalized"] != "Hip-Hop/Rap".lower()


def test_the_payload_hash_matches_the_catalogue_encoding(genres):
    """The same encoding artists are hashed with, or every run re-stores.

    `external_entities` is unique on `(provider, external_id, payload_hash)`, so
    the hash is what makes an unchanged answer conflict rather than duplicate.
    `catalogue.py` hashes `json.dumps(payload, sort_keys=True,
    ensure_ascii=False)`; a second encoding here would hash the same answer two
    ways.
    """
    import hashlib

    row = genres.shaped({"51": {"name": "K-Pop", "parent_id": "14"}})[0]
    payload = {"name": "K-Pop", "normalized": "k pop", "parent_id": "14"}
    expected = hashlib.sha256(
        json.dumps(payload, sort_keys=True, ensure_ascii=False).encode("utf-8")
    ).hexdigest()

    assert row["payload_hash"] == expected
    assert row["parent_id"] == "14", "the parent is Apple's id, resolved by the mint"


def test_english_is_read_from_the_storefront_rather_than_guessed(genres, monkeypatch):
    """`en-US` in Japan, `en-GB` across Europe — and a storefront with neither.

    Asking in a language the storefront does not support returns its own, and
    `music_dictionary.py`'s tables hold English strings only. A storefront with
    no English tag is skipped rather than asked in a language nothing reads.
    """
    monkeypatch.setattr(genres, "_get", lambda token, path: {"data": [
        {"id": "jp", "attributes": {"supportedLanguageTags": ["ja", "en-US"]}},
        {"id": "gb", "attributes": {"supportedLanguageTags": ["en-GB"]}},
        {"id": "xx", "attributes": {"supportedLanguageTags": ["fr-FR"]}},
    ]})

    fronts = genres.english_storefronts("token")

    assert fronts == {"jp": "en-US", "gb": "en-GB"}
    assert "xx" not in fronts
