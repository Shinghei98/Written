"""Turning stored observations into concept mappings.

**This is the first thing that connects a person's data to the ontology.** Up to
now the pipeline captured, classified and promoted; nothing ever said *this row
is about that concept*.

**It never touches the vault**, which is the property worth protecting.
Everything it needs is already in `observations.normalized_payload` — the
sanitised music projection carrying title, performer, credited artists, composer,
album and genres. So resolution runs on evidence rather than on plaintext, and
the worker's `Decrypt` stays reserved for classifiers that genuinely need raw
rows.

**Music and YouTube, and Calendar and HealthKit remain refused by three separate
mechanisms.** `ObservationMapper._source_projection_is_valid` refuses Calendar
outright and demands an exact fitness-candidate shape for HealthKit;
`guard_calendar_observation_mapping` says the same thing again in the database;
and §7 permits only the current Calendar classifier over Calendar rows. Nothing
here bypasses any of them.

**YouTube is the second independence group, which is why it is here at all.**
`apple_music`, `music_library` and `spotify` all carry the group `music` by
design — three streaming services agreeing that somebody played a song is one
witness — so no music source can ever be the second, and `motif_rules` requires
two as a check constraint. Its two mapping kinds are gated differently:
`provider_topic` needs no approval and `uploader_tag` is licensed by `0078`,
read off the *run's* policy row rather than the approval.

**Unresolved terms are emitted anyway, and that is the point of emitting them.**
Artists, works and composers resolve to nothing today, because the ontology holds
genres and no creators. They are still built, because they are the input to
`EmergentTermMiner` — which needs five distinct users before it will surface
anything for curator review, and cannot start counting terms that were never
made. Dropping them would be dropping the ontology's growth path.
"""

from __future__ import annotations

import json
import re
from dataclasses import replace
from typing import Any, NamedTuple

from written_ontology.mapping import ObservationMapper
from written_ontology.models import (
    Concept,
    ConceptEdge,
    InferencePolicyName,
    Observation,
    Term,
)
from written_ontology.normalize import normalize_text
from written_ontology.graph import OntologyGraph

from score import score_user
from music_dictionary import CLASSICAL_ERAS
from music_works import (
    classical_composer,
    classical_work,
    artist_eras,
    artist_scenes,
    artist_spheres,
    composers_in,
    english_genre,
    normalized_song_key,
    people_in,
    propagate,
    work_parents,
)
from written_ontology.recency import (
    DEFAULT_RECENCY_POLICY,
    RecencyPolicyError,
)

# The `recency` domain each source belongs to, which is the policy's own
# vocabulary rather than ours.
#
# **Per source, and it was a constant.** `DEFAULT_RECENCY_POLICY` registers
# YouTube's curves under `video` — `register("video", ("youtube",),
# ("subscription",), ENDURING_FOLLOW)` — while a hardcoded `"music"` would find
# no rule for a YouTube row, raise `RecencyPolicyError`, and drop every one of
# them as `unweighted_action`. Counted rather than silent, but the count would
# have read as "YouTube supports no terms" rather than "asked the wrong
# question".
RECENCY_DOMAIN_BY_SOURCE = {
    "apple_music": "music",
    "music_library": "music",
    "spotify": "music",
    "youtube": "video",
}


def recency_domain(source_code: str) -> str:
    """The policy domain for a source, refusing to guess for an unknown one.

    A default of `"music"` here would put the next source's rows on music's
    decay curve silently, which is worse than a source that resolves nothing:
    a wrong weight is indistinguishable from a right one downstream.
    """
    domain = RECENCY_DOMAIN_BY_SOURCE.get(source_code)
    if domain is None:
        raise RecencyPolicyError(f"no recency domain for source {source_code!r}")
    return domain

MUSIC_SOURCES = ("apple_music", "music_library", "spotify")
YOUTUBE_SOURCE = "youtube"

# **Read from `0078`'s resolver model rather than chosen here.** Its parameters
# record `min_tag_length`, `whole_tag_only` and `substring_matching: false`, and
# the reason the bound exists is measured: `creator:yg` matched in the corpus,
# YG Entertainment is a label rather than an artist, and a two-character tag
# matches noise in any library. Duplicated as a constant only so a failure to
# load the model is not a silently permissive default.
MIN_TAG_LENGTH = 3

# **Games an uploader's own channel keywords may name, and nothing else.**
#
# The one rule governing what may be added here, borrowed whole from
# `aws/ingestion/work_titles.mjs` because it is the same hazard one layer down:
# **an alias must not be a word.** `wow` is an exclamation before it is
# Warcraft, and a term in the wrong place is a false claim about a person — so
# `World of Warcraft` is listed under names nobody types by accident and is
# simply unreachable from the abbreviation everybody uses. Losing a true term is
# the cheaper mistake.
#
# **Why a list here rather than the ontology's own aliases.** Measured
# 2026-08-14: 50 active `work` aliases, three of them ordinary English words —
# `bleach`, `wicked`, `overlord` — each minted from a music library and each
# defined *"Read from a music library; never inferred from a title."* Matching
# free text against the whole `work` vocabulary would hand a Broadway cast
# recording to anyone whose channel tags `wicked`, and those aliases cannot be
# withdrawn because they are how the music lane reaches those works correctly.
# A per-lane vocabulary is the house pattern for exactly this: `provider_topic`
# resolves against `tools/youtube_topics.py`, `title_work` against the bundled
# catalogue in the ingestion Lambda.
#
# **Every value must already exist in `ontology.concepts` as a `work`, with its
# own key as an `alternate` label** — `0149`'s arrangement, which is what lets
# the ordinary exact-alias path resolve a key with no new resolution code. A key
# that does not exist is not an error here: it resolves to nothing, silently,
# which is why `0168` asserts the three from the other end.
GAME_TAG_CATALOGUE = {
    "hearthstone": "work:hearthstone",
    "world of warcraft": "work:world_of_warcraft",
    "warcraft": "work:world_of_warcraft",
    "final fantasy xiv": "work:final_fantasy_xiv",
    "ffxiv": "work:final_fantasy_xiv",
    "ff14": "work:final_fantasy_xiv",
}

# How a channel title is split for `written_title_tag`. Whitespace and the
# punctuation that separates words in a channel name — never inside a word, so
# `ritvikmath` stays one token and is aliased whole rather than being cut into
# something that matches by accident.
_TITLE_TOKEN = re.compile(r"[\s/|,:;()\[\]{}\u2013\u2014-]+")

# Every source this resolver reads. YouTube joins music rather than
# replacing it: independence is per source, and a concept reaching both
# groups is the only thing that can ever satisfy a motif rule.
RESOLVED_SOURCES = MUSIC_SOURCES + (YOUTUBE_SOURCE,)

# One batch per invocation. Kept well above the ~1,300 currently-present music
# observations so a run is one pass, and bounded so a large library cannot make a
# Lambda time out silently.
MAX_OBSERVATIONS = 5000


# ---------------------------------------------------------------------------
# The ontology, as the mapper wants it


SELECT_CONCEPTS = """
select c.concept_key, r.preferred_label, r.concept_kind, r.sensitivity,
       r.inference_policy, r.status, r.definition, c.id
  from ontology.concept_revisions r
  join ontology.concepts c on c.id = r.concept_id
 where r.ontology_version_id = %(version)s
"""

SELECT_LABELS = """
select c.concept_key, l.normalized_label, l.confidence, l.label_type
  from ontology.concept_labels l
  join ontology.concepts c on c.id = l.concept_id
 where l.ontology_version_id = %(version)s and l.status = 'active'
"""

SELECT_EDGES = """
select subject.concept_key as subject_key, e.predicate_key,
       object.concept_key as object_key, e.confidence, e.provenance_type, e.status
  from ontology.concept_edges e
  join ontology.concepts subject on subject.id = e.subject_concept_id
  join ontology.concepts object on object.id = e.object_concept_id
 where e.ontology_version_id = %(version)s
"""


PUBLISHED_VERSION = """
select id from ontology.versions where status = 'published'
"""


def published_version(connection) -> str:
    """The ontology a run must be opened against.

    **Not the version in the job payload, and the schema is why.**
    `guard_semantic_run_contract` refuses any run whose
    `ontology_version_id` is not currently `published` — so a job queued before a
    version change can never open a run against the version it was queued with.
    That is coherent rather than awkward: `one_published_ontology_version` allows
    exactly one at a time, `recompute_user` exists precisely so outputs can be
    rebuilt when something moves, and a mapping is only meaningful against the
    ontology in force.

    This corrected a comment that said the opposite. Reproducibility comes from
    the *run* recording which version it used, not from a queued job pinning one
    that has since been retired.
    """
    with connection.cursor() as cursor:
        cursor.execute(PUBLISHED_VERSION)
        row = cursor.fetchone()
    if row is None:
        raise RuntimeError("no published ontology version")
    return str(row["id"])


def load_graph(connection, ontology_version_id: str) -> tuple[OntologyGraph, dict[str, str]]:
    """The ontology at one version, plus a `concept_key -> id` map for writing."""
    concepts: dict[str, Concept] = {}
    concept_ids: dict[str, str] = {}
    with connection.cursor() as cursor:
        cursor.execute(SELECT_CONCEPTS, {"version": ontology_version_id})
        for row in cursor.fetchall():
            concepts[row["concept_key"]] = Concept(
                key=row["concept_key"],
                label=row["preferred_label"],
                kind=row["concept_kind"],
                sensitivity=row["sensitivity"],
                # **The enum, not the string the database returns.**
                # `InferenceSafetyPolicy.concept_is_inferable` reads
                # `.value` off it, so a raw `str` raises `AttributeError`
                # from inside the safety check — the one place a failure is
                # least welcome, since it guards what may be inferred at all.
                inference_policy=InferencePolicyName(row["inference_policy"]),
                status=row["status"],
                definition=row["definition"],
            )
            concept_ids[row["concept_key"]] = str(row["id"])

    aliases: dict[str, list[tuple[str, float, str]]] = {}
    with connection.cursor() as cursor:
        cursor.execute(SELECT_LABELS, {"version": ontology_version_id})
        for row in cursor.fetchall():
            aliases.setdefault(row["normalized_label"], []).append(
                (row["concept_key"], float(row["confidence"]), row["label_type"])
            )

    edges: list[ConceptEdge] = []
    with connection.cursor() as cursor:
        cursor.execute(SELECT_EDGES, {"version": ontology_version_id})
        for row in cursor.fetchall():
            edges.append(ConceptEdge(
                subject_key=row["subject_key"],
                predicate_key=row["predicate_key"],
                object_key=row["object_key"],
                confidence=float(row["confidence"]),
                provenance_type=row["provenance_type"],
                status=row["status"],
            ))

    return OntologyGraph(concepts, tuple(edges), aliases), concept_ids


# ---------------------------------------------------------------------------
# Terms


def _text(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def _is_classical(payload: dict[str, Any]) -> bool:
    """Whether this row is classical repertoire, by Apple's own genre.

    **Genre, never the title.** A catalogue number in a title is good evidence
    and a crossover album would still be mislabelled by it; Apple's genre is a
    stated fact and this whole file's rule is that a stated label beats a
    derived one. `CLASSICAL_ERAS` is reused rather than a second list, so
    `Baroque`, `Renaissance` and `Romantic` count without being named twice —
    the same reason `english_genre` exists.
    """
    genres = payload.get("genres")
    if not isinstance(genres, list) or not genres:
        # **Nothing stated, so the title is allowed to speak — and only then.**
        # The rule above is that a stated label beats a derived one, which is
        # right when there is a stated label. Apple returns *no* genre on some
        # rows: 68 of the 276 in one St Matthew Passion recording, same album as
        # the rest, `genres: null`. Those rows escaped the classical rule
        # entirely and carried their performers at full weight, which is how
        # Pichon and Pygmalion survived a change that removed every comparable
        # ensemble.
        #
        # A catalogue number is the narrowest fallback available: `BWV 244` is
        # an identifier, not a guess, and `classical_work` already parses it.
        # A crossover album with a genre stated is still judged on the genre,
        # because this branch is only reached when there is none.
        return classical_work(_text(payload.get("title"))) is not None
    for genre in genres:
        text = english_genre(_text(genre))
        if not text:
            continue
        lowered = text.lower()
        if "classical" in lowered or "opera" in lowered:
            return True
        if text in CLASSICAL_ERAS:
            return True
    return False


# **How many albums a classical performer must appear on to be a preference.**
#
# A flat weight was tried first and could not work. `strength` saturates as
# `w/(w+6)`, and that curve is almost flat where these concepts sit, so cutting
# the input by 70% moved Pichon from 0.92 to 0.85 — still above Mozart at 0.73.
# The problem was never the size of the number; it was that row count is the
# wrong question.
#
# Measured: Pichon and Pygmalion have the most rows in the library (276) and one
# album — the St Matthew Passion counted once per movement. Perlman has 47 rows
# across six albums, Hadelich 97 across three, the Berlin Philharmonic 100
# across thirteen. One album means the performer came with a recording; several
# means they were chosen more than once, which is a choice.
#
# **The criterion is breadth in this library, not fame.** A legendary soloist
# with one album here gets one album's worth of consideration, which as a claim
# about taste is none — and that avoids needing an external "is this person
# famous" oracle, the same trap the YouTube channel-role work refused.
CLASSICAL_PERFORMER_MIN_ALBUMS = 2

# What a performer below that threshold is worth. Not zero: the term still has
# to exist for term mining. Low enough that the largest such credit in a real
# library — 276 rows of one recording — lands at 0.19 against the 0.35 an
# assertion needs.
INCIDENTAL_PERFORMER_WEIGHT = 0.02


def _term(text: str, role: str, source_field: str, type_hint: str | None,
          weight: float = 1.0) -> Term:
    return Term(
        evidence_weight=weight,
        text=text,
        normalized=normalize_text(text),
        role=role,
        source_field=source_field,
        type_hint=type_hint,
        # **Both false, for every music term.** These gate whether a term may be
        # sent to an external resolver or pooled into global mining, and neither
        # is permitted without the online-resolution policy that
        # `sources.online_resolution_policy` currently sets to
        # `disabled_private`. A term that may not leave the device boundary must
        # say so on the term, not in a comment somewhere upstream.
        safe_for_online=False,
        safe_for_global_mining=False,
    )


def terms_for(payload: dict[str, Any], action: str,
              work: str | None = None, eras: tuple[str, ...] = (),
              breadth: dict[str, int] | None = None,
              spheres: tuple[str, ...] = (),
              scenes: tuple[str, ...] = ()) -> tuple[Term, ...]:
    """The terms one music observation supports.

    Roles and type hints mirror `export_adapter._music_observation`, which is the
    package's own reading of a music row. That function is private and coupled to
    the legacy CSV shape, so the vocabulary is copied and the code is not —
    duplicating it would have meant maintaining two parsers of the same thing.

    **The keys are the sanitised projection's, which are snake_case.** Unlike the
    envelope payloads, `normalize()` in `observations.py` already renamed Swift's
    camelCase — `primary_performer`, not `primaryPerformer`. Getting that
    backwards reads every field as absent, which surfaces as a library that
    supports no terms rather than as a bug.
    """
    terms: list[Term] = []
    breadth = breadth or {}

    title = _text(payload.get("title"))
    album_text = _text(payload.get("album"))
    # An artist row's `title` *is* the artist. Anything else is a work.
    title_is_creator = action in {"library_artist", "followed_artist"}

    # **Classical is the one repertoire where the title names a movement rather
    # than a piece.** `Matthäus-Passion, BWV 244, Seconda parte: Nr.38 …` is one
    # of 68 rows for one work, so taking the title whole makes 68 works nobody
    # listened to and loses the one they did. Cut at the catalogue number, which
    # ends a work's name by convention. A row with no catalogue number is left
    # exactly as it was — `classical_work` abstains rather than guessing a
    # boundary, which is how a work concept once collected 139 unrelated albums.
    classical = _is_classical(payload)
    if title and not title_is_creator and classical:
        work_title = classical_work(title)
        if work_title:
            terms.append(_term(work_title, "work", "title", "work"))
            title = ""

    if title:
        terms.append(_term(
            title,
            "creator" if title_is_creator else "work",
            "title",
            "creator" if title_is_creator else "work",
        ))

    # **Split before judging, and judge each part.** `Berlin Philharmonic &
    # Claudio Abbado` is two people; judging the whole string files it under
    # neither. `people_in` also drops Apple's editorial accounts and puts each
    # name in its own language — `尚・西貝流士` is Jean Sibelius, `久石讓` is not
    # translated because Japanese *is* his language.
    seen_creators = {normalize_text(title)} if title_is_creator else set()
    credits = [_text(payload.get("primary_performer"))]
    credited = payload.get("credited_artists")
    if isinstance(credited, list):
        credits.extend(_text(item) for item in credited)
    for credit in credits:
        for performer in people_in(credit):
            if normalize_text(performer) in seen_creators:
                continue
            seen_creators.add(normalize_text(performer))
            # **A one-album classical performer is emitted and weighed at
            # almost nothing, rather than dropped.**
            #
            # Dropping it was the first attempt and three tests caught what it
            # cost: this file's own docstring says unresolved terms are built
            # *deliberately*, because they are `EmergentTermMiner`'s input and
            # "dropping them would be dropping the ontology's growth path". A
            # `continue` here silently removed that for every classical
            # performer in the library.
            #
            # The weight is chosen against the eligibility bar rather than
            # picked. Pichon carries ~69 units of evidence across 276 rows of
            # one recording; at 0.02 that is 1.4, which saturates to 0.19 —
            # under the 0.35 an assertion needs. At 0.05 it is 0.365 and still
            # clears it, which is why 0.3 did nothing.
            incidental = (classical
                          and breadth.get(normalize_text(performer), 0)
                              < CLASSICAL_PERFORMER_MIN_ALBUMS)
            terms.append(_term(
                performer, "creator", "primary_performer", "creator",
                weight=INCIDENTAL_PERFORMER_WEIGHT if incidental else 1.0))

    composer = _text(payload.get("composer"))
    # **Apple states a composer on 8% of a classical library and a performer on
    # 100% of it**, so the repertoire resolved entirely to whoever played it:
    # 1,014 classical rows produced 138 observations for one ensemble and two
    # for Bach. The composer is in the data — classical albums are labelled
    # `Composer: Work` by convention, and a catalogue number names the composer
    # outright — it was simply never read. Recovered on 788 of those 1,014.
    #
    # Only where Apple said nothing, and only for classical: preferring a
    # composer everywhere would tell a pop listener they are into Max Martin,
    # which is the asymmetry `0038` already established for the icebreaker and
    # this is the same rule one layer down.
    if not composer and classical:
        composer = classical_composer(title or _text(payload.get("title")),
                                      album_text, "") or ""
    if composer:
        # **Kept apart from the performer, which is the whole reason this field
        # is carried.** The "artist" of a Bach partita is whoever played it, and
        # a library that is 1,440 classical rows is unreadable without the
        # distinction. Split too: `Dean Pitchford & Tom Snow` wrote it together
        # — but capped, because a pop track credits seventeen writers and only
        # the first few are who the song is by.
        for person in composers_in(composer):
            terms.append(_term(person, "composer", "composer", "creator"))

    album = _text(payload.get("album"))
    if album and normalize_text(album) != normalize_text(title):
        terms.append(_term(album, "album", "album", "work"))

    # **Always English.** `古典樂` and `Classical` are one genre; leaving them as
    # written would make a Chinese-labelled library resolve to different concepts
    # than an English-labelled one, and this library carries both.
    genres = payload.get("genres")
    if isinstance(genres, list):
        seen_genres: set[str] = set()
        for genre in genres:
            text = english_genre(_text(genre))
            if text and text not in seen_genres:
                seen_genres.add(text)
                terms.append(_term(text, "genre", "genres", "genre"))

    # The work a song was written for, and the franchise above it. Stated by
    # Apple or recognised by a person — never guessed from a title.
    # **`source_work`, not `work`** — a song title already uses that role, and a
    # reviewer seeing two `work` terms on one row could not tell the song from
    # the anime it was written for.
    if work:
        for name in [work, *work_parents(work)]:
            terms.append(_term(name, "source_work", "work", "work"))

    # **An era is an artist-level fact and arrives computed.** A row cannot
    # decide it alone: every Hikaru Utada row says 2024 because they came from a
    # 2024 tour album, and a per-row decade would file her under the 2020s.
    for era in eras:
        terms.append(_term(era.removeprefix("era:"), "era", "era", "topic"))

    # **The sphere, and the decade crossed with it.** An era alone spans worlds
    # that have nothing to do with each other — one real `era:1970s` rested on
    # ABBA, Frankie Kao and Fritz Kreisler at once — so the composite is what
    # carries a taste and the bare decade is kept only as its axis. Both are
    # artist-level for the same reason the era is: a row cannot decide either.
    for sphere in spheres:
        terms.append(_term(sphere.removeprefix("sphere:"), "sphere", "sphere", "topic"))
    for scene in scenes:
        terms.append(_term(scene.removeprefix("scene:"), "scene", "scene", "topic"))

    return tuple(terms)


class LibraryFacts(NamedTuple):
    """What `library_facts` computes, named rather than positional.

    It returned a bare 3-tuple and is now five. A caller unpacking positionally
    keeps working as it grows — which is the hazard, not the convenience: adding
    a fourth element between `eras` and `breadth` would have silently handed
    every performer's album count to the era parameter. Named fields make that a
    `TypeError` at the call site instead of a wrong number in a score.
    """
    works: dict[str, str]
    eras: dict[str, tuple[str, ...]]
    breadth: dict[str, int]
    spheres: dict[str, tuple[str, ...]]
    scenes: dict[str, tuple[str, ...]]


def with_catalogue_metadata(
    rows: list[dict[str, Any]], catalogue_by_isrc: dict[str, dict[str, Any]]
) -> int:
    """Fill in what the source did not state, from Apple's catalogue.

    **Genre, composer and release date — not the genre alone.** The tool has
    stored all three since it was written; this join read one of them and
    silently ignored the other two, which were sitting in the same row of the
    same table having been fetched by the same request. A Spotify row enriched
    with all three is, in content, an Apple Music row: `terms_for` cannot tell
    them apart, and that is the point.

    The composer is the one that buys the most on a classical library. Spotify
    returns none anywhere, so `_is_classical` falls back to a catalogue number
    and the whole repertoire resolves to whoever performed it — Bach's partita
    filed under the ensemble. This is the field that separates them.

    **Why any of this exists.** Measured 2026-08-14: Apple Music stamps a genre
    on every song row a library has — 641 of 641 library songs — and Spotify
    stamps one on none, because its API states no genre at track level. A genre
    is the root of everything a person can see. `artist_spheres` reads nothing
    else, `artist_scenes` needs a sphere, and `takes_decades` gates the era, so
    a row without one reaches a bare `genre:` concept at best and usually
    nothing: 1,522 terms, 6 accepted mappings, 0 eligible assertions on a
    593-row library.

    **One place rather than two.** The genre feeds two families down two
    different paths — `terms_for` emits `genre:*` directly, `library_facts`
    computes `sphere:*`, `scene:*` and `era:*` per performer — and merging at
    each would be two copies of one decision, with the failure mode that the
    second gets forgotten. Both read the payload, so the payload is where the
    join belongs.

    **Not restricted to Spotify, though only Spotify needs it today.** The
    condition is *"this row states no genre and names an ISRC"*, which is a
    description of the gap rather than a list of the sources that have it —
    naming `spotify` here would be a deny-list, and the failure mode of a
    deny-list is silence.

    **A new dict, never a mutation of the loaded payload.** Nothing writes these
    rows back, and `guard_observation_immutable` would refuse it if anything
    tried: the catalogue is not the person's evidence and has no business in
    their vault. This is a read-time join that lives exactly as long as the run.

    Returns how many rows were filled, so a run can say so out loud rather than
    leaving "the catalogue was empty" and "the join never fired" as the same
    observation.
    """
    filled = 0
    for row in rows:
        payload = row.get("normalized_payload")
        if not isinstance(payload, dict):
            continue
        isrc = payload.get("isrc")
        if not isinstance(isrc, str):
            continue
        answer = catalogue_by_isrc.get(isrc)
        if not answer:
            continue

        # **The source always outranks the catalogue.** A field the row already
        # states is never overwritten — Apple's answer is for the recording, and
        # where the two disagree the one that came off the person's own library
        # is the one about them. Only an absence is filled.
        additions: dict[str, Any] = {}

        stated_genres = payload.get("genres")
        genres = answer.get("genreNames")
        if not (isinstance(stated_genres, list) and stated_genres) and genres:
            additions["genres"] = list(genres)

        # **Composer, and it is worth as much as the genre on a classical row.**
        # Apple states one on 8% of a classical library and `classical_composer`
        # recovers it from the title for the rest, but neither can fire on a
        # Spotify row: Spotify returns no composer anywhere, so `_is_classical`
        # falls back to a catalogue number and the repertoire resolves entirely
        # to whoever played it. This is the field that tells Bach from the
        # ensemble.
        stated_composer = payload.get("composer")
        composer = (answer.get("composerName") or "").strip()
        if not (isinstance(stated_composer, str) and stated_composer.strip()) and composer:
            additions["composer"] = composer

        # `music_works.artist_eras` takes `released[:4]`, so any precision works.
        stated_release = payload.get("release_date")
        released = (answer.get("releaseDate") or "").strip()
        if not (isinstance(stated_release, str) and stated_release.strip()) and released:
            additions["release_date"] = released

        if not additions:
            continue
        row["normalized_payload"] = {**payload, **additions}
        filled += 1
    return filled


def library_facts(rows: list[dict[str, Any]]) -> LibraryFacts:
    """The five things a single row cannot decide.

    **Both are properties of a set of rows.** A work propagates between releases
    of the same song — `Resister (Special Edition)` names none while
    `Resister (From "Sword Art Online: Alicization")` does — and an era is an
    artist-level fact, because every Hikaru Utada row is dated 2024 by the tour
    album they came from.

    Returns `song key -> work`, `performer -> eras`, and
    `normalized person -> distinct album count`.
    """
    flat: list[dict[str, Any]] = []
    for row in rows:
        payload = row.get("normalized_payload")
        if not isinstance(payload, dict):
            continue
        flat.append({
            "title": payload.get("title") or "",
            "album": payload.get("album") or "",
            "performer": payload.get("primary_performer") or "",
            "genres": [english_genre(g) for g in (payload.get("genres") or [])],
            "released": payload.get("release_date") or "",
            # **Carried for the period lookup**, which is what `artist_eras`
            # gained with `COMPOSER_PERIODS`. Apple states a composer on most
            # classical rows and `classical_composer` prefers a stated name to
            # one parsed out of a title — dropping it here made the strongest
            # available signal invisible to the one function that wanted it.
            "composer": payload.get("composer") or "",
        })

    works = propagate(flat)

    by_performer: dict[str, list[dict[str, Any]]] = {}
    for item in flat:
        by_performer.setdefault(item["performer"], []).append(item)
    eras = {
        performer: tuple(sorted(artist_eras(performer, items)))
        for performer, items in by_performer.items()
        if performer
    }

    # **The sphere and the scene, per performer for the same reason the era is.**
    # A row states a genre and the genre states a sphere, so a per-row sphere
    # would be defensible — but the *scene* crosses it with an era, and the era
    # is only decidable across an artist's rows. Deriving one per row and the
    # other per artist would let a single `Pop`-tagged Cantopop track put an
    # artist in the anglophone scene of a decade computed from everything else.
    spheres = {
        performer: tuple(sorted(artist_spheres(items)))
        for performer, items in by_performer.items()
        if performer
    }
    scenes = {
        performer: tuple(sorted(artist_scenes(
            performer, items, set(eras.get(performer, ())))))
        for performer, items in by_performer.items()
        if performer
    }

    # **How many distinct albums each person appears on**, which is the third
    # thing a single row cannot decide and the reason this function already
    # exists. Keyed per *person* rather than per credit string, because the
    # question is about Perlman rather than about
    # `Itzhak Perlman, Berlin Philharmonic & Daniel Barenboim`.
    #
    # Measured on the real library, this separates a performer somebody sought
    # out from one who happened to be on a recording — and row count does the
    # opposite. Pichon and Pygmalion have the *most* rows of anyone (276) and
    # one album: the St Matthew Passion, counted once per movement. Perlman has
    # a sixth as many rows across six albums.
    albums_by_person: dict[str, set[str]] = {}
    for item in flat:
        if not item["album"]:
            continue
        for person in people_in(item["performer"]):
            albums_by_person.setdefault(normalize_text(person), set()).add(item["album"])
    breadth = {person: len(albums) for person, albums in albums_by_person.items()}

    return LibraryFacts(works, eras, breadth, spheres, scenes)


def youtube_terms_for(payload: dict[str, Any],
                      allow_uploader_tags: bool,
                      allow_channel_identity: bool = False,
                      channel_titles: dict[str, str] | None = None,
                      allow_title_tags: bool = False,
                      ) -> tuple[Term, ...]:
    """The terms one YouTube observation supports.

    Two kinds, and they carry different permissions and different type rules.

    **`provider_topic` passes no `type_hint`, deliberately.** The hint exists to
    stop a *fuzzy* match landing on a concept of the wrong kind — it is what
    threw away 321 song titles that had matched `work` concepts. These are not
    fuzzy: each of the twenty is a mapping hand-authored in
    `tools/youtube_topics.py`, so the target was chosen rather than guessed and
    there is nothing left to check. Passing `topic` would actively break it —
    the hint permits only `{topic, genre, culture, cuisine}`, while six of the
    twenty resolve to `hub:*` and `medium:television`, which would be rejected on
    type after resolving correctly.

    **`uploader_tag` passes `creator`, equally deliberately.** A tag is the
    uploader's free text, so the guard is worth having: it is what stops the tag
    `music` reaching `hub:music`, and it means a tag can only ever become
    evidence about a creator.

    **Topics arrive as Wikipedia slugs and the underscores must go.** `0076`
    stored `normalized_label` as `topic.replace('_', ' ').lower()` — `music of
    asia` — so a term still carrying `Music_of_Asia` normalizes to something the
    alias map has never heard of and resolves to nothing at all, silently.
    """
    terms: list[Term] = []

    for topic in payload.get("topics") or []:
        text = str(topic).replace("_", " ").strip()
        if text:
            terms.append(_term(text, "provider_topic", "topics", None))

    # **Gated on the run's own policy, not on the approval.** A run opened
    # before `0078`'s determination existed is legitimately denied, and reading
    # the approval directly would grant it retroactively.
    if allow_uploader_tags:
        for tag in payload.get("tags") or []:
            text = str(tag).strip()
            # Whole tags only, and never a substring — recognising `physics` is
            # translation, matching `phys` inside a title is a guess wearing the
            # same clothes. `resolve_alias` compares whole normalized labels, so
            # the only thing needed here is the length floor.
            if len(text) >= MIN_TAG_LENGTH:
                terms.append(_term(text, "uploader_tag", "tags", "creator"))
                # **The same tag again, read as a work rather than as a name.**
                #
                # A hint admits one family, so `creator` alone meant a tag could
                # only ever be evidence about a person or a band, and a game
                # named outright had nowhere to land. Measured 2026-08-14: an
                # account subscribes to Kripparrian, whose channel keywords are
                # `Hearthstone|HS|Meta|Lucky Hearthstone|…`, and the only games
                # vocabulary the ontology held was four `genre:*` concepts —
                # withheld from Memories by `list_assertions`' kind allowlist,
                # and 43 accepted mappings that asserted nothing.
                #
                # **A catalogue rather than the whole `work` vocabulary, and the
                # measurement is why.** The first version of this passed the raw
                # tag with the hint `work`, which reaches every active `work`
                # alias. There are 50, and three of them are ordinary English
                # words — `bleach`, `wicked`, `overlord` — each minted from a
                # music library and each carrying the definition *"Read from a
                # music library; never inferred from a title."* One account's
                # own subscriptions already collide: `Anime Man Talks` tags
                # `Bleach`, which is right, and any channel tagging `wicked`
                # would have been handed a Broadway cast recording. Withdrawing
                # those aliases is not available — `work:wicked` stands at 0.683
                # on 30 music rows *because* of that alias — so the lane narrows
                # instead of the vocabulary. This is `work_titles.mjs`'s rule
                # applied one layer down: **an alias must not be a word**, and
                # where the ontology holds one anyway, free text may not reach
                # it.
                #
                # **So this emits a key, not the tag**, exactly as `title_work`
                # does, and for the same reason the type hint is a guard rather
                # than a widening: `0149` gives every catalogue concept its own
                # key as an `alternate` label, so the ordinary exact-alias path
                # matches it at 1.000 with no new resolution code, and a key
                # that somehow reached a creator is refused on type.
                #
                # **Two roles rather than one**, which is the shape
                # `title_hashtag` already uses against `written_title_tag`: the
                # two readings stay separable in `observation_mappings` so a
                # later change can weigh a work differently from a creator
                # without unpicking history. Both carry the stored kind
                # `uploader_tag` and both are gated on `allow_uploader_tags`,
                # because both are the same act — the uploader's own keyword —
                # and `0078` licenses the act, not a family of concept.
                #
                # **This estimates nothing**, which is the line III.E.4.h draws.
                # `Hearthstone` is matched whole against a list we authored;
                # deciding what a channel is *about* from its topics would be
                # the other thing, and is not done here or anywhere.
                game = GAME_TAG_CATALOGUE.get(text.casefold())
                if game is not None:
                    terms.append(
                        _term(game, "uploader_tag_work", "tags", "work")
                    )

    # **The channel, named rather than identified.** The projection carries only
    # `channel_id` — an opaque string that resolves to nothing — so the title
    # comes from `ontology.youtube_channels`, which is catalogue rather than
    # user data. Gated on the run's policy for the same reason the tags are: a
    # run opened before the determination existed is legitimately denied, and
    # reading the approval directly would grant it retroactively.
    #
    # `creator` as the type hint, exactly as an uploader tag takes: a channel
    # can only ever be evidence about a creator, and the hint is what stops a
    # channel called `Music` reaching `hub:music`.
    if allow_channel_identity:
        channel_id = payload.get("channel_id")
        title = (channel_titles or {}).get(str(channel_id or "")) or ""
        text = title.strip()
        if len(text) >= MIN_TAG_LENGTH:
            terms.append(_term(text, "channel_identity", "channel_id", "creator"))

    # **The same title again, read as a subject rather than as a name.**
    # `channel_identity` above passes the type hint `creator`, so a title can
    # only ever become evidence about a person or a band — which is correct for
    # what it is for, and is why a bioinformatics channel resolved to nothing on
    # an account with seventy of them. Measured 2026-08-13: those seventy carry
    # YouTube's own topic `Knowledge`, which reaches `hub:ideas_learning` at a
    # strength of 0.552 and is never asserted because a hub is a container. The
    # signal was strong, correctly scored, and had nowhere assertable to land.
    #
    # **This is the level that needs the licence, and it has one.** Reading
    # YouTube's labels onto our vocabulary needs nothing; assigning *our own*
    # descriptive tags to a channel is what the Content Categorization and
    # Tagging amendment §3 permits — "additive and distinct from YouTube's video
    # categories", which `subject:bioinformatics` is against `Education`. Gated
    # on the run's own `allow_title_tags` rather than on the approval row, for
    # the reason the two gates above are: a run opened before the 2026-08-13
    # determination existed is legitimately denied, and reading the approval
    # directly would grant it retroactively.
    #
    # **Whole tokens, never substrings**, which is `domainForCreatorTag`'s
    # restraint and the same rule `uploader_tag` follows. The title goes out
    # whole *and* split, because the vocabulary needs both: `Bioinformatics
    # DotCa` resolves on its token while `StatQuest with Josh Starmer` has no
    # token worth having and is aliased entire. Anything matching no alias
    # resolves to nothing, exactly as it does today — the controlled vocabulary
    # is the guard, not a length test.
    if allow_title_tags:
        channel_id = payload.get("channel_id")
        title = (channel_titles or {}).get(str(channel_id or "")) or ""
        seen: set[str] = set()
        for text in (title.strip(), *(_TITLE_TOKEN.split(title))):
            text = text.strip()
            # No `creator` hint: a subject is a `topic`, and passing the hint
            # `channel_identity` uses would reject every one of these on type
            # after resolving correctly — the trap `provider_topic` documents.
            if len(text) >= MIN_TAG_LENGTH and text.casefold() not in seen:
                seen.add(text.casefold())
                terms.append(_term(text, "written_title_tag", "channel_id", None))

    # **A hashtag is the uploader's own tag, so it takes `uploader_tag`'s
    # treatment rather than the channel title's.** The two are both "title
    # derived" and could not be more different in kind: a channel-title *token*
    # is a word cut out of a name nobody wrote as a tag, which is why it is
    # confined to `subject:` above; a hashtag was typed as a tag, deliberately,
    # and `#le_sserafim` means the group.
    #
    # So it passes the `creator` hint exactly as `snippet.tags` does — the hint
    # that stops the tag `music` reaching `hub:music` — and is not confined to a
    # family. Measured before building: `르세라핌` 316 videos, `le_sserafim` 204,
    # `kimchaewon` 146, all of which should reach a creator and none of which a
    # channel-title token ever could.
    #
    # `written_title_tag` is the *stored* kind for both, because that is the one
    # `0045` permits and `0135` licensed; the roles differ so the two readings
    # stay separable here.
    if allow_title_tags:
        for tag in payload.get("title_hashtags") or []:
            text = str(tag).strip()
            if len(text) >= MIN_TAG_LENGTH:
                terms.append(_term(text, "title_hashtag", "title_hashtags", "creator"))

    # **A work the title named outright, already recognised at ingestion.**
    # The other three lanes above resolve free text; this one resolves a key.
    # The recognition happened where the title still existed — in the Lambda,
    # against a bundled catalogue — because the title is discarded there and
    # never reaches `normalized_payload`, so no later stage could do it. What
    # arrives is `work:sword_art_online`, and `0149` gives every catalogue
    # concept its own key as an `alternate` label, so the ordinary exact-alias
    # path matches it as `curated_alias` at 1.000 with no new resolution code.
    #
    # **The `work` hint is the guard, not decoration.** It restricts the match
    # to `work` concepts, so a key that somehow reached a creator or a genre is
    # refused on type — the safety net that caught channel-title tokens landing
    # on musicians who shared a forename. Here it should never fire, which is
    # exactly when a type check earns its keep.
    #
    # Gated on `allow_title_tags` with the two lanes above, and for their
    # reason: a run opened before the 2026-08-13 determination is legitimately
    # denied, and reading the approval row directly would grant it backwards.
    if allow_title_tags:
        for key in payload.get("title_works") or []:
            text = str(key).strip()
            # A key of another family is not a work, and the projection guard
            # refuses one at the door. Checked again here because this file also
            # reads rows written before that guard existed.
            if text.startswith("work:"):
                terms.append(_term(text, "title_work", "title_works", "work"))

    return tuple(terms)


# The `youtube_semantic_kind` each term role becomes. `observation_mappings`
# constrains the column to five values and `0078` licenses exactly one of the
# gated ones; a role absent from this map stamps nothing and is refused by
# `guard_youtube_mapping_fusion`.
YOUTUBE_KIND_BY_ROLE = {
    "provider_topic": "provider_topic",
    "uploader_tag": "uploader_tag",
    # Permitted by `observation_mappings_youtube_semantic_v02_check` since
    # `0045`; granted by the 2026-08-13 determination in `0135`.
    "channel_identity": "channel_identity",
    # Permitted by `observation_mappings_youtube_semantic_v02_check` since
    # `0045` and granted by the 2026-08-13 determination in `0135`, which set
    # `allow_title_tags` — read by `resolve.py` and, until now, used by nothing.
    "written_title_tag": "written_title_tag",
    # Same stored kind, different role — see `youtube_terms_for`. The gate is
    # `title_tags` for both, which `guard_youtube_mapping_fusion` derives from
    # the kind rather than the role, so nothing else needs to learn this.
    "title_hashtag": "written_title_tag",
    # Third role on the same stored kind. A work named in a title is a term we
    # derived from a title, which is what `written_title_tag` names and what
    # `allow_title_tags` gates — so `guard_youtube_mapping_fusion`, which reads
    # the kind rather than the role, needs no change. The roles stay distinct
    # here because a channel-title token, a hashtag and a named work are three
    # different acts, and this store cannot be rewritten to separate them later.
    "title_work": "written_title_tag",
    # Second role on `uploader_tag`, and the same argument one layer down: a
    # keyword read as a name and the same keyword read as a work are two
    # readings of one act, so the stored kind — and therefore the gate
    # `guard_youtube_mapping_fusion` derives from it — is unchanged, while the
    # roles stay apart so the two can be weighed separately later.
    "uploader_tag_work": "uploader_tag",
}


def exact_terms_only(observation: Observation, graph: OntologyGraph) -> Observation | None:
    """Drop terms that can only ever produce a discarded fuzzy match.

    **`resolve_alias` falls back to comparing a term against every alias in the
    graph**, one `SequenceMatcher` per label, and that fallback fires for any
    term with no exact hit. Music barely noticed: its terms are curated aliases
    that match exactly. Uploader tags are arbitrary free text — roughly 5,500 of
    them on one real library, almost none matching anything — so each triggered a
    full scan of 1,512 labels. About 8.3 million string comparisons in pure
    Python, which is the whole of the worker's 300-second timeout.
    
    **And every result was already being thrown away.** The fuzzy path can only
    return `CANDIDATE` or `REJECTED` — never `ACCEPTED` — and the loop below
    skips any non-accepted `lexical` match as a near miss. So this removes no
    mapping that was ever written; it removes the work of computing answers
    nobody reads, which is this codebase's standing defect measured in CPU-minutes.
    
    It is also what `0078`'s resolver model already specified — `whole_tag_only`,
    `fuzzy: false`, `substring_matching: false` — and the resolver was simply not
    honouring it.

    Returns `None` when nothing survives, which the caller treats exactly as it
    treats an observation that supported no terms.
    """
    kept = tuple(t for t in observation.terms if t.normalized in graph.aliases)
    if not kept:
        return None
    return replace(observation, terms=kept)


def observation_from_row(row: dict[str, Any], source: dict[str, Any],
                         works: dict[str, str] | None = None,
                         eras: dict[str, tuple[str, ...]] | None = None,
                         allow_uploader_tags: bool = False,
                         allow_channel_identity: bool = False,
                         allow_title_tags: bool = False,
                         channel_titles: dict[str, str] | None = None,
                         breadth: dict[str, int] | None = None,
                         spheres: dict[str, tuple[str, ...]] | None = None,
                         scenes: dict[str, tuple[str, ...]] | None = None) -> Observation | None:
    payload = row["normalized_payload"]
    if not isinstance(payload, dict):
        return None

    # **YouTube takes its own branch rather than a wider `terms_for`.** Its
    # projection shares no field with music's — it has no title, no performer
    # and no genres, by design — so widening the music reader would mean a
    # function whose every line tests which source it is looking at.
    if row["source_code"] == YOUTUBE_SOURCE:
        terms = youtube_terms_for(
            payload, allow_uploader_tags,
            allow_channel_identity=allow_channel_identity,
            channel_titles=channel_titles,
            allow_title_tags=allow_title_tags)
    else:
        performer = payload.get("primary_performer") or ""
        key = normalized_song_key(payload.get("title") or "", performer)
        terms = terms_for(
            payload, row["action_type"],
            work=(works or {}).get(key),
            eras=(eras or {}).get(performer, ()),
            breadth=breadth,
            spheres=(spheres or {}).get(performer, ()),
            scenes=(scenes or {}).get(performer, ()),
        )
    if not terms:
        return None
    return Observation(
        id=str(row["id"]),
        source=row["source_code"],
        data_type=row["data_type"],
        action=row["action_type"],
        evidence_channel=source["evidence_channel"],
        independence_group=source["independence_group"],
        occurred_at=row["occurred_at"],
        collected_at=row["created_at"],
        terms=terms,
        record_fingerprint=row["record_fingerprint"],
        # Music observations carry no content lineage — that column is the
        # Calendar classifier's HMAC over a private title. The fingerprint is the
        # honest stand-in: it identifies the same content without claiming to be
        # a lineage signature.
        content_lineage=row["content_lineage_hmac"] or row["record_fingerprint"],
        field_quality=float(row["field_quality"]),
        action_weight=float(row["action_weight"]),
        privacy_class=row["privacy_class"],
        allow_external_resolution=bool(row["allow_external_resolution"]),
    )


# ---------------------------------------------------------------------------
# The run


SELECT_OBSERVATIONS = """
select o.id, o.source_code, o.data_type, o.action_type, o.occurred_at,
       o.created_at, o.record_fingerprint, o.content_lineage_hmac,
       o.normalized_payload, o.field_quality, o.action_weight, o.privacy_class,
       o.allow_external_resolution
  from semantic_private.observations o
  join semantic_private.current_source_items i
    on i.user_id = o.user_id
   and i.source_code = o.source_code
   and i.record_fingerprint = o.record_fingerprint
   and i.lifecycle_state = 'present'
 where o.user_id = %(user_id)s
   and o.source_code = any(%(sources)s)
   and o.lifecycle_state = 'active'
 order by o.occurred_at nulls last, o.id
 limit %(limit)s
"""
# **Joined to `current_source_items` rather than filtered afterwards.**
# `guard_mapping_current_source_v031` refuses a candidate or accepted mapping for
# an item that is not currently present, so a mapping built for a superseded
# revision would fail the insert and take the transaction with it. Measured on
# this account: 2,417 music observations, of which 1,314 are current — the rest
# are superseded revisions from the v1-to-v2 payload change and rows behind a run
# that was never finalized.

OPEN_RUN = """
insert into semantic_private.semantic_runs (
  user_id, ontology_version_id, resolver_model_id, scorer_model_id,
  embedding_model_id, input_revision, input_hash, status
) values (
  %(user_id)s, %(ontology_version_id)s, %(resolver_model_id)s, %(scorer_model_id)s,
  %(embedding_model_id)s, %(input_revision)s, %(input_hash)s, 'running'
)
-- **`do nothing`, because recomputing identical input is not an error.**
-- `semantic_run_live_identity_idx` is unique on
-- `(user, ontology version, resolver, scorer, input_revision, input_hash)` over
-- running and succeeded runs, so the same state resolved against the same
-- ontology by the same models can only be computed once. That is the contract
-- making `recompute_user` idempotent by construction — and it is the index its
-- ingestion counterpart cannot be, since `ingestion_runs.input_hash` covers
-- `observed_at` and differs every run. Here the hash is the ontology version and
-- the revision, so it means what it says.
on conflict do nothing
returning id, started_at
"""

EXISTING_RUN = """
select id, started_at, status
  from semantic_private.semantic_runs
 where user_id = %(user_id)s
   and ontology_version_id = %(ontology_version_id)s
   and resolver_model_id = %(resolver_model_id)s
   and scorer_model_id = %(scorer_model_id)s
   and input_revision = %(input_revision)s
   and input_hash = %(input_hash)s
   and status in ('running', 'succeeded')
"""

INSERT_MAPPING = """
insert into semantic_private.observation_mappings (
  semantic_run_id, observation_id, user_id, ontology_version_id, concept_id,
  mapping_method, mapping_state, confidence, candidate_rank, score_margin,
  feature_snapshot, evidence_path, evidence_weight, cross_source_fusion_allowed,
  youtube_semantic_kind,
  recency_weight, recency_quality, recency_policy_version, recency_rule_id,
  recency_status, recency_timestamp_quality, recency_as_of
) values (
  %(run)s, %(observation)s, %(user_id)s, %(version)s, %(concept)s,
  %(method)s, %(state)s, %(confidence)s, %(rank)s, %(margin)s,
  '{}'::jsonb, %(evidence_path)s::jsonb, %(evidence_weight)s, false,
  -- Null for every non-YouTube mapping, which is what the column's check
  -- allows and what `guard_youtube_mapping_fusion` expects. Stamped only
  -- where the source is YouTube, so a mapping can always be traced to the
  -- permission that licensed it.
  %(youtube_kind)s,
  %(recency_weight)s, %(recency_quality)s, %(recency_policy)s, %(recency_rule)s,
  %(recency_status)s, %(recency_quality_label)s, %(as_of)s
)
on conflict (semantic_run_id, observation_id, concept_id, mapping_method)
  do nothing
"""

# **Metrics while running, status by the finalizer.** `guard_semantic_run_update`
# refuses a direct move to `succeeded` — *"semantic runs must be succeeded by
# finalization"* — because `finalize_semantic_run` does more than set a status:
# it re-locks user state and marks the run `stale` if the input revision moved
# under it. Writing `succeeded` by hand would skip that check and claim a run was
# computed against state it no longer matches. A running run is freely updatable,
# so the metrics go first.
RECORD_METRICS = """
update semantic_private.semantic_runs
   set metrics = %(metrics)s::jsonb
 where id = %(run)s and user_id = %(user_id)s and status = 'running'
"""

SELECT_RUN_POLICY = """
select allow_uploader_tags, allow_channel_identity, allow_role_resolution,
       allow_title_tags, policy_version
  from semantic_private.youtube_run_policies
 where semantic_run_id = %(run)s
"""

# **Only the channels this user actually observed.** The catalogue is global —
# it is provider metadata, not user data — but loading all of it into every run
# would grow without bound, and the join is what keeps the lookup proportional
# to the person rather than to the table.
SELECT_CHANNEL_TITLES = """
select distinct ch.youtube_channel_id, ch.canonical_title
  from ontology.youtube_channels ch
  join semantic_private.observations o
    on o.normalized_payload->>'channel_id' = ch.youtube_channel_id
 where o.user_id = %(user_id)s
   and o.source_code = 'youtube'
   and o.lifecycle_state = 'active'
   and ch.lifecycle_state = 'active'
   and ch.canonical_title is not null
"""

INSERT_MENTION = """
insert into semantic_private.observation_mentions (
  observation_id, user_id, mention_text, normalized_text, mention_role,
  locale, type_hint, source_field, extraction_method, confidence,
  safe_for_global_mining, safe_for_external_resolution)
values (
  %(observation_id)s, %(user_id)s, %(mention_text)s, %(normalized_text)s,
  %(mention_role)s, 'und', %(type_hint)s, %(source_field)s, 'projection_field',
  1.0, false, false)
on conflict do nothing
"""

# **An allow-list, because the failure mode of a deny-list is silence.**
#
# A mention is a raw string out of somebody's library, so the question is not
# whether it is useful but whether storing it discloses anything not already
# stored. For these four the answer is no: the string is public catalogue
# metadata already sitting in `observations.normalized_payload`, and none of them
# carries a term restricting downstream use.
#
# The three refusals, each for its own reason and none of them "we forgot":
#
# * **`spotify`** — IV.2.1.a forbids ingesting Spotify Content into an ML/AI
#   model and IV.2.5 says a user's consent does not cure it. Growing vocabulary
#   from Spotify strings is exactly that. It is the source with the worst
#   resolution rate (5%) and the one that most needs the vocabulary grown, and it
#   still may not feed it; its route is catalogue identity, which reads and
#   discards rather than learning from Content.
# * **`youtube`** — III.E.4 gives titles and creator names 30 days, and
#   `sweep_youtube_vault_retention` covers `observations` and
#   `raw_source_records`. A mentions row would be the same strings outside the
#   sweep, which is how a retention obligation stops being true without anybody
#   deciding to break it.
# * **every calendar** — titles never reach the vault at all; the stored payload
#   is at most four keys. There is nothing here to index, and a table that could
#   hold one is what that design refuses.
MINEABLE_SOURCES = frozenset({
    "apple_music",
    "music_library",
    "apple_podcasts",
    "podcast",
})


def record_mentions(
    connection, user_id: str, unresolved: list[tuple[Any, Any]]
) -> int:
    """Write down the terms that matched nothing, before they are discarded.

    **The only place these strings still exist.** `exact_terms_only` drops every
    term absent from the alias graph and the sole trace is an integer —
    `no_exact_alias` was 2,881 on one run, which says how many were lost and
    nothing about which. A system that cannot name what it failed to recognise
    cannot learn to recognise it, and every route to growing the vocabulary
    begins here.

    **`safe_for_global_mining` is written `false` on every row.** Recording a
    term and licensing its promotion into shared vocabulary are two decisions;
    this is only the first, and `EmergentTermMiner`'s five-user privacy floor
    sits behind the second.

    Returns how many were written, so a run can say so rather than leaving
    "nothing was unresolved" and "nothing was recorded" as the same observation.
    """
    rows = [
        {
            "observation_id": observation.id,
            "user_id": user_id,
            "mention_text": term.text,
            "normalized_text": term.normalized,
            "mention_role": term.role,
            "type_hint": term.type_hint,
            "source_field": term.source_field,
        }
        for observation, term in unresolved
        if observation.source in MINEABLE_SOURCES and term.text and term.normalized
    ]
    if not rows:
        return 0
    with connection.cursor() as cursor:
        cursor.executemany(INSERT_MENTION, rows)
    return len(rows)


SELECT_CATALOGUE_METADATA = """
select distinct on (e.external_id)
       e.external_id, e.raw_payload
  from ontology.external_entities e
  join semantic_private.observations o
    on o.normalized_payload->>'isrc' = e.external_id
 where o.user_id = %(user_id)s
   and o.lifecycle_state = 'active'
   and e.provider = 'apple_music_catalog'
   and e.entity_kind = 'song'
 order by e.external_id, e.retrieved_at desc
"""
# **The genre-presence filter is gone deliberately.** A recording Apple answered
# for with a composer and no genre was excluded by it, which threw away the field
# that matters most on a classical row. `entity_kind = 'song'` replaces it,
# because the same provider now also stores artists.

FINALIZE_RUN = "select semantic_private.finalize_semantic_run(%(run)s) as finalized"

CURRENT_REVISION = """
select revision from semantic_private.user_state_versions where user_id = %(user_id)s
"""


def resolve_user(connection, user_id: str, job_payload: dict[str, Any]) -> dict[str, Any]:
    """Map this user's current music observations onto ontology concepts.

    **The run is opened here, unlike an observation's ingestion run.** That is
    the structural difference that makes resolution the worker's job at all:
    `guard_semantic_output_writable` requires a *running* `semantic_runs` row
    owned by the same user, and this process is the one that owns it. An
    observation, by contrast, belongs to the ingestion run that captured it,
    which is why writing observations from here could never work.
    """
    version = published_version(connection)
    counts = {
        "observations": 0,
        "no_terms": 0,
        "unweighted_action": 0,
        "mappings": 0,
        "accepted": 0,
        "rejected": 0,
    }

    graph, concept_ids = load_graph(connection, version)
    mapper = ObservationMapper(graph)

    with connection.cursor() as cursor:
        cursor.execute(
            "select source_code, evidence_channel, independence_group"
            "  from semantic_private.sources where source_code = any(%(sources)s)",
            {"sources": list(RESOLVED_SOURCES)},
        )
        sources = {row["source_code"]: row for row in cursor.fetchall()}

    with connection.cursor() as cursor:
        cursor.execute(SELECT_OBSERVATIONS, {
            "user_id": user_id,
            "sources": list(RESOLVED_SOURCES),
            "limit": MAX_OBSERVATIONS,
        })
        rows = cursor.fetchall()

    # **The revision as it is now, not as the job was queued with.**
    # `finalize_semantic_run` compares the run's `input_revision` against current
    # user state and marks the run `stale` if they differ — which is the right
    # answer for a revision that moved *during* the run, and the wrong one for a
    # job that merely sat in the queue while an unrelated distillation landed.
    # `recompute_user` means recompute against what exists now.
    with connection.cursor() as cursor:
        cursor.execute(CURRENT_REVISION, {"user_id": user_id})
        revision_row = cursor.fetchone()
    revision = revision_row["revision"] if revision_row else 0

    identity = {
        "user_id": user_id,
        "ontology_version_id": version,
        "resolver_model_id": job_payload["resolver_model_id"],
        "scorer_model_id": job_payload["scorer_model_id"],
        # The run's identity is the ontology it ran against and the state it
        # read, which is what makes a re-run comparable to this one.
        "input_revision": revision,
        "input_hash": f"{version}:{revision}",
    }

    with connection.cursor() as cursor:
        cursor.execute(OPEN_RUN, {
            **identity,
            "embedding_model_id": job_payload["embedding_model_id"],
        })
        run = cursor.fetchone()

    if run is None:
        # This exact input has already been resolved. Nothing to recompute, and
        # nothing to report as a failure — the mappings from that run are the
        # answer, and re-deriving them would produce the same rows.
        with connection.cursor() as cursor:
            cursor.execute(EXISTING_RUN, identity)
            existing = cursor.fetchone()
        counts["semantic_run_id"] = str(existing["id"]) if existing else None
        counts["already_resolved"] = True
        return counts

    run_id, as_of = run["id"], run["started_at"]

    # **The run's own policy, not the approval.** `initialize_youtube_run_policy`
    # writes this row from the active approval as the run is created, so a run
    # opened before `0078`'s determination existed carries `deny-all-v1` and is
    # legitimately refused. Reading the approval directly here would grant it
    # retroactively, which is the difference between a permission and a fact
    # about when something happened.
    with connection.cursor() as cursor:
        cursor.execute(SELECT_RUN_POLICY, {"run": run_id})
        policy = cursor.fetchone()
    allow_uploader_tags = bool(policy and policy["allow_uploader_tags"])
    allow_channel_identity = bool(policy and policy["allow_channel_identity"])
    allow_title_tags = bool(policy and policy["allow_title_tags"])
    counts["youtube_policy"] = policy["policy_version"] if policy else "missing"
    counts["allow_uploader_tags"] = allow_uploader_tags
    counts["allow_channel_identity"] = allow_channel_identity
    counts["allow_title_tags"] = allow_title_tags

    # Loaded once per run rather than per observation: a person's liked videos
    # concentrate heavily on a few channels, so the same title would otherwise
    # be fetched hundreds of times.
    channel_titles: dict[str, str] = {}
    if allow_channel_identity or allow_title_tags:
        with connection.cursor() as cursor:
            cursor.execute(SELECT_CHANNEL_TITLES, {"user_id": user_id})
            channel_titles = {
                row["youtube_channel_id"]: row["canonical_title"]
                for row in cursor.fetchall()
            }
    counts["channel_titles"] = len(channel_titles)

    # **Collected, then written in one statement.** This was one `INSERT` per
    # mapping, and at ~2,000 observations producing several terms each that is
    # thousands of sequential round trips through a *transaction pooler* — every
    # one paying full network latency inside a single transaction. Measured
    # before changing it: the run never finished, burning the Lambda's whole
    # 300s twice over, and `pg_stat_statements` put the blame on the
    # `semantic_runs` insert at 116s max, which was really later jobs blocking
    # on `semantic_run_live_identity_idx` while the first held its transaction
    # open for the entire resolution.
    mapping_rows: list[dict[str, Any]] = []
    # Terms that matched no alias, kept only long enough to be written down.
    unresolved: list[tuple[Observation, Term]] = []

    # **Before the facts, and that ordering is the whole of it.** `library_facts`
    # derives eras, spheres and scenes from the genres on each row, so a genre
    # merged afterwards would reach `genre:*` and none of the three — which is
    # the same shape as having no genre at all for everything a person sees.
    with connection.cursor() as cursor:
        cursor.execute(SELECT_CATALOGUE_METADATA, {"user_id": user_id})
        catalogue = {
            row["external_id"]: row["raw_payload"] or {} for row in cursor.fetchall()
        }
    counts["catalogue_fields"] = with_catalogue_metadata(rows, catalogue)

    # Computed once over the whole set, because neither is decidable per row.
    facts = library_facts(rows)

    for row in rows:
        source = sources.get(row["source_code"])
        if source is None:
            continue
        observation = observation_from_row(
            row, source, facts.works, facts.eras,
            allow_uploader_tags=allow_uploader_tags,
            allow_channel_identity=allow_channel_identity,
            allow_title_tags=allow_title_tags,
            channel_titles=channel_titles,
            breadth=facts.breadth, spheres=facts.spheres, scenes=facts.scenes)
        if observation is not None:
            kept_terms = exact_terms_only(observation, graph)
            before = len(observation.terms)
            after = len(kept_terms.terms) if kept_terms is not None else 0
            counts["no_exact_alias"] = counts.get("no_exact_alias", 0) + before - after
            # **Written down before being discarded.** Everything below deletes
            # these strings; this is the only place they still exist. See
            # `MINEABLE_SOURCES` for which of them may be kept and why the list
            # is short.
            if before > after:
                resolved = {term.normalized for term in (kept_terms.terms if kept_terms else ())}
                unresolved.extend(
                    (observation, term)
                    for term in observation.terms
                    if term.normalized not in resolved
                )
            observation = kept_terms
            if observation is None:
                counts["no_terms"] += 1
                continue
        if observation is None:
            counts["no_terms"] += 1
            continue
        counts["observations"] += 1

        try:
            recency = DEFAULT_RECENCY_POLICY.evaluate(
                domain=recency_domain(observation.source),
                source=observation.source,
                action=observation.action,
                occurred_at=observation.occurred_at,
                # **Pinned to the run, not to now.** `pin_recency_to_semantic_run`
                # enforces it in the database, and the reason is reproducibility:
                # a mapping's decay must be a function of the run it belongs to,
                # or re-reading the same run gives a different answer tomorrow.
                as_of=as_of,
            )
        except RecencyPolicyError:
            # **An action with no recency rule is dropped here, and the count is
            # the only trace.** For `recommendation` that is the policy speaking
            # rather than a gap: Apple chose the track, so it is not the user's
            # act, `action_weights` gives it exactly 0 and the policy declines to
            # give it a rule.
            #
            # **It was not the only action this hit, and saying so cost 560
            # observations.** `0139` weighed Spotify's `top_track` and
            # `top_artist` in the database and left `SOURCE_ACTION_WEIGHTS` and
            # this policy untouched, so every one of them landed here — correctly
            # weighted, correctly projected, silently discarded — while the
            # sentence above said that could not be happening. A comment naming
            # the one case it knows about reads as an exhaustive list to the next
            # person, and this counter is otherwise indistinguishable from a
            # policy working as intended.
            #
            # If this number is larger than the `recommendation` rows in a run,
            # something is being dropped that nobody decided to drop.
            counts["unweighted_action"] += 1
            continue

        for candidate in mapper.map_observation(observation):
            # **Rejections are counted, not stored.** `resolve_alias` falls back
            # to fuzzy matching at 0.87 similarity when no exact alias matches,
            # so an album title reaches `genre:chamber_music` and a song title
            # reaches `routine:consistent_sleep_schedule` — and every one is
            # refused by `_type_compatible`, which is the safety net working.
            # The first run stored them: 2,824 rejected rows against 1,055
            # meaningful ones, burying the signal in matches the type system had
            # already thrown away. A rejection is not an abstention about a real
            # candidate; it is a near-miss that was never a candidate.
            if str(candidate.state) == "rejected":
                counts["rejected"] = counts.get("rejected", 0) + 1
                continue

            # **A fuzzy match that was not accepted is a near-miss, not a
            # candidate.** `resolve_alias` accepts a lexical match only above
            # 0.87 and hands back everything below it for review — which was
            # harmless while those matches hit concepts of the wrong kind and
            # were rejected on type. Once `work` concepts existed, song titles
            # and album names became type-compatible with them, and 321 matches
            # at confidence 0.28–0.56 landed as candidates against 77 real ones:
            # `Bleach: Thousand-Year Blood War` collected 139 albums it has
            # nothing to do with. Every genuine mapping here is a `curated_alias`
            # at 1.000.
            if candidate.method == "lexical" and str(candidate.state) != "accepted":
                counts["near_miss"] = counts.get("near_miss", 0) + 1
                continue
            concept_id = concept_ids.get(candidate.concept_key)
            if concept_id is None:
                continue
            # **A channel title may only ever name a subject**, and without this
            # it names whatever its words happen to spell. The title goes out
            # token by token, so `StatQuest with Josh Starmer` offers `Josh` and
            # `Starmer` to a creator vocabulary holding 1,111 performer names —
            # and a match there is not a weak signal, it is a wrong one: a
            # bioinformatics channel becomes YouTube evidence about a musician
            # who shares a forename.
            #
            # It failed loudly rather than quietly, which was luck.
            # `guard_youtube_assertion_evidence` refuses YouTube evidence on an
            # assertion whose outward surfaces `0128` opened — every music-
            # evidenced creator — so the first such mapping killed the whole
            # run with `YouTube assertion evidence conflicts with surface
            # policy`. Had those surfaces been shut, the mapping would have been
            # written and nobody would have known.
            #
            # A `type_hint` cannot express this: the hint vocabulary is
            # `{topic, genre, culture, cuisine}`, which would still admit
            # `genre:pop` from the token `Pop` and every `scene:*`, all of them
            # `topic` by kind. The family is the rule, so the family is what is
            # tested.
            if (candidate.term.role == "written_title_tag"
                    and not candidate.concept_key.startswith("subject:")):
                counts["title_tag_off_family"] = \
                    counts.get("title_tag_off_family", 0) + 1
                continue
            mapping_rows.append({
                    "run": run_id,
                    "observation": observation.id,
                    "user_id": user_id,
                    "version": version,
                    "concept": concept_id,
                    "method": candidate.method,
                    "state": str(candidate.state),
                    "confidence": candidate.confidence,
                    "rank": candidate.rank,
                    "margin": candidate.score_margin,
                    "evidence_path": json.dumps(
                        list(candidate.evidence_path) + [recency.evidence_step()]
                    ),
                    "evidence_weight": candidate.term.evidence_weight,
                    "recency_weight": recency.weight,
                    "recency_quality": recency.timestamp_quality_weight,
                    "recency_policy": recency.policy_version,
                    "recency_rule": recency.rule_id,
                    "recency_status": str(recency.temporal_status),
                    "recency_quality_label": str(recency.timestamp_quality),
                    "as_of": as_of,
                    "youtube_kind": (
                        YOUTUBE_KIND_BY_ROLE.get(candidate.term.role)
                        if observation.source == YOUTUBE_SOURCE else None
                    ),
            })
            counts["mappings"] += 1
            if str(candidate.state) == "accepted":
                counts["accepted"] += 1

    # `executemany` pipelines under psycopg 3, so this is one round trip rather
    # than one per row. Nothing about what is written changes — same statement,
    # same `on conflict do nothing`, same order.
    if mapping_rows:
        with connection.cursor() as cursor:
            cursor.executemany(INSERT_MAPPING, mapping_rows)

    counts["mentions_recorded"] = record_mentions(connection, user_id, unresolved)

    # **Scoring runs inside this run, not a second one.** A score belongs to the
    # mappings it was computed from, and `finalize_semantic_run`'s staleness
    # check covers the whole run — mappings and scores together — only because
    # they share one. Two runs could interleave with a distillation and leave
    # scores describing mappings that are no longer current, with nothing saying
    # so.
    #
    # Before `RECORD_METRICS` so the run's metrics describe what it actually
    # did. A run that scored nothing and a run that never tried are different
    # facts, and the metrics are the only place that difference is visible.
    counts.update(score_user(connection, user_id, run_id, version, as_of))

    with connection.cursor() as cursor:
        cursor.execute(RECORD_METRICS, {
            "run": run_id,
            "user_id": user_id,
            "metrics": json.dumps(counts),
        })

    with connection.cursor() as cursor:
        cursor.execute(FINALIZE_RUN, {"run": run_id})
        finalized = cursor.fetchone()["finalized"]

    counts["semantic_run_id"] = str(run_id)
    # `False` means the finalizer found the input revision had moved and marked
    # the run `stale`. The mappings it wrote are still there and still correct
    # for the state they were computed against; what is not claimed is that they
    # are current. A later job recomputes.
    counts["finalized"] = bool(finalized)
    return counts
