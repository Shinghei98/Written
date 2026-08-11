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

**Music only, and three separate mechanisms agree on that.**
`ObservationMapper._source_projection_is_valid` refuses Calendar outright and
demands an exact fitness-candidate shape for HealthKit;
`guard_calendar_observation_mapping` says the same thing again in the database;
and §7 permits only the current Calendar classifier over Calendar rows. Nothing
here bypasses any of them.

**Unresolved terms are emitted anyway, and that is the point of emitting them.**
Artists, works and composers resolve to nothing today, because the ontology holds
genres and no creators. They are still built, because they are the input to
`EmergentTermMiner` — which needs five distinct users before it will surface
anything for curator review, and cannot start counting terms that were never
made. Dropping them would be dropping the ontology's growth path.
"""

from __future__ import annotations

import json
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
from written_ontology.recency import (
    DEFAULT_RECENCY_POLICY,
    RecencyPolicyError,
)

# The `recency` domain each source belongs to, which is the policy's own
# vocabulary rather than ours.
RECENCY_DOMAIN = "music"

MUSIC_SOURCES = ("apple_music", "music_library", "spotify")

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


def _term(text: str, role: str, source_field: str, type_hint: str | None) -> Term:
    return Term(
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


def terms_for(payload: dict[str, Any], action: str) -> tuple[Term, ...]:
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

    title = _text(payload.get("title"))
    # An artist row's `title` *is* the artist. Anything else is a work.
    title_is_creator = action in {"library_artist", "followed_artist"}
    if title:
        terms.append(_term(
            title,
            "creator" if title_is_creator else "work",
            "title",
            "creator" if title_is_creator else "work",
        ))

    seen_creators = {normalize_text(title)} if title_is_creator else set()
    performers = [_text(payload.get("primary_performer"))]
    credited = payload.get("credited_artists")
    if isinstance(credited, list):
        performers.extend(_text(item) for item in credited)
    for performer in performers:
        if not performer or normalize_text(performer) in seen_creators:
            continue
        seen_creators.add(normalize_text(performer))
        terms.append(_term(performer, "creator", "primary_performer", "creator"))

    composer = _text(payload.get("composer"))
    if composer:
        # **Kept apart from the performer, which is the whole reason this field
        # is carried.** The "artist" of a Bach partita is whoever played it, and
        # a library that is 1,440 classical rows is unreadable without the
        # distinction.
        terms.append(_term(composer, "composer", "composer", "creator"))

    album = _text(payload.get("album"))
    if album and normalize_text(album) != normalize_text(title):
        terms.append(_term(album, "album", "album", "work"))

    genres = payload.get("genres")
    if isinstance(genres, list):
        for genre in genres:
            text = _text(genre)
            if text:
                terms.append(_term(text, "genre", "genres", "genre"))

    return tuple(terms)


def observation_from_row(row: dict[str, Any], source: dict[str, Any]) -> Observation | None:
    payload = row["normalized_payload"]
    if not isinstance(payload, dict):
        return None
    terms = terms_for(payload, row["action_type"])
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
  recency_weight, recency_quality, recency_policy_version, recency_rule_id,
  recency_status, recency_timestamp_quality, recency_as_of
) values (
  %(run)s, %(observation)s, %(user_id)s, %(version)s, %(concept)s,
  %(method)s, %(state)s, %(confidence)s, %(rank)s, %(margin)s,
  '{}'::jsonb, %(evidence_path)s::jsonb, %(evidence_weight)s, false,
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
            {"sources": list(MUSIC_SOURCES)},
        )
        sources = {row["source_code"]: row for row in cursor.fetchall()}

    with connection.cursor() as cursor:
        cursor.execute(SELECT_OBSERVATIONS, {
            "user_id": user_id,
            "sources": list(MUSIC_SOURCES),
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

    for row in rows:
        source = sources.get(row["source_code"])
        if source is None:
            continue
        observation = observation_from_row(row, source)
        if observation is None:
            counts["no_terms"] += 1
            continue
        counts["observations"] += 1

        try:
            recency = DEFAULT_RECENCY_POLICY.evaluate(
                domain=RECENCY_DOMAIN,
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
            concept_id = concept_ids.get(candidate.concept_key)
            if concept_id is None:
                continue
            with connection.cursor() as cursor:
                cursor.execute(INSERT_MAPPING, {
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
                })
            counts["mappings"] += 1
            if str(candidate.state) == "accepted":
                counts["accepted"] += 1

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
