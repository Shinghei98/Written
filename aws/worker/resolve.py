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
from dataclasses import replace
from typing import Any

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
    if not isinstance(genres, list):
        return False
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
              breadth: dict[str, int] | None = None) -> tuple[Term, ...]:
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

    return tuple(terms)


def library_facts(
    rows: list[dict[str, Any]],
) -> tuple[dict[str, str], dict[str, tuple[str, ...]], dict[str, int]]:
    """The three things a single row cannot decide: work, era, and breadth.

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

    return works, eras, breadth


def youtube_terms_for(payload: dict[str, Any],
                      allow_uploader_tags: bool) -> tuple[Term, ...]:
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

    return tuple(terms)


# The `youtube_semantic_kind` each term role becomes. `observation_mappings`
# constrains the column to five values and `0078` licenses exactly one of the
# gated ones; a role absent from this map stamps nothing and is refused by
# `guard_youtube_mapping_fusion`.
YOUTUBE_KIND_BY_ROLE = {
    "provider_topic": "provider_topic",
    "uploader_tag": "uploader_tag",
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
                         breadth: dict[str, int] | None = None) -> Observation | None:
    payload = row["normalized_payload"]
    if not isinstance(payload, dict):
        return None

    # **YouTube takes its own branch rather than a wider `terms_for`.** Its
    # projection shares no field with music's — it has no title, no performer
    # and no genres, by design — so widening the music reader would mean a
    # function whose every line tests which source it is looking at.
    if row["source_code"] == YOUTUBE_SOURCE:
        terms = youtube_terms_for(payload, allow_uploader_tags)
    else:
        performer = payload.get("primary_performer") or ""
        key = normalized_song_key(payload.get("title") or "", performer)
        terms = terms_for(
            payload, row["action_type"],
            work=(works or {}).get(key),
            eras=(eras or {}).get(performer, ()),
            breadth=breadth,
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
    counts["youtube_policy"] = policy["policy_version"] if policy else "missing"
    counts["allow_uploader_tags"] = allow_uploader_tags

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

    # Computed once over the whole set, because neither is decidable per row.
    works, eras, breadth = library_facts(rows)

    for row in rows:
        source = sources.get(row["source_code"])
        if source is None:
            continue
        observation = observation_from_row(
            row, source, works, eras, allow_uploader_tags=allow_uploader_tags,
            breadth=breadth)
        if observation is not None:
            before = len(observation.terms)
            observation = exact_terms_only(observation, graph)
            after = len(observation.terms) if observation is not None else 0
            counts["no_exact_alias"] = counts.get("no_exact_alias", 0) + before - after
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
            # **`recommendation` is the only action this hits, and skipping it is
            # the policy speaking rather than a gap.** Apple chose the track, so
            # it is not the user's act — `action_weights` gives it exactly 0 and
            # the recency policy declines to give it a rule. Counted, never
            # silently dropped.
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
