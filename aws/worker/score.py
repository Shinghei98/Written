"""Scoring: 12,017 mappings become claims about a person.

**This is the first thing in the system that says something about somebody.**
Everything before it is bookkeeping — a row was captured, an observation was
made, a term resolved to a concept. A `user_assertion` is the first artefact
that asserts *this person has an affinity to this concept*, and it is the reason
the vault exists.

It runs inside the resolver's own `semantic_run`, between the mappings and
`finalize_semantic_run`. Not a second run, deliberately: a score belongs to the
mappings it was computed from, and two runs could interleave with a distillation
and score against inputs that no longer exist. The finalizer's staleness check
covers the whole run, mappings and scores together, only because they share one.

## The scoring model, and what each number refuses to claim

`concept_scores` asks for six numbers and they are not interchangeable. Filling
them all from one aggregate would make five of them decoration.

- **`strength` saturates, it does not sum.** One concept carries 3,893
  `library_song` mappings; a linear sum would be meaningless above about three.
  `w / (w + HALF_WEIGHT)` maps any total onto [0,1) with an interpretable knob:
  at `w == HALF_WEIGHT` the strength is exactly 0.5. Owning a thousand songs by
  an artist is stronger than owning ten, and not a hundred times stronger.

- **`confidence` is about the evidence, not the affinity.** It rises with the
  number of distinct observations and with breadth across independence groups,
  because one source repeating itself is not corroboration. A single mapping is
  low-confidence however heavily weighted.

- **`independent_source_breadth` counts independence *groups*, never sources.**
  `apple_music`, `music_library` and `spotify` all carry the group `music` by
  design — three streaming services agreeing that you played a song is one
  witness, not three. Today every music mapping is in that one group, so this
  is 1 for every concept and will stay 1 until a YouTube observation exists.

- **`stability` is 0.0 on a first run and that is a refusal, not a placeholder.**
  Stability means a score held across runs. With no prior run there is no
  evidence either way, and 1.0 would assert a property from the absence of
  observation — the failure this codebase names as inferring absence from
  omission. The basis is recorded in `explanation` so the zero is readable as
  "not yet measurable" rather than "measured as unstable".

- **`missing_source_count` is what the user has connected that said nothing
  about this concept**, which is the honest denominator for how much of the
  picture we have. A concept evidenced by one of five connected sources is a
  different claim from one evidenced by the only source connected.

## What becomes an assertion

Not every scored concept. `capture broadly, promote narrowly` applies here as
much as at ingestion: a concept below `ELIGIBLE_STRENGTH` gets a score and no
claim, and a concept above it gets an assertion at `machine_state='eligible'`.
Everything scored is inspectable; only what clears the bar is assertable.

The predicate is `affinity_to` — user_claim, assertion-safe, zero inference hops
("defeasible or explicit user affinity"). It is the only predicate in the
vocabulary that means *this person likes this*, and its zero hops matter: an
affinity does not propagate along `broader`, so liking one K-pop group never
becomes liking Asian music by arithmetic.
"""

from __future__ import annotations

import json
from typing import Any

# At this total weight a concept scores exactly 0.5. Calibrated against the real
# corpus: a strongly-evidenced artist accumulates roughly 8-15 weighted mappings
# (library songs at 0.48, plays at 0.78, ratings at 0.88), so 6.0 puts a
# well-evidenced artist above 0.5 and a one-song artist near 0.1.
HALF_WEIGHT = 6.0

# Confidence saturates on observation count the same way, but far sooner —
# a handful of independent observations is most of the confidence available.
HALF_OBSERVATIONS = 4.0

# Below this a concept is scored and makes no claim.
ELIGIBLE_STRENGTH = 0.35

AFFINITY_PREDICATE = "affinity_to"


# **Aggregated in SQL rather than in Python.** 12,017 mappings across ~340
# concepts is small, but pulling them into the Lambda to group them would put
# somebody's whole library in memory for arithmetic Postgres does better — and
# the weights are already columns.
#
# `evidence_weight` and `recency_weight` are what the resolver stored per
# mapping; `default_reliability` and the per-action weight come from
# `semantic_private.sources`, which is authored data and not this file's
# business to invent.
AGGREGATE = """
select
  m.concept_id,
  count(*)                                     as mapping_count,
  count(distinct m.observation_id)             as observation_count,
  count(distinct o.source_code)                as source_count,
  count(distinct s.independence_group)         as breadth,
  sum(
    m.evidence_weight
    * m.recency_weight
    * s.default_reliability
    * coalesce((s.action_weights ->> o.action_type)::double precision, 0.0)
  )                                            as total_weight,
  avg(m.confidence)                            as mapping_agreement,
  avg(m.recency_quality * s.default_reliability) as evidence_quality
from semantic_private.observation_mappings m
join semantic_private.observations o on o.id = m.observation_id
join semantic_private.sources s on s.source_code = o.source_code
where m.semantic_run_id = %(run)s
  and m.user_id = %(user_id)s
  and m.mapping_state = 'accepted'
group by m.concept_id
having sum(
    m.evidence_weight * m.recency_weight * s.default_reliability
    * coalesce((s.action_weights ->> o.action_type)::double precision, 0.0)
  ) > 0
"""

# The mappings behind one concept, for `assertion_evidence`. Its
# `independence_group` must equal the group of the source the observation came
# from — a trigger checks it — so the group is read here rather than assumed.
EVIDENCE = """
select m.id as mapping_id, s.independence_group,
       m.evidence_weight * m.recency_weight * s.default_reliability
         * coalesce((s.action_weights ->> o.action_type)::double precision, 0.0)
         as weight,
       m.recency_weight, m.recency_quality, m.recency_policy_version,
       m.recency_rule_id, m.recency_status, m.recency_timestamp_quality,
       o.source_code, o.action_type
from semantic_private.observation_mappings m
join semantic_private.observations o on o.id = m.observation_id
join semantic_private.sources s on s.source_code = o.source_code
where m.semantic_run_id = %(run)s and m.user_id = %(user_id)s
  and m.concept_id = %(concept)s and m.mapping_state = 'accepted'
"""

CONNECTED_SOURCES = """
select count(distinct source_code) as n
from semantic_private.observations where user_id = %(user_id)s
"""

INSERT_SCORE = """
insert into semantic_private.concept_scores (
  semantic_run_id, user_id, ontology_version_id, concept_id,
  strength, confidence, independent_source_breadth, stability,
  usable_source_count, missing_source_count, explanation,
  mapping_agreement, evidence_quality, recency_policy_version, recency_as_of
) values (
  %(run)s, %(user_id)s, %(version)s, %(concept)s,
  %(strength)s, %(confidence)s, %(breadth)s, %(stability)s,
  %(usable)s, %(missing)s, %(explanation)s,
  %(agreement)s, %(quality)s, %(policy)s, %(as_of)s
)
on conflict (semantic_run_id, concept_id) do nothing
"""

FIND_ASSERTION = """
select id from semantic_private.user_assertions
where user_id = %(user_id)s and predicate_key = %(predicate)s
  and concept_id = %(concept)s
limit 1
"""

INSERT_ASSERTION = """
insert into semantic_private.user_assertions (
  user_id, predicate_key, concept_id, created_ontology_version_id,
  source_semantic_run_id, assertion_origin, machine_state
) values (
  %(user_id)s, %(predicate)s, %(concept)s, %(version)s,
  %(run)s, 'inferred', %(state)s
) returning id
"""

# **An assertion that stops being evidenced becomes `inactive`, never deleted.**
# "Collected then struck off" and "never collected" are different facts, which is
# the same reasoning `markedRemoved` carries in the legacy path.
UPDATE_ASSERTION = """
update semantic_private.user_assertions
set machine_state = %(state)s, updated_at = now()
where id = %(id)s and user_id = %(user_id)s
"""

INSERT_SCORE_VERSION = """
insert into semantic_private.assertion_score_versions (
  assertion_id, user_id, semantic_run_id, ontology_version_id,
  strength, confidence, breadth, stability, surfacing_score, display_payload,
  mapping_agreement, evidence_quality, recency_policy_version, recency_as_of
) values (
  %(assertion)s, %(user_id)s, %(run)s, %(version)s,
  %(strength)s, %(confidence)s, %(breadth)s, %(stability)s,
  %(surfacing)s, %(payload)s,
  %(agreement)s, %(quality)s, %(policy)s, %(as_of)s
)
on conflict (assertion_id, semantic_run_id) do nothing
returning id
"""

INSERT_EVIDENCE = """
insert into semantic_private.assertion_evidence (
  assertion_score_version_id, user_id, observation_mapping_id,
  contribution, independence_group, evidence_path,
  recency_weight, recency_quality, recency_policy_version,
  recency_rule_id, recency_status, recency_timestamp_quality, recency_as_of
) values (
  %(version_id)s, %(user_id)s, %(mapping)s,
  %(contribution)s, %(group)s, %(path)s,
  %(recency_weight)s, %(recency_quality)s, %(policy)s,
  %(rule)s, %(status)s, %(quality_label)s, %(as_of)s
)
on conflict (assertion_score_version_id, observation_mapping_id) do nothing
"""

CONCEPT_LABELS = """
select c.id, c.concept_key, r.preferred_label, r.concept_kind
from ontology.concepts c
join ontology.concept_revisions r on r.concept_id = c.id
where r.ontology_version_id = %(version)s
"""

# **Read from the mappings rather than passed in.** A score's recency policy
# must be the one its evidence was weighted under; taking it as an argument
# means two places can disagree and the row would still insert, recording a
# policy that never touched the numbers.
RUN_POLICY_VERSION = """
select recency_policy_version, count(*) as n
from semantic_private.observation_mappings
where semantic_run_id = %(run)s and user_id = %(user_id)s
group by recency_policy_version order by n desc limit 1
"""


def _saturate(value: float, half: float) -> float:
    """Map a non-negative total onto [0,1), reaching 0.5 at `half`.

    Chosen over a hard cap because a cap loses all ordering above it: every
    heavily-evidenced concept would tie at 1.0 and the strongest signal in the
    library would be indistinguishable from the tenth strongest.
    """
    if value <= 0:
        return 0.0
    return value / (value + half)


def score_user(connection, user_id: str, run_id: str, version: str,
               as_of: Any) -> dict[str, Any]:
    """Score every concept this run mapped, and assert the ones that clear the bar.

    Returns counts for the run metrics. Writes nothing outside the run, and
    promotes nothing — `finalize_semantic_run` does that, and only after
    re-checking that the input revision has not moved.
    """
    counts: dict[str, Any] = {
        "scored": 0, "eligible": 0, "candidate": 0, "evidence_rows": 0,
    }

    with connection.cursor() as cursor:
        cursor.execute(RUN_POLICY_VERSION, {"run": run_id, "user_id": user_id})
        row = cursor.fetchone()
    if row is None:
        # No mappings, so nothing to score. Not a failure: a run over a library
        # that resolved to nothing is a real and uninteresting outcome.
        return counts
    policy_version = row["recency_policy_version"]

    with connection.cursor() as cursor:
        cursor.execute(CONCEPT_LABELS, {"version": version})
        labels = {str(row["id"]): row for row in cursor.fetchall()}

    with connection.cursor() as cursor:
        cursor.execute(CONNECTED_SOURCES, {"user_id": user_id})
        row = cursor.fetchone()
        connected = int(row["n"]) if row else 0

    with connection.cursor() as cursor:
        cursor.execute(AGGREGATE, {"run": run_id, "user_id": user_id})
        aggregates = cursor.fetchall()

    for agg in aggregates:
        concept_id = str(agg["concept_id"])
        label = labels.get(concept_id, {})

        strength = _saturate(float(agg["total_weight"]), HALF_WEIGHT)
        observation_confidence = _saturate(
            float(agg["observation_count"]), HALF_OBSERVATIONS)
        breadth = int(agg["breadth"])
        # Breadth multiplies confidence rather than strength: a second
        # independent witness does not make somebody like an artist more, it
        # makes us more sure they do.
        confidence = min(1.0, observation_confidence * (1.0 + 0.25 * (breadth - 1)))
        usable = int(agg["source_count"])

        explanation = {
            "total_weight": round(float(agg["total_weight"]), 4),
            "mapping_count": int(agg["mapping_count"]),
            "observation_count": int(agg["observation_count"]),
            "half_weight": HALF_WEIGHT,
            "stability_basis": "no_prior_run",
            "concept_key": label.get("concept_key"),
        }

        with connection.cursor() as cursor:
            cursor.execute(INSERT_SCORE, {
                "run": run_id, "user_id": user_id, "version": version,
                "concept": concept_id,
                "strength": strength, "confidence": confidence,
                "breadth": breadth, "stability": 0.0,
                "usable": usable, "missing": max(0, connected - usable),
                "explanation": json.dumps(explanation),
                "agreement": float(agg["mapping_agreement"]),
                "quality": float(agg["evidence_quality"]),
                "policy": policy_version, "as_of": as_of,
            })
        counts["scored"] += 1

        state = "eligible" if strength >= ELIGIBLE_STRENGTH else "candidate"
        counts[state] += 1
        if state != "eligible":
            # Scored and inspectable, asserting nothing. Promote narrowly.
            continue

        with connection.cursor() as cursor:
            cursor.execute(FIND_ASSERTION, {
                "user_id": user_id, "predicate": AFFINITY_PREDICATE,
                "concept": concept_id,
            })
            existing = cursor.fetchone()

        if existing:
            assertion_id = existing["id"]
            with connection.cursor() as cursor:
                cursor.execute(UPDATE_ASSERTION, {
                    "id": assertion_id, "user_id": user_id, "state": state,
                })
        else:
            with connection.cursor() as cursor:
                cursor.execute(INSERT_ASSERTION, {
                    "user_id": user_id, "predicate": AFFINITY_PREDICATE,
                    "concept": concept_id, "version": version,
                    "run": run_id, "state": state,
                })
                assertion_id = cursor.fetchone()["id"]

        payload = {
            "concept_key": label.get("concept_key"),
            "label": label.get("preferred_label"),
            "kind": label.get("concept_kind"),
        }
        with connection.cursor() as cursor:
            cursor.execute(INSERT_SCORE_VERSION, {
                "assertion": assertion_id, "user_id": user_id, "run": run_id,
                "version": version, "strength": strength,
                "confidence": confidence, "breadth": breadth, "stability": 0.0,
                "surfacing": strength * confidence,
                "payload": json.dumps(payload),
                "agreement": float(agg["mapping_agreement"]),
                "quality": float(agg["evidence_quality"]),
                "policy": policy_version, "as_of": as_of,
            })
            version_row = cursor.fetchone()

        if version_row is None:
            # Already scored in this run. Its evidence is already written.
            continue
        score_version_id = version_row["id"]

        with connection.cursor() as cursor:
            cursor.execute(EVIDENCE, {
                "run": run_id, "user_id": user_id, "concept": concept_id,
            })
            evidence = cursor.fetchall()

        total = sum(float(e["weight"]) for e in evidence) or 1.0
        for item in evidence:
            with connection.cursor() as cursor:
                cursor.execute(INSERT_EVIDENCE, {
                    "version_id": score_version_id, "user_id": user_id,
                    "mapping": item["mapping_id"],
                    # A share of the whole, so `contribution` stays in [0,1] and
                    # the set sums to one. It answers "how much of this claim
                    # rests on this row", which is what an explanation needs.
                    "contribution": float(item["weight"]) / total,
                    "group": item["independence_group"],
                    "path": json.dumps({
                        "source": item["source_code"],
                        "action": item["action_type"],
                    }),
                    "recency_weight": item["recency_weight"],
                    "recency_quality": item["recency_quality"],
                    "policy": item["recency_policy_version"],
                    "rule": item["recency_rule_id"],
                    "status": item["recency_status"],
                    "quality_label": item["recency_timestamp_quality"],
                    "as_of": as_of,
                })
            counts["evidence_rows"] += 1

    return counts
