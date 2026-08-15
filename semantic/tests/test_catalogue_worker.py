"""The worker's catalogue fetch must shape rows the mint can actually store.

**Everything this covers fails silently.** A payload hashed differently from the
way `tools/apple_catalog.py` hashes it re-stores the same answer on every run and
`external_entities` grows without bound; a missing `normalized` makes the mint
skip the artist with no error, because the minting SQL filters on it; and an
unset developer token that raised like any other error would turn "nobody
configured this" into a dead job that reads as a defect.

**One fetch, not two.** `catalogue.py` imports `catalogue()` and `artists_in()`
from the tool rather than reimplementing them, and `build.sh` copies the tool
into the bundle beside the music dictionary for the same reason that one is
copied. The test that matters most here is that the import survives the *flat*
bundle layout, since the Lambda has no `tools/` directory.

Skipped when `WRITTEN_REPOSITORY_PATH` is unset, like the rest of the suite.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import pathlib
import sys

import pytest

REPOSITORY = os.environ.get("WRITTEN_REPOSITORY_PATH")

pytestmark = pytest.mark.skipif(
    not REPOSITORY, reason="WRITTEN_REPOSITORY_PATH is unset"
)


@pytest.fixture(scope="module")
def catalogue():
    """`aws/worker/catalogue.py`, loaded the way the bundle lays it out.

    `build.sh` flattens `aws/worker/*.py` and `tools/apple_catalog.py` into one
    directory, so both must be importable by bare module name.
    """
    worker = os.path.join(REPOSITORY, "aws", "worker")
    tools = os.path.join(REPOSITORY, "tools")
    path = os.path.join(worker, "catalogue.py")
    if not os.path.exists(path):
        pytest.skip("worker catalogue module not present")
    for directory in (worker, tools):
        if directory not in sys.path:
            sys.path.insert(0, directory)
    spec = importlib.util.spec_from_file_location("written_worker_catalogue", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def test_an_unset_token_is_its_own_refusal(catalogue, monkeypatch):
    """Distinguishable from an expired one, which must fail loudly.

    Unset means nobody configured the credential and retrying cannot help, so
    the handler returns `no_op`. An expired token raises from the fetch instead,
    because silently not enriching is the failure this work exists to remove.
    """
    monkeypatch.delenv("APPLE_MUSIC_DEVELOPER_TOKEN", raising=False)
    with pytest.raises(catalogue.CatalogueUnavailable):
        catalogue.developer_token()

    monkeypatch.setenv("APPLE_MUSIC_DEVELOPER_TOKEN", "   ")
    with pytest.raises(catalogue.CatalogueUnavailable):
        catalogue.developer_token()

    monkeypatch.setenv("APPLE_MUSIC_DEVELOPER_TOKEN", "eyJhbGciOi")
    assert catalogue.developer_token() == "eyJhbGciOi"


def test_the_payload_hash_matches_the_tools_encoding(catalogue):
    """Or the same answer stores twice and keeps storing.

    `external_entities` is unique on `(provider, external_id, payload_hash)`, so
    the digest *is* the identity of an answer. `tools/apple_catalog.py` encodes
    with `sort_keys=True, ensure_ascii=False`; anything else means the tool and
    the worker disagree about whether they have already asked.
    """
    payload = {"genreNames": ["J-Pop"], "composerName": "", "releaseDate": "2019-02-27"}
    _, digest = catalogue._hashed(dict(payload))
    expected = hashlib.sha256(
        json.dumps(payload, sort_keys=True, ensure_ascii=False).encode("utf-8")
    ).hexdigest()
    assert digest == expected


def test_fetch_shapes_rows_the_minting_sql_will_accept(catalogue, monkeypatch):
    """The mint filters on these exact keys, and drops anything missing them.

    `mint_vocabulary_from_catalogue` requires a non-empty `isrc` and
    `payload_hash` on a song, and a non-empty `external_id`, `payload_hash` and
    `normalized` on an artist. It strips `isrc`/`label`/`payload_hash` from the
    song and `external_id`/`payload_hash` from the artist to form `raw_payload`,
    so what is left has to be exactly what the resolver later reads.
    """
    monkeypatch.setattr(catalogue, "catalogue", lambda token, isrcs: (
        {"JPU901900060": {
            "genreNames": ["J-Pop", "Anime"],
            "composerName": "",
            "releaseDate": "2019-02-27",
        }},
        {"1234567": {"name": "P!nk", "genres": ["Pop"],
                     "isrcs": ["JPU901900060"]}},
    ))

    songs, artists, _ = catalogue.fetch(
        "token", {"JPU901900060": ["apple_music"]}
    )

    assert len(songs) == 1
    song = songs[0]
    assert song["isrc"] == "JPU901900060"
    assert song["label"] == "J-Pop, Anime"
    assert song["payload_hash"]
    assert song["genreNames"] == ["J-Pop", "Anime"]

    assert len(artists) == 1
    artist = artists[0]
    assert artist["external_id"] == "1234567"
    assert artist["payload_hash"]
    assert artist["name"] == "P!nk"
    # The fold the resolver uses, not `str.lower()` — `p!nk` would never match.
    assert artist["normalized"] == "p nk"
    # And the genres that give a minted creator its `broader` edge.
    assert artist["genres_normalized"] == ["pop"]


def test_the_isrc_query_asks_only_for_ones_never_answered(catalogue):
    """A cap that silently truncates reads as coverage, so it is reported.

    The statement filters to ISRCs with no `apple_music_catalog` song entity, so
    a second pass over the same library asks Apple nothing. `MAX_ISRCS_PER_JOB`
    bounds one job; `mint_for` returns whether the cap was hit so a run can say
    it left work behind rather than implying it finished.
    """
    statement = catalogue.SELECT_MISSING_ISRCS
    assert "array_agg(distinct o.source_code)" in statement
    assert "not exists" in statement
    assert "'apple_music_catalog'" in statement
    assert "entity_kind = 'song'" in statement
    assert "lifecycle_state = 'active'" in statement
    assert "limit %(limit)s" in statement
    assert catalogue.MAX_ISRCS_PER_JOB > 0


def test_no_isrcs_means_no_fetch_and_still_a_mint(catalogue, monkeypatch):
    """A user with nothing new must not need a credential at all.

    Arming has no coverage gate by decision, so most jobs will find nothing to
    look up. If that path demanded a token, every such job would decline instead
    of completing, and the absence of a credential would look like the absence of
    new artists.
    """
    monkeypatch.delenv("APPLE_MUSIC_DEVELOPER_TOKEN", raising=False)
    monkeypatch.setattr(catalogue, "missing_isrcs", lambda connection, users: {})

    calls: list = []

    class Cursor:
        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

        def execute(self, statement, params):
            calls.append(params)

        def fetchone(self):
            return {"receipt": {"minted": 0, "published": False}}

    class Connection:
        def cursor(self):
            return Cursor()

    receipt = catalogue.mint_for(Connection(), ["11111111-1111-1111-1111-111111111111"])

    assert receipt["isrcs_looked_up"] == 0
    assert receipt["isrcs_capped"] is False
    assert receipt["published"] is False
    assert json.loads(calls[0]["songs"]) == []
    assert json.loads(calls[0]["artists"]) == []


def test_the_bundle_copies_the_shared_fetch(catalogue):
    """`catalogue.py` imports `apple_catalog` by bare module name.

    The Lambda has no `tools/` directory, so if `build.sh` stops copying it the
    worker fails at import — after deploy, not at build. Pinned here because the
    symptom would be every mint job dying with a `handler_error` naming nothing.
    """
    build = pathlib.Path(REPOSITORY) / "aws" / "worker" / "build.sh"
    assert "tools/apple_catalog.py" in build.read_text(encoding="utf-8")


def test_an_identifier_seen_in_two_sources_records_both(catalogue, monkeypatch):
    """**The case a "first source wins" implementation gets wrong.**

    Measured across both accounts: only 10 of 817 artists are reachable from both
    Apple and Spotify. Those ten are exactly the entries that are Apple-clean
    *despite* Spotify also naming them, so collapsing them to one source would
    report them as belonging to whichever was read first — and the mistake stays
    invisible until the day the restriction is applied and the wrong entries are
    pruned.
    """
    monkeypatch.setattr(catalogue, "catalogue", lambda token, isrcs: (
        {"SHARED0000001": {"genreNames": ["Pop"], "composerName": "", "releaseDate": ""}},
        {},
    ))

    _, _, provenance = catalogue.fetch(
        "token", {"SHARED0000001": ["apple_music", "spotify"]}
    )

    songs = [row for row in provenance if row["entity_kind"] == "song"]
    assert {row["source_code"] for row in songs} == {"apple_music", "spotify"}
    assert all(row["external_id"] == "SHARED0000001" for row in songs)


def test_an_artist_inherits_every_source_that_named_it(catalogue, monkeypatch):
    """Provenance follows source → ISRC → song → artist, and unions at the end.

    A performer on one Apple track and one Spotify track is supplied by both.
    The artist step is the one that used to drop this entirely — `artists_in`
    was called per song and the mapping back to the recording was discarded.
    """
    monkeypatch.setattr(catalogue, "catalogue", lambda token, isrcs: (
        {
            "APPLE00000001": {"genreNames": ["Rock"], "composerName": "", "releaseDate": ""},
            "SPOT000000001": {"genreNames": ["Rock"], "composerName": "", "releaseDate": ""},
        },
        {"999": {"name": "Both Ways", "genres": ["Rock"],
                 "isrcs": ["APPLE00000001", "SPOT000000001"]}},
    ))

    _, _, provenance = catalogue.fetch("token", {
        "APPLE00000001": ["apple_music"],
        "SPOT000000001": ["spotify"],
    })

    artist_rows = [row for row in provenance if row["entity_kind"] == "artist"]
    assert {row["source_code"] for row in artist_rows} == {"apple_music", "spotify"}
    assert all(row["external_id"] == "999" for row in artist_rows)


def test_an_artist_named_only_by_one_source_records_only_that_one(catalogue, monkeypatch):
    """The negative, which is what makes the positive worth anything.

    If everything came back as "both", the record would be true and useless. A
    Spotify-only artist must be recorded as Spotify-only — 461 of 817 are.
    """
    monkeypatch.setattr(catalogue, "catalogue", lambda token, isrcs: (
        {"SPOT000000002": {"genreNames": [], "composerName": "", "releaseDate": ""}},
        {"777": {"name": "Spotify Only", "genres": [], "isrcs": ["SPOT000000002"]}},
    ))

    _, _, provenance = catalogue.fetch("token", {"SPOT000000002": ["spotify"]})

    artist_rows = [row for row in provenance if row["entity_kind"] == "artist"]
    assert [row["source_code"] for row in artist_rows] == ["spotify"]
