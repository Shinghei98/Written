"""A genre the source did not state, filled in from Apple's catalogue.

**The measurement this is written against.** 2026-08-14, a 593-row Spotify
library: 1,522 terms extracted, 6 accepted mappings, 0 eligible assertions.
Apple Music stamps a genre on every song row and Spotify stamps one on none,
because Spotify's API states no genre at track level at all — and a genre is
the root of everything a person can see. `artist_spheres` reads nothing else,
`artist_scenes` needs a sphere, and `takes_decades` gates the era.

Every Spotify track carries an ISRC (500 of 500, measured), which is the one
identifier Apple's catalogue shares, so the catalogue can answer for rows
Spotify left bare. `tools/apple_catalog.py` fetches the answers into
`ontology.external_entities`; `with_catalogue_genres` is the read-time join.

What is pinned here is the *shape* of that join rather than any arithmetic: who
gets filled, who does not, and that nothing the vault holds is altered on the
way through.
"""

from __future__ import annotations

import importlib.util
import os
import sys

import pytest

REPOSITORY = os.environ.get("WRITTEN_REPOSITORY_PATH")

pytestmark = pytest.mark.skipif(
    not REPOSITORY, reason="WRITTEN_REPOSITORY_PATH is unset"
)


@pytest.fixture(scope="module")
def resolve():
    """`aws/worker/resolve.py` is a Lambda module, not an installed package."""
    worker = os.path.join(REPOSITORY, "aws", "worker")
    path = os.path.join(worker, "resolve.py")
    if not os.path.exists(path):
        pytest.skip("worker not present")
    for extra in (worker, os.path.join(REPOSITORY, "tools")):
        if extra not in sys.path:
            sys.path.insert(0, extra)
    spec = importlib.util.spec_from_file_location("written_worker_resolve", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def row(**payload):
    return {"source_code": "spotify", "normalized_payload": dict(payload)}


def test_a_bare_row_with_an_isrc_is_filled(resolve):
    """The case the whole exercise exists for: a Spotify top track."""
    rows = [row(title="小小蟲", primary_performer="Khalil Fong",
                album="橙月", isrc="HKI490867403", release_date="2010-05-18")]
    filled = resolve.with_catalogue_genres(rows, {"HKI490867403": ["Mandopop"]})
    assert filled == 1
    assert rows[0]["normalized_payload"]["genres"] == ["Mandopop"]
    # Everything else survives untouched — the join adds, it does not rewrite.
    assert rows[0]["normalized_payload"]["release_date"] == "2010-05-18"


def test_a_stated_genre_is_never_overwritten(resolve):
    """**The source outranks the catalogue, always.**

    An Apple Music row states its own genre, and that is what the person's
    library actually says. A catalogue that could overwrite it would be this
    system deciding it knows better than the source it read — and would do it
    silently, on rows that were already resolving correctly.
    """
    rows = [row(title="again - EP", genres=["J-Pop"], isrc="JPB600901234")]
    assert resolve.with_catalogue_genres(rows, {"JPB600901234": ["Rock"]}) == 0
    assert rows[0]["normalized_payload"]["genres"] == ["J-Pop"]


def test_an_empty_genre_list_counts_as_unstated(resolve):
    """`lib.mjs` deletes empty arrays before projecting, so an empty list should
    not arrive — but if one does it means the same thing as a missing key, and
    treating the two differently is how a row silently misses a fill."""
    rows = [row(title="Anything", genres=[], isrc="USUM71805757")]
    assert resolve.with_catalogue_genres(rows, {"USUM71805757": ["K-Pop"]}) == 1
    assert rows[0]["normalized_payload"]["genres"] == ["K-Pop"]


def test_a_row_with_no_isrc_is_left_alone(resolve):
    """Artist rows carry no ISRC — 0 of 80, measured — and there is nothing to
    join them on. They are not a failure, they are simply not this lane's."""
    rows = [row(title="Aimer", primary_performer="Aimer")]
    assert resolve.with_catalogue_genres(rows, {"HKI490867403": ["Mandopop"]}) == 0
    assert "genres" not in rows[0]["normalized_payload"]


def test_an_isrc_the_catalogue_never_answered_for_is_left_alone(resolve):
    """Apple does not hold every ISRC. A miss must leave the row exactly as it
    was rather than stamping an empty genre, which would then read downstream as
    *"this song has no genre"* — a claim nobody made."""
    rows = [row(title="Obscure", isrc="ZZZ000000000")]
    assert resolve.with_catalogue_genres(rows, {}) == 0
    assert "genres" not in rows[0]["normalized_payload"]


def test_the_source_is_not_named(resolve):
    """**The condition is the gap, not a list of who has it.**

    A row that states no genre and names an ISRC is filled whatever source it
    came from. Naming `spotify` here would be a deny-list, and the failure mode
    of a deny-list is silence — a later source with the same gap would get
    nothing, with nothing reporting the difference.
    """
    rows = [{"source_code": "some_future_source",
             "normalized_payload": {"title": "x", "isrc": "HKI490867403"}}]
    assert resolve.with_catalogue_genres(rows, {"HKI490867403": ["Mandopop"]}) == 1


def test_the_loaded_payload_is_not_mutated(resolve):
    """**The vault's copy is never touched**, and this is the assertion that
    keeps it that way. `guard_observation_immutable` freezes
    `normalized_payload`, and the catalogue is not the person's evidence: this
    join lives exactly as long as the run.
    """
    original = {"title": "小小蟲", "isrc": "HKI490867403"}
    rows = [{"source_code": "spotify", "normalized_payload": original}]
    resolve.with_catalogue_genres(rows, {"HKI490867403": ["Mandopop"]})
    assert original == {"title": "小小蟲", "isrc": "HKI490867403"}
    assert rows[0]["normalized_payload"] is not original


def test_a_malformed_row_does_not_raise(resolve):
    """A payload that is not a dict, or an ISRC that is not a string, is data
    this function did not expect — and a resolver that raises on one strange row
    fails a whole run for one person's odd record."""
    rows = [
        {"source_code": "spotify", "normalized_payload": None},
        {"source_code": "spotify", "normalized_payload": {"isrc": 12345}},
        {"source_code": "spotify"},
    ]
    assert resolve.with_catalogue_genres(rows, {"HKI490867403": ["Mandopop"]}) == 0


def test_genres_reach_a_sphere_and_a_scene_once_filled(resolve):
    """**The end of the chain, and the reason the fill happens before
    `library_facts`.**

    A genre merged after the facts are computed would reach `genre:*` and
    neither `sphere:*` nor `scene:*` — which is everything a person actually
    sees. This runs the real `library_facts` over a filled row and asserts all
    three arrive, so the ordering cannot be quietly rearranged later.
    """
    rows = [
        row(title="小小蟲", primary_performer="Khalil Fong",
            album="橙月", isrc="HKI490867403", release_date="2010-05-18"),
        row(title="橙月", primary_performer="Khalil Fong",
            album="橙月", isrc="HKI490867404", release_date="2010-05-18"),
    ]
    bare = resolve.library_facts(rows)
    assert bare.spheres.get("Khalil Fong", ()) == ()
    assert bare.scenes.get("Khalil Fong", ()) == ()

    resolve.with_catalogue_genres(rows, {
        "HKI490867403": ["Mandopop"], "HKI490867404": ["Mandopop"],
    })
    facts = resolve.library_facts(rows)
    assert "sphere:mandarin" in facts.spheres.get("Khalil Fong", ())
    assert facts.scenes.get("Khalil Fong", ()) != ()
    assert facts.eras.get("Khalil Fong", ()) != ()
