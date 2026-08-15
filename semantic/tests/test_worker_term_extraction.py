"""Turning a stored music projection into terms, and those terms into concepts.

**The same silent failure mode as the HealthKit and Calendar adapters**, one
layer further on: a wrong key reads as *absent*, and an observation that supports
no terms is indistinguishable from a person with no music. Nothing errors, the
run succeeds, and the mappings are simply missing.

So these assert the resolver's *output* — which concept a term lands on — rather
than the shape of the term. Two of them exist for properties that took a
migration to establish and would be silently lost if the extraction were wrong:
that a Traditional Chinese genre resolves at all, and that a label shared with a
non-genre concept stays a review candidate.

Skipped when `WRITTEN_REPOSITORY_PATH` is unset, like the rest of the
repository-integration suite.
"""

import importlib.util
import os
import sys

import pytest

from written_ontology.graph import OntologyGraph
from written_ontology.mapping import ObservationMapper
from written_ontology.models import Concept, InferencePolicyName, Observation

REPOSITORY = os.environ.get("WRITTEN_REPOSITORY_PATH")

pytestmark = pytest.mark.skipif(
    not REPOSITORY, reason="WRITTEN_REPOSITORY_PATH is unset"
)


@pytest.fixture(scope="module")
def resolve():
    worker = os.path.join(REPOSITORY, "aws", "worker")
    path = os.path.join(worker, "resolve.py")
    if not os.path.exists(path):
        pytest.skip("worker resolver not present")
    # **`tools/` too.** `build.sh` copies the music dictionary in beside the
    # handler so the bundle is flat, and `resolve` imports it by bare module
    # name; in the repository the two live in different directories, so the test
    # has to reproduce the bundle's layout rather than the checkout's.
    tools = os.path.join(REPOSITORY, "tools")
    for directory in (worker, tools):
        if directory not in sys.path:
            sys.path.insert(0, directory)
    spec = importlib.util.spec_from_file_location("written_worker_resolve", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


# A slice of the real seeded ontology: the two genres that matter for these
# tests, plus the activity that collides with one of them.
def build_graph() -> OntologyGraph:
    concepts = {
        "genre:classical": Concept(
            key="genre:classical", label="Classical", kind="genre",
            sensitivity="ordinary", inference_policy=InferencePolicyName.INFERABLE, status="active",
        ),
        "genre:dance": Concept(
            key="genre:dance", label="Dance", kind="genre",
            sensitivity="ordinary", inference_policy=InferencePolicyName.INFERABLE, status="active",
        ),
        "activity:dance": Concept(
            key="activity:dance", label="Dance", kind="activity",
            sensitivity="ordinary", inference_policy=InferencePolicyName.REVIEW_REQUIRED, status="active",
        ),
    }
    aliases = {
        "classical": [("genre:classical", 1.0, "preferred")],
        "古典樂": [("genre:classical", 1.0, "alternate")],
        "dance": [("genre:dance", 1.0, "preferred"), ("activity:dance", 1.0, "preferred")],
    }
    return OntologyGraph(concepts, (), aliases)


def observation_with(resolve, payload, action="library_song"):
    return Observation(
        id="obs-1",
        source="apple_music",
        data_type="song",
        action=action,
        evidence_channel="music",
        independence_group="music",
        occurred_at=None,
        collected_at=None,
        terms=resolve.terms_for(payload, action),
        record_fingerprint="f" * 64,
        content_lineage="f" * 64,
    )


SONG = {
    "title": "Partita No. 2 in D Minor",
    "primary_performer": "Hilary Hahn",
    "credited_artists": ["Hilary Hahn"],
    "composer": "Johann Sebastian Bach",
    "album": "Bach: Violin Partitas",
    "genres": ["Classical", "Violin"],
}


def test_a_song_supports_the_roles_the_package_uses(resolve):
    terms = resolve.terms_for(SONG, "library_song")
    by_role = {term.role: term for term in terms}

    assert by_role["work"].text == "Partita No. 2 in D Minor"
    assert by_role["work"].type_hint == "work"
    assert by_role["creator"].text == "Hilary Hahn"
    assert by_role["creator"].type_hint == "creator"
    # **The composer is a separate term from the performer.** The "artist" of a
    # Bach partita is whoever played it, so folding the two together would make
    # a classical library unreadable — which is the reason the field is carried
    # at all.
    assert by_role["composer"].text == "Johann Sebastian Bach"
    assert by_role["album"].text == "Bach: Violin Partitas"
    assert [t.text for t in terms if t.role == "genre"] == ["Classical", "Violin"]


def test_the_performer_is_not_repeated_from_credited_artists(resolve):
    # `primary_performer` is usually also the first credited artist. Two
    # identical creator terms would double that artist's evidence for no reason.
    terms = resolve.terms_for(SONG, "library_song")
    creators = [t.text for t in terms if t.role == "creator"]
    assert creators == ["Hilary Hahn"]


def test_an_artist_row_is_a_creator_not_a_work(resolve):
    terms = resolve.terms_for({"title": "Hilary Hahn"}, "library_artist")
    assert [(t.role, t.type_hint) for t in terms] == [("creator", "creator")]


def test_camel_case_keys_yield_nothing(resolve):
    """The negative control, and the failure this file exists to catch.

    `observations.normalize()` already renamed Swift's camelCase, so the stored
    projection is snake_case. Reading it the other way finds every field absent
    and produces an observation supporting no terms — which looks exactly like a
    person with no music.
    """
    assert resolve.terms_for({"primaryPerformer": "Hilary Hahn"}, "library_song") == ()


def test_a_traditional_chinese_genre_resolves(resolve):
    """The property `0066` exists for.

    Apple returns genre names in the storefront's locale, and this library
    carries both — `Classical` 1,126 times and `古典樂` 314. An English-only
    vocabulary would abstain on the Chinese rows while looking perfectly healthy.
    """
    mapper = ObservationMapper(build_graph())
    candidates = mapper.map_observation(
        observation_with(resolve, {"title": "x", "genres": ["古典樂"]})
    )
    resolved = {c.concept_key: str(c.state) for c in candidates}
    assert resolved.get("genre:classical") == "accepted"


def test_english_and_chinese_reach_the_same_concept(resolve):
    """Two spellings, one concept — otherwise the two halves of this library
    would count as two different tastes."""
    mapper = ObservationMapper(build_graph())
    for spelling in ("Classical", "古典樂"):
        candidates = mapper.map_observation(
            observation_with(resolve, {"title": "x", "genres": [spelling]})
        )
        assert any(c.concept_key == "genre:classical" for c in candidates)


def test_a_colliding_label_stays_a_candidate(resolve):
    """`dance` is genuinely both a genre and a HealthKit workout type.

    `resolve_alias` computes the collision *before* type compatibility, so both
    degrade to `candidate` rather than `accepted`. That is the schema being
    right about an ambiguous word, and this test exists so nobody "fixes" it
    into an auto-accept later.
    """
    mapper = ObservationMapper(build_graph())
    candidates = mapper.map_observation(
        observation_with(resolve, {"title": "x", "genres": ["Dance"]})
    )
    states = {c.concept_key: str(c.state) for c in candidates}
    assert states.get("genre:dance") == "candidate"
    assert "accepted" not in states.values()


def test_creator_terms_are_built_even_though_nothing_resolves_them(resolve):
    """The ontology holds genres and no creators, so these map to nothing today.

    They are still emitted, because `EmergentTermMiner` needs five distinct users
    before it will surface a term for curator review and cannot count terms that
    were never built. This is the ontology's growth path, and it would be lost
    silently by an extractor that only emitted what currently resolves.
    """
    mapper = ObservationMapper(build_graph())
    observation = observation_with(resolve, SONG)
    assert any(term.role == "creator" for term in observation.terms)
    mapped = {c.concept_key for c in mapper.map_observation(observation)}
    assert not any(key.startswith("creator:") for key in mapped)


def test_no_term_may_leave_the_device_boundary(resolve):
    """`sources.online_resolution_policy` is `disabled_private` for music.

    Both flags live on the term, so a future external resolver cannot opt a term
    in by forgetting to check a policy somewhere upstream.
    """
    for term in resolve.terms_for(SONG, "library_song"):
        assert term.safe_for_online is False
        assert term.safe_for_global_mining is False


# --- the dictionary, applied ------------------------------------------------
#
# `terms_for` reads a stored projection; the dictionary decides what the strings
# in it *mean*. These assert the two together, because each is fine alone and
# the join is where a library quietly resolves to nothing.

def test_a_compound_credit_becomes_several_people(resolve):
    """`Berlin Philharmonic & Claudio Abbado` is two artists. Judging the whole
    string files it under neither, and half this library's credits are
    compound."""
    terms = resolve.terms_for(
        {"title": "x", "primary_performer": "Berlin Philharmonic & Claudio Abbado"},
        "library_song")
    assert [t.text for t in terms if t.role == "creator"] \
        == ["Berlin Philharmonic", "Claudio Abbado"]


def test_a_transliterated_name_returns_to_its_own_language(resolve):
    """`尚・西貝流士` is a Chinese rendering of a Finnish name, and `Jean Sibelius`
    is also in this library — without this they are two composers."""
    terms = resolve.terms_for(
        {"title": "x", "primary_performer": "尚・西貝流士"}, "library_song")
    assert [t.text for t in terms if t.role == "creator"] == ["Jean Sibelius"]


def test_a_native_name_is_left_alone(resolve):
    """`久石讓` is Joe Hisaishi's name. Japanese *is* its language."""
    terms = resolve.terms_for(
        {"title": "x", "primary_performer": "久石讓"}, "library_song")
    assert [t.text for t in terms if t.role == "creator"] == ["久石讓"]


def test_an_editorial_account_is_not_an_artist(resolve):
    """`Apple Music 古典樂` credits a curated playlist, not a person."""
    terms = resolve.terms_for(
        {"title": "x", "primary_performer": "Apple Music 古典樂"}, "library_song")
    assert [t for t in terms if t.role == "creator"] == []


def test_genres_arrive_in_english_whatever_they_were_written_in(resolve):
    """The single most load-bearing translation: this library carries `Classical`
    1,126 times and `古典樂` 314, and they must be one concept."""
    terms = resolve.terms_for(
        {"title": "x", "genres": ["古典樂", "Classical", "巴洛克音樂"]}, "library_song")
    assert [t.text for t in terms if t.role == "genre"] == ["Classical", "Baroque Era"]


def test_a_work_carries_its_franchise(resolve):
    """Named once, both available — somebody with an Ave Mujica song is evidence
    for BanG Dream! too."""
    terms = resolve.terms_for(
        {"title": "KiLLKiSS", "genres": ["Anime"]}, "library_song",
        work="BanG Dream! Ave Mujica")
    assert [t.text for t in terms if t.role == "source_work"] \
        == ["BanG Dream! Ave Mujica", "BanG Dream!"]


def test_an_era_arrives_computed_rather_than_read_off_the_row(resolve):
    """A row cannot decide its era. Every Hikaru Utada row is dated 2024 by the
    tour album it came from, so a per-row decade would say 2020s — which is why
    `library_facts` computes it per artist and passes it in."""
    terms = resolve.terms_for(
        {"title": "First Love", "genres": ["J-Pop"]}, "library_song",
        eras=("era:1990s", "era:2000s"))
    assert sorted(t.text for t in terms if t.role == "era") == ["1990s", "2000s"]


def test_a_catalogue_game_is_a_work_and_everyone_else_stays_a_creator(resolve):
    """`Where Winds Meet` is a video game credited as an artist.

    Apple lists a game soundtrack under an "artist" named after the game, so it
    arrives in a music payload exactly as a person does. `0180` routes the
    *concept* to `work:apple_…`, but a term typed `creator` cannot map onto a
    work — the game scored 0.055 against a 0.25 bar, present and invisible.

    Both directions, over the same call: the game becomes a `source_work`, and
    the composer credited beside it on the very same soundtrack stays a creator.
    """
    from written_ontology.normalize import normalize_text
    payload = {
        "title": "Where Winds Meet_Login Screen_Yida",
        "primary_performer": "Where Winds Meet",
        "credited_artists": ["Where Winds Meet", "Yida"],
    }
    games = frozenset({normalize_text("Where Winds Meet")})
    roles = {
        (term.text, term.role, term.type_hint)
        for term in resolve.terms_for(payload, "library_song", games=games)
    }
    assert ("Where Winds Meet", "source_work", "work") in roles
    assert ("Where Winds Meet", "creator", "creator") not in roles
    assert ("Yida", "creator", "creator") in roles

    # With no catalogue answer nothing is reclassified — the flag is the only
    # thing that moves a credit, never the name.
    plain = {
        (term.text, term.role) for term in resolve.terms_for(payload, "library_song")
    }
    assert ("Where Winds Meet", "creator") in plain
