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
    if worker not in sys.path:
        sys.path.insert(0, worker)
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
