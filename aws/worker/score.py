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

# **Concept kinds that are scored and never asserted.**
#
# A hub is where a concept *lives*, not something somebody likes. `hub:music` at
# 0.92 says this person likes music, which is true of everyone with a music
# library — it is the denominator, not a fact about them. The three that
# surfaced on a real profile were `music`, `ideas_learning` and `film_video`,
# and none of them distinguishes one person from another.
#
# **Scored, though, and that is deliberate.** `concept_scores` is what a
# Memories page groups by, and a hub with no score would leave a section with no
# heading. The exclusion is on the *claim*, which is the same distinction
# `notAnAction(.container)` draws for a playlist or a calendar: captured
# broadly, promoted narrowly, and a container is structurally not an act.
#
NEVER_ASSERTED_KINDS = frozenset({"hub"})

# **A work clears a lower bar than a creator, because the same strength means
# more evidence.** A creator accumulates across everything they touch — Bach is
# on 417 mappings — while a work is attested only by the songs that belong to
# it, and an album is one work and a dozen artists. Judging both at 0.35 asks a
# cast recording to be as well evidenced as a composer.
#
# **Set from the owner's judgement on their own rows, which is the only thing
# that could set it.** They were asked about three works and answered all three:
# *"Footloose is real"* (0.266, seven mappings), *"do not include Re:Zero"*
# (0.047, one), and — shown the result of the first cut — *"BanG Dream
# shouldn't be there"* (0.237, six).
#
# It went in at 0.20 first, deliberately below both Footloose and BanG Dream!,
# on the grounds that seven mappings against six is not a difference this scale
# can resolve and that splitting them would be fitting a constant to a single
# data point. That was right as far as it went: what was missing was a label on
# the second row, not a finer threshold. With both judged, 0.25 separates two
# *labelled* points rather than guessing between two unlabelled ones.
#
# 0.25 is a total weight of 2.0 — on these actions, five or six songs from the
# same work. It excludes the four-mapping cluster (Bleach, Thousand-Year Blood
# War, MyGO), where a franchise starts looking like one soundtrack somebody
# played, and `work:re_zero` at 0.047 by a wide margin.
#
# **One library and one reviewer, so this is a judgement rather than a
# measurement.** The next library is what would make it either.
ELIGIBLE_STRENGTH_BY_KIND = {"work": 0.25}

# **A bare decade, which is a different argument from the hub above.**
#
# Eras were deliberately kept assertable, on the owner's reading that they are
# the point: *"if he/she listens specifically to 80s German music, it would be a
# strong personality"*. That reading stands and this implements it rather than
# reversing it — **"80s German music" is a decade crossed with a language, not a
# decade.** The composite did not exist then, so the era had to carry it alone.
#
# What a bare decade actually carries was then measured on the owner's library:
# `era:1970s` at 0.403 rested on ABBA, Stevie Wonder, Frankie Kao's 姑娘的酒渦
# and Fritz Kreisler — anglophone pop, Mandopop and a violin recital. Three
# unrelated worlds under one claim, and 1970s British pop and 1970s Cantopop are
# not the same fact about a person. So the decade is the axis and `scene:*` is
# the claim, exactly as `sphere:*` remains assertable on its own: what language
# somebody listens in does differ between two people, and a decade alone barely
# does.
#
# **By key prefix rather than by kind**, because `era:`, `sphere:` and `scene:`
# are all `concept_kind = 'topic'` — the kind cannot separate the axis from the
# claim, and giving eras a kind of their own would rewrite thirteen concepts
# that six migrations already reference.
NEVER_ASSERTED_KEY_PREFIXES = ("era:",)


# **Aggregated in SQL rather than in Python.** 12,017 mappings across ~340
# concepts is small, but pulling them into the Lambda to group them would put
# somebody's whole library in memory for arithmetic Postgres does better — and
# the weights are already columns.
#
# `evidence_weight` and `recency_weight` are what the resolver stored per
# mapping; `default_reliability` and the per-action weight come from
# `semantic_private.sources`, which is authored data and not this file's
# business to invent.
# **A rejection is evidence about which concept the row was about.**
#
# The owner's model: liking a song admits three readings — the singer and the
# song, the singer only, the song only. Striking off the singer eliminates the
# first two, so what remains must be carried by whatever else the row names.
# It is the classical composer/performer/work dilemma with a pop name on it,
# and `CLASSICAL_PERFORMER_MIN_ALBUMS` already solves one corner of it.
#
# **The schema had already named this and nothing acted on it.** A suppression
# is written `label_semantics = 'ambiguous_rejection'`, against
# `explicit_confirmation` for a confirm — the vocabulary says outright that a
# rejection does not tell you *which* reading it was. Redistributing the
# evidence among the concepts that shared the row is disambiguating that. It is
# **not** a concept-level negative, which the contract forbids: nothing here
# asserts that the person dislikes the struck-off concept, only that the rows
# are better explained by something else on them.
#
# **The rule is "a different named role on the same row", and the data taught
# each half of that.** Cynthia Erivo's rows also carry Ariana Grande, Idina
# Menzel, Kristin Chenoweth and the Wicked Movie Cast — so boosting every
# co-occurring name would let striking off one cast member promote the other
# five, who are in exactly the same ambiguous position. Hence *different* role.
# The Berlin Philharmonic's rows carry **no work at all** — 108 creator
# mappings, zero `source_work` — so in classical the gainer is the composer,
# which is why this is written in the resolver's *roles* rather than in
# `concept_kind`.
#
# And it is symmetric because a real suppression demanded it: the first one
# anybody made was **Frank Wildhorn, who has no `creator` mappings at all** —
# he is the composer of *Jekyll & Hyde*. A creator-only rule did nothing for
# him. Striking off the writer says the same kind of thing as striking off the
# singer, so the performers and the work gain instead.
#
# **And genre, era, scene and sphere are excluded.** "I don't like the singer"
# says nothing new about the genre, which the row already supported; raising it
# would count one fact twice.
#
# **Conservation rather than a constant.** The freed weight is exactly what the
# suppressed concept was drawing from those rows, redistributed in proportion to
# what each recipient already rests on them. Measured on the real library:
# Erivo frees 4.247 and Wicked stands at 9.580, so Wicked rises to about 0.66
# from 0.615; the Berlin Philharmonic frees 13.894 across Beethoven at 13.99 and
# Mahler at 13.84. A multiplier would have needed a number nobody measured; this
# needs none, and says something truer — the listening did not change, only the
# account of it.
SUPPRESSION_TRANSFER = """
with weighted as (
  select m.concept_id, m.observation_id,
         m.evidence_path -> 0 ->> 'role' as role,
         m.evidence_weight * m.recency_weight * s.default_reliability
           * coalesce((s.action_weights ->> o.action_type)::double precision, 0.0) as w
    from semantic_private.observation_mappings m
    join semantic_private.observations o on o.id = m.observation_id
    join semantic_private.sources s on s.source_code = o.source_code
   where m.semantic_run_id = %(run)s
     and m.user_id = %(user_id)s
     and m.mapping_state = 'accepted'
), suppressed as (
  select a.concept_id
    from semantic_private.assertion_preferences p
    join semantic_private.user_assertions a on a.id = p.assertion_id
   where p.user_id = %(user_id)s
     and a.user_id = %(user_id)s
     and p.display_state = 'suppressed'
     and a.concept_id is not null
), freed as (
  -- Per row *and per role*: a row whose performer was struck off frees the
  -- performer's weight, and one whose composer was frees the composer's. The
  -- role is carried through so recipients can exclude it.
  select w.observation_id, w.role as freed_role, sum(w.w) as amount
    from weighted w
    join suppressed s on s.concept_id = w.concept_id
   where w.role in ('creator', 'composer', 'source_work')
   group by w.observation_id, w.role
), recipients as (
  select w.observation_id, w.role, w.concept_id, w.w
    from weighted w
   where w.role in ('creator', 'composer', 'source_work')
     and w.concept_id not in (select concept_id from suppressed)
), shares as (
  -- The window cannot sit inside the aggregate below, so the share per row is
  -- computed first. The denominator is every recipient of a *different* role on
  -- the same row, which is what makes the split conserve the freed weight.
  select r.concept_id,
         f.amount * r.w
           / sum(r.w) over (partition by r.observation_id, f.freed_role) as share
    from recipients r
    join freed f
      on f.observation_id = r.observation_id
     and f.freed_role <> r.role
)
select concept_id, sum(share) as extra_weight
  from shares
 group by concept_id
"""

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

# **For a long time the comment above described something the code could not do.**
# The eligibility test sat *before* the lookup — `if state != "eligible":
# continue` — so `UPDATE_ASSERTION` was only ever reached with `state`
# `eligible`, and an assertion that stopped clearing the bar simply kept
# standing. Found by changing the scorer so hubs assert nothing, deploying it,
# re-scoring, and watching `hub:music`, `hub:film_video` and
# `hub:ideas_learning` come back `eligible` from a run that had not touched
# them. The scorer could add a claim and could not withdraw one.
#
# Two ways a claim stops holding, and they need two statements because the
# second concept never reaches the loop at all:
#
#   - **Scored and no longer eligible** — the strength fell, or the kind is one
#     that is never asserted. Demoted inside the loop.
#   - **Not scored at all** — the ontology dropped the concept, a ban removed
#     every mapping, the source was disconnected. There is no iteration to hang
#     a demotion on, so it is a sweep after the loop.
#
# **`assertion_origin = 'inferred'` on both.** A declared assertion is something
# a person said about themselves, and a scorer that could retire one would let
# an absence of evidence overrule a statement.
DEMOTE_ASSERTION = """
update semantic_private.user_assertions
set machine_state = 'inactive', updated_at = now()
where user_id = %(user_id)s and predicate_key = %(predicate)s
  and concept_id = %(concept)s
  and assertion_origin = 'inferred' and machine_state <> 'inactive'
"""

DEMOTE_UNSCORED_ASSERTIONS = """
update semantic_private.user_assertions
set machine_state = 'inactive', updated_at = now()
where user_id = %(user_id)s and predicate_key = %(predicate)s
  and assertion_origin = 'inferred' and machine_state <> 'inactive'
  and not (concept_id = any(%(scored)s::uuid[]))
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
        "demoted": 0,
    }
    scored_concepts: list[str] = []

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

    # The weight freed by suppressed creators, already apportioned to the
    # composers and works that shared their rows. Fetched separately rather than
    # folded into `AGGREGATE` so the base scoring query stays the thing it has
    # always been, and so a run with no suppressions does no extra arithmetic.
    with connection.cursor() as cursor:
        cursor.execute(SUPPRESSION_TRANSFER, {"run": run_id, "user_id": user_id})
        transferred = {
            str(row["concept_id"]): float(row["extra_weight"])
            for row in cursor.fetchall()
        }
    counts["transferred_concepts"] = len(transferred)

    for agg in aggregates:
        concept_id = str(agg["concept_id"])
        label = labels.get(concept_id, {})

        # **The transfer is added before saturation, not after.** Saturation is
        # what makes a strength comparable between people, and adding to the
        # output of a curve that is nearly flat at the top would give a large
        # transfer almost no effect on a well-evidenced concept and a small one
        # a large effect on a weak one — the opposite of what the evidence says.
        # It is the same arithmetic that made a flat 0.3 performer weight
        # useless: the curve, not the constant, decides what a change is worth.
        transfer = transferred.get(concept_id, 0.0)
        strength = _saturate(float(agg["total_weight"]) + transfer, HALF_WEIGHT)
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
            # Recorded whenever it is non-zero, because a score that moved for a
            # reason nobody can see is the thing an explanation exists to stop.
            **({"transferred_from_suppressed": round(transfer, 4)} if transfer else {}),
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
        scored_concepts.append(concept_id)

        kind = label.get("concept_kind")
        key = label.get("concept_key") or ""
        if kind in NEVER_ASSERTED_KINDS or key.startswith(NEVER_ASSERTED_KEY_PREFIXES):
            # Counted rather than skipped silently: a kind quietly asserting
            # nothing is indistinguishable from a kind nothing ever scored.
            counts["container_kind"] = counts.get("container_kind", 0) + 1
            state = "candidate"
        else:
            bar = ELIGIBLE_STRENGTH_BY_KIND.get(kind, ELIGIBLE_STRENGTH)
            state = "eligible" if strength >= bar else "candidate"
        counts[state] += 1
        if state != "eligible":
            # Scored and inspectable, asserting nothing. Promote narrowly — and
            # withdraw anything this concept was asserting before, since it no
            # longer clears the bar it once cleared.
            with connection.cursor() as cursor:
                cursor.execute(DEMOTE_ASSERTION, {
                    "user_id": user_id, "predicate": AFFINITY_PREDICATE,
                    "concept": concept_id,
                })
                counts["demoted"] += cursor.rowcount
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
        # Batched for the same reason the mappings are: one concept can rest on
        # thousands of mappings, and a round trip each turns an explanation into
        # a timeout.
        evidence_rows = []
        for item in evidence:
            evidence_rows.append({
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
        if evidence_rows:
            with connection.cursor() as cursor:
                cursor.executemany(INSERT_EVIDENCE, evidence_rows)
            counts["evidence_rows"] += len(evidence_rows)

    # **The sweep, and its guard is the whole of its safety.** A run that scored
    # nothing has learned nothing, and running this against an empty
    # `scored_concepts` would retire every claim the person has — a failed
    # resolver, a disconnected source or an empty ontology version would read as
    # somebody who likes nothing. `score_user` already returns early when a run
    # mapped nothing at all (that path never reaches here); this covers the
    # other shape, where the loop ran and produced no scores.
    if scored_concepts:
        with connection.cursor() as cursor:
            cursor.execute(DEMOTE_UNSCORED_ASSERTIONS, {
                "user_id": user_id, "predicate": AFFINITY_PREDICATE,
                "scored": scored_concepts,
            })
            counts["demoted"] += cursor.rowcount

    return counts
