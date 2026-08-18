"""The candidate overlay's eight jobs.

`0203` created the tables and `0205` gave them tenancy and idempotency; nothing
wrote to them. These are the writers.

## The lane these run in

`compiled_semantic_contract_v1.json` declares `initial_mode: exact_only` and
`qwen_overlay: disabled_until_all_deploy_gates_pass`, and the specification says
what that leaves: *"resolve stable identifiers and exact aliases before any model
call."* **The exact lane is resolution, not extraction** — so seven of these
eight run today, against the 73,126 mentions the legacy resolver has already
mined, with no model, no gateway and no network call of any kind.

`extract_mentions` is the exception and is the model lane by definition: the
workbook keys its idempotency on `model_version+prompt_version+grammar_version`.
It ships declining, which is a complete implementation of what it must do while
the overlay is off — not a stub. Registering a job type whose handler is absent
is worse than not registering it, because the job is claimed, found handler-less
and marked `dead` with no retry.

## What they share

- **Bounded work.** Every handler caps what one invocation touches. EventBridge
  drains the queue every two minutes and a Lambda has fifteen; a job that tried
  to resolve one account's 73,126 mentions in a single claim would time out and
  be retried from the start, forever.
- **Idempotent by constraint, not by care.** `0205`'s
  `mention_resolutions_one_per_route`, `review_items_one_card_per_epoch` and the
  partial unique indexes on `user_term_candidates` mean a re-run inserts nothing
  new. Every insert here is `on conflict do nothing` and means it.
- **Counts in receipts, never text.** `worker_job_result_is_safe_v03` refuses
  anything else, and a title in a receipt would be a title in a log.
- **The contract decides, not these constants.** Roles, predicates, families and
  the overlay switch are read from `written_ontology.semantic_contract`.
"""

from __future__ import annotations

from typing import Any

from written_ontology.semantic_contract import load as load_contract

#: One invocation's ceiling. Chosen so the slowest of these — resolution, which
#: joins each mention against the published label set — stays far inside a
#: fifteen-minute Lambda on the largest account in the database, and so that a
#: partial pass leaves a queue that the next tick continues rather than repeats.
RESOLVE_BATCH = 2000
CANDIDATE_BATCH = 5000
REVIEW_PAGE = 24

#: The route these jobs write. A route is *how* a resolution was reached, and it
#: is recorded per row because feedback is attributed to it: `aggregate_feedback`
#: cannot say which route is producing bad terms if every row claims the same
#: one. `exact_label` is the only route the exact lane has.
EXACT_ROUTE = "exact_label"

#: Everything the exact lane can claim about somebody. A resolved mention says a
#: term appeared in their library, which is an affinity and is not a claim that
#: they *do* the thing — `0200` put participation and spectating behind evidence
#: that says so, and a label match says neither.
EXACT_PREDICATE = "affinity_to"

#: The bar `score.py` uses for an assertion. Reused rather than reinvented: a
#: candidate below it is real evidence that has not earned a claim, which is
#: what `secondary` means.
ELIGIBILITY = 0.35

#: `strength` saturates as `w/(w+6)` in the scorer, and the same curve is used
#: here so a candidate's score and the assertion it may become are on one scale.
#: A hard cap would tie every strong concept at 1.0.
SATURATION = 6.0


def _published_version(cursor) -> str | None:
    cursor.execute("select id from ontology.versions where status = 'published'")
    row = cursor.fetchone()
    return row["id"] if row else None


# ---------------------------------------------------------------------------
# 1. extract_mentions — the model lane
# ---------------------------------------------------------------------------

def extract_mentions(job) -> dict[str, Any]:
    """Propose mentions with the model. Declines while the overlay is off.

    **This is the whole handler and it is not a placeholder.** The contract says
    the overlay is disabled until every deploy gate passes, and the honest
    behaviour of a model job in that state is to decline and say so. The
    alternative — not registering the job type until the gateway exists — means
    the type cannot be enqueued, and the day the overlay is enabled becomes the
    day a migration, a handler and a gateway all ship together.

    The switch is read from the compiled contract rather than an environment
    variable, so turning the lane on is a contract change a deploy validator
    compares against what it attested to.
    """
    contract = load_contract()
    mode = contract.model_lane_mode

    # **Branch on the mode, not on a boolean.** The old test asked whether the
    # contract string contained "disabled", which fails open: `evaluation`
    # contains no such word and would have fallen straight through to the
    # `NotImplementedError` below. The four modes are exhaustive and unknown
    # values already raised in `model_lane_mode`, so there is no `else` that
    # silently proceeds.
    if mode == "off":
        return {
            "status": "no_op",
            "abstained": True,
            "item_count": 0,
        }

    # `evaluation` and `shadow` both call the model; they differ in what may be
    # written, which is enforced where the writes happen rather than here — a
    # handler that decided its own permissions would be a second copy of the
    # rule. What is common to both is that neither can run without a gateway.
    raise NotImplementedError(
        f"the qwen extraction lane is in mode {mode!r} and its gateway has not "
        "shipped"
    )


# ---------------------------------------------------------------------------
# 2. resolve_mention — the exact lane
# ---------------------------------------------------------------------------

#: **One statement, not a loop.** Resolving row by row would be 73,126 round
#: trips for one account, and the decision — how many distinct concepts carry
#: this normalized label at the published version — is a join the database is
#: better at than we are.
#:
#: The three outcomes are the contract's own: exactly one match is
#: `resolved_existing`, several is `ambiguous` (and asserts nothing, because a
#: name that means two things means neither), and none is `unresolved`, which is
#: the row `build_candidate_overlay` ignores and a later mint may rescue.
RESOLVE = """
with published as (
  select id from ontology.versions where status = 'published'
),
pending as (
  select m.id, m.user_id, m.normalized_text
    from semantic_private.observation_mentions m
    join semantic_private.observations o
      on o.id = m.observation_id and o.user_id = m.user_id
   where m.user_id = %(user_id)s
     and o.lifecycle_state = 'active'
     -- **Eligibility, before resolution rather than after.** An observation the
     -- scorer weighs at zero — an Apple `recommendation`, which is Apple's
     -- suggestion and not the person's act — is not a semantic opportunity, and
     -- counting it inflates every coverage number computed downstream. 1,080 of
     -- one account's 12,821 active mentions sat behind this line.
     and o.action_weight > 0
     and length(btrim(m.normalized_text)) > 0
     -- **Judged against the vocabulary now published, not merely judged.** The
     -- old condition skipped any mention that already had a row for this
     -- resolver and route, so a mention recorded `unresolved` could never be
     -- reconsidered — the record of the failure was what prevented the retry,
     -- and publishing new vocabulary rescued nothing. Keying on the evaluated
     -- version means a new ontology makes every negative verdict pending again,
     -- once, by itself.
     and not exists (
       select 1 from semantic_private.mention_resolutions r
        where r.mention_id = m.id
          and r.route_id = %(route)s
          and r.evaluated_ontology_version_id = (select id from published))
   order by m.id
   limit %(batch)s
),
matched as (
  select p.id, p.user_id, v.id as ontology_version_id,
         x.distinct_concepts, x.concept_id
    from pending p
   cross join published v
   left join lateral (
     select count(distinct l.concept_id) as distinct_concepts,
            -- **`min(uuid)` does not exist.** Postgres has no ordering aggregate
            -- for uuid, and the cast through text is what `0190` already does
            -- for the same reason. It is only ever read when the count is 1, so
            -- which uuid "min" picks is not a decision — there is one.
            min(l.concept_id::text)::uuid as concept_id
       from ontology.concept_labels l
       join ontology.concept_revisions cr
         on cr.ontology_version_id = l.ontology_version_id
        and cr.concept_id = l.concept_id
      where l.ontology_version_id = v.id
        and l.status = 'active'
        and cr.status = 'active'
        and l.normalized_label = p.normalized_text
   ) x on true
)
insert into semantic_private.mention_resolutions
  (user_id, mention_id, resolution, ontology_version_id, concept_id,
   route_id, resolver_version, confidence, abstention_reason,
   evaluated_ontology_version_id)
select m.user_id, m.id,
       case when m.distinct_concepts = 1 then 'resolved_existing'
            when m.distinct_concepts > 1 then 'ambiguous'
            else 'unresolved' end,
       case when m.distinct_concepts = 1 then m.ontology_version_id end,
       case when m.distinct_concepts = 1 then m.concept_id end,
       %(route)s, %(resolver_version)s,
       case when m.distinct_concepts = 1 then 1.0 else 0.0 end,
       case when m.distinct_concepts > 1 then 'ambiguous'
            when coalesce(m.distinct_concepts, 0) = 0 then 'no_durable_subject' end,
       -- Set on every row, including the negatives. `ontology_version_id` above
       -- is half a foreign key to `concept_revisions` and means where the
       -- concept lives; it is null exactly for the rows that need revisiting.
       m.ontology_version_id
  from matched m
on conflict do nothing
"""

#: **The current verdict per mention, never every historical one.** A mention
#: resolved under today's vocabulary still carries yesterday's `unresolved` row,
#: and a tally over the table would report it as both.
RESOLVE_TALLY = """
select resolution, count(*) as rows
  from semantic_private.current_mention_resolutions
 where user_id = %(user_id)s and route_id = %(route)s
 group by resolution
"""

REMAINING = """
select count(*) as remaining
  from semantic_private.observation_mentions m
  join semantic_private.observations o
    on o.id = m.observation_id and o.user_id = m.user_id
 where m.user_id = %(user_id)s
   and o.lifecycle_state = 'active'
   and o.action_weight > 0
   and length(btrim(m.normalized_text)) > 0
   and not exists (
     select 1 from semantic_private.mention_resolutions r
      where r.mention_id = m.id
        and r.route_id = %(route)s
        and r.evaluated_ontology_version_id
            = (select id from ontology.versions where status = 'published'))
"""


#: **The provisional lane lives in SQL, and this is the whole of the reason.**
#: Its proof has to seed rows and read them back, which a contract file can do
#: and a Python string constant cannot — `apply_feedback` is the standing example
#: of a statement no test can reach. `0234` owns the body; this calls it.
PROVISION = """
select minted, provisioned
  from semantic_private.provision_exact_misses(%(user_id)s::uuid, %(version)s::uuid)
"""


def resolve_mention(job) -> dict[str, Any]:
    """Resolve a bounded batch of one account's mentions against exact labels.

    No model, no network. A mention resolves when exactly one active concept at
    the published ontology version carries its normalized label — which is what
    *"resolve stable identifiers and exact aliases before any model call"* asks
    for, and is the whole of the exact lane.

    **`normalized_text` is compared, not `mention_text`.** The stored value was
    produced by `normalize_text`, and `concept_labels.normalized_label` by the
    same function; SQL cannot reproduce that fold, so comparing the raw surfaces
    would silently miss every accented, cased or width-variant name.
    """
    import psycopg
    from psycopg.rows import dict_row

    from handler import database_url  # noqa: PLC0415 - Lambda flat layout

    payload = job.payload
    arguments = {
        "user_id": payload["user_id"],
        "resolver_version": payload["resolver_version"],
        "route": EXACT_ROUTE,
        "batch": RESOLVE_BATCH,
    }

    with psycopg.connect(
        database_url(), row_factory=dict_row, prepare_threshold=None
    ) as connection:
        with connection.cursor() as cursor:
            published = _published_version(cursor)
            if published is None:
                # Nothing to resolve against. A run that wrote `unresolved` for
                # every mention because the ontology was momentarily absent
                # would be indistinguishable from a library of unknown names.
                return {"status": "no_op", "abstained": True, "item_count": 0}

            cursor.execute(RESOLVE, arguments)
            written = cursor.rowcount

            # **The fallback runs inside this job, after the exact verdict for
            # the same bounded batch exists.** A separate stage would have to
            # decide for itself whether the exact lane had finished, and its
            # armer would need a route-aware work test to avoid a provisional
            # row satisfying the exact route's. One job, one transaction, and
            # the ordering is guaranteed rather than scheduled.
            cursor.execute(
                PROVISION, {"user_id": arguments["user_id"], "version": published}
            )
            fallback = cursor.fetchone()
            minted = fallback["minted"]
            provisioned = fallback["provisioned"]

            cursor.execute(RESOLVE_TALLY, arguments)
            tally = {row["resolution"]: row["rows"] for row in cursor.fetchall()}

            cursor.execute(REMAINING, arguments)
            remaining = cursor.fetchone()["remaining"]
        connection.commit()

    return {
        "status": "succeeded" if remaining == 0 else "partial",
        "item_count": written,
        "resolved_count": tally.get("resolved_existing", 0),
        "ambiguous_count": tally.get("ambiguous", 0),
        "unresolved_count": tally.get("unresolved", 0),
        "provisional_minted": minted,
        "provisional_count": provisioned,
        "remaining_count": remaining,
    }


# ---------------------------------------------------------------------------
# 3. build_candidate_overlay — resolutions become candidates
# ---------------------------------------------------------------------------

#: **`on conflict` names the partial index's predicate**, because that is how
#: Postgres infers which index to check. Omitting it raises rather than choosing
#: wrongly, which is the right failure but only if the statement is written to
#: expect it.
BUILD_CANDIDATES = """
insert into semantic_private.user_term_candidates
  (user_id, concept_id, user_facing_predicate, confidence_tier, primary_route_id)
select distinct r.user_id, r.concept_id, %(predicate)s, 'secondary', %(route)s
  from semantic_private.current_mention_resolutions r
 where r.user_id = %(user_id)s
   and r.resolution = 'resolved_existing'
   and r.concept_id is not null
on conflict (user_id, concept_id, user_facing_predicate)
  where lifecycle_state = 'active' and concept_id is not null
do nothing
"""

#: Evidence, one row per (candidate, observation, route). The unique key is what
#: makes a second pass free rather than doubling every contribution.
#:
#: **`contribution` is the mention's own evidence weight, bounded.** The column
#: is capped at 1.0 by check constraint, and a repeated fetch or a same-album
#: repost must not accumulate — a cap enforced only in the aggregator is a cap
#: one query can forget.
LINK_EVIDENCE = """
insert into semantic_private.candidate_support_links
  (user_id, candidate_id, observation_id, mention_resolution_id, route_id,
   evidence_family_key, contribution)
select c.user_id, c.id, m.observation_id, r.id, %(route)s,
       coalesce(m.type_hint, 'unspecified'),
       least(greatest(m.evidence_weight * m.recency_weight, 0.0), 1.0)
  from semantic_private.current_mention_resolutions r
  join semantic_private.observation_mentions m
    on m.id = r.mention_id and m.user_id = r.user_id
  join semantic_private.user_term_candidates c
    on c.user_id = r.user_id
   and c.concept_id = r.concept_id
   and c.user_facing_predicate = %(predicate)s
   and c.lifecycle_state = 'active'
 where r.user_id = %(user_id)s
   and r.resolution = 'resolved_existing'
   and r.concept_id is not null
   -- **The anti-join is what makes the limit a page rather than a wall.**
   -- Without it every pass selects the same arbitrary 5,000 rows, conflicts
   -- them all away, and evidence beyond the first page is unreachable — the
   -- limit stops being a batch size and becomes a ceiling on how much of
   -- somebody's library can ever support a term.
   and not exists (
     select 1 from semantic_private.candidate_support_links l
      where l.candidate_id = c.id
        and l.observation_id = m.observation_id
        and l.route_id = %(route)s)
 -- And stable ordering, so successive pages are successive rather than a
 -- reshuffle of whatever the planner returned.
 order by r.id
 limit %(batch)s
on conflict (candidate_id, observation_id, route_id) do nothing
"""


#: The candidate and evidence half of the same lane, for the same reason.
BUILD_PROVISIONAL = """
select candidates, links
  from semantic_private.build_provisional_candidates(
         %(user_id)s::uuid, %(predicate)s, %(batch)s::integer)
"""


def build_candidate_overlay(job) -> dict[str, Any]:
    """Turn resolved mentions into candidate terms and the evidence under them.

    A candidate is one concept a person might be said to have an affinity for,
    and it is *not* an assertion: nothing here writes `user_assertions`, nothing
    reaches a surface, and `api.list_assertions` cannot see any of it. That
    separation is the point of an overlay — a claim has to survive scoring and
    a review before it becomes something said about somebody.

    Candidates arrive `secondary`; `aggregate_term_candidates` decides tier from
    the evidence rather than this job asserting one on the way in.
    """
    import psycopg
    from psycopg.rows import dict_row

    from handler import database_url  # noqa: PLC0415

    arguments = {
        "user_id": job.payload["user_id"],
        "route": EXACT_ROUTE,
        "predicate": EXACT_PREDICATE,
        "batch": CANDIDATE_BATCH,
    }

    with psycopg.connect(
        database_url(), row_factory=dict_row, prepare_threshold=None
    ) as connection:
        with connection.cursor() as cursor:
            cursor.execute(BUILD_CANDIDATES, arguments)
            candidates = cursor.rowcount
            cursor.execute(LINK_EVIDENCE, arguments)
            links = cursor.rowcount

            cursor.execute(BUILD_PROVISIONAL, arguments)
            provisional = cursor.fetchone()
            candidates += provisional["candidates"]
            links += provisional["links"]
        connection.commit()

    return {
        "status": "succeeded",
        "item_count": candidates,
        # **`changed` is a boolean here, not a count.**
        # `worker_job_result_is_safe_v03` types it, and a receipt that
        # failed that check would fail the *job*, after the work had
        # already committed.
        "changed": bool(candidates or links),
    }


# ---------------------------------------------------------------------------
# 4. aggregate_term_candidates — scoring
# ---------------------------------------------------------------------------

#: **The same saturation the scorer uses**, so a candidate's number and the
#: assertion it may become are on one scale and a reviewer comparing them is
#: comparing like with like.
#:
#: Tier is read off the bar rather than invented: at or above `0.35` the
#: evidence would clear what an assertion needs, which is `inferred`; below it
#: the evidence is real and has not earned a claim, which is `secondary`.
#: `direct` is reserved for something the person said, and nothing in the exact
#: lane can produce that.
AGGREGATE = """
with weighed as (
  select l.candidate_id,
         sum(l.contribution) as total,
         count(*) as evidence_rows
    from semantic_private.candidate_support_links l
   where l.user_id = %(user_id)s
   group by l.candidate_id
)
update semantic_private.user_term_candidates c
   set aggregate_score = w.total / (w.total + %(saturation)s),
       confidence_tier = case
         when w.total / (w.total + %(saturation)s) >= %(bar)s then 'inferred'
         else 'secondary' end,
       updated_at = now()
  from weighed w
 where c.id = w.candidate_id
   and c.user_id = %(user_id)s
   and c.lifecycle_state = 'active'
   and (c.aggregate_score is distinct from w.total / (w.total + %(saturation)s)
        or c.confidence_tier is distinct from case
             when w.total / (w.total + %(saturation)s) >= %(bar)s then 'inferred'
             else 'secondary' end)
"""

TIER_TALLY = """
select confidence_tier, count(*) as rows
  from semantic_private.user_term_candidates
 where user_id = %(user_id)s and lifecycle_state = 'active'
 group by confidence_tier
"""


def aggregate_term_candidates(job) -> dict[str, Any]:
    """Score every active candidate from the evidence beneath it.

    **Only rows whose score or tier actually moves are written.** An update that
    touched every candidate each pass would churn `updated_at` on thousands of
    rows for no change, and make "when did this term last move" unanswerable —
    which is the question a reviewer asks first.
    """
    import psycopg
    from psycopg.rows import dict_row

    from handler import database_url  # noqa: PLC0415

    arguments = {
        "user_id": job.payload["user_id"],
        "saturation": SATURATION,
        "bar": ELIGIBILITY,
    }

    with psycopg.connect(
        database_url(), row_factory=dict_row, prepare_threshold=None
    ) as connection:
        with connection.cursor() as cursor:
            cursor.execute(AGGREGATE, arguments)
            moved = cursor.rowcount
            cursor.execute(TIER_TALLY, {"user_id": arguments["user_id"]})
            tiers = {row["confidence_tier"]: row["rows"] for row in cursor.fetchall()}
        connection.commit()

    return {
        "status": "succeeded",
        "changed": bool(moved),
        "item_count": sum(tiers.values()),
        "inferred_count": tiers.get("inferred", 0),
        "secondary_count": tiers.get("secondary", 0),
    }


# ---------------------------------------------------------------------------
# 5. build_review_items — what a person is shown
# ---------------------------------------------------------------------------

#: **Suppressed terms are excluded here and not at draw time.** A strike is a
#: person saying "not this", and the honest place to honour it is before the
#: card is built — a review item that exists and is filtered later still appears
#: in the exposure history as something they were shown.
BUILD_REVIEW = """
with ranked as (
  select c.id, c.user_id, c.confidence_tier, c.aggregate_score, c.primary_route_id,
         row_number() over (order by c.aggregate_score desc, c.id) - 1 as rank
    from semantic_private.user_term_candidates c
   where c.user_id = %(user_id)s
     and c.lifecycle_state = 'active'
     -- **Already on this epoch's page, so not a candidate for it again.**
     -- Without this the builder re-selects the same highest-ranked 24 every
     -- pass, conflicts them away, and candidate 25 is unreachable for the life
     -- of the epoch.
     and not exists (
       select 1 from semantic_private.review_items i
        where i.candidate_id = c.id and i.review_epoch = %(epoch)s)
     and not exists (
       select 1 from semantic_private.user_term_suppressions s
        where s.user_id = c.user_id
          and s.active
          and s.user_facing_predicate = c.user_facing_predicate
          and (s.concept_id = c.concept_id
               or s.provisional_entity_id = c.provisional_entity_id))
   order by c.aggregate_score desc, c.id
   limit %(page)s
)
insert into semantic_private.review_items
  (user_id, candidate_id, review_epoch, primary_route_id, confidence_tier,
   aggregate_score, rank, presentation_version)
select r.user_id, r.id, %(epoch)s, r.primary_route_id, r.confidence_tier,
       r.aggregate_score, r.rank, %(presentation)s
  from ranked r
on conflict (user_id, candidate_id, review_epoch) do nothing
"""

LINK_REVIEW_EVIDENCE = """
insert into semantic_private.review_item_evidence
  (review_item_id, user_id, support_link_id)
select i.id, i.user_id, l.id
  from semantic_private.review_items i
  join semantic_private.candidate_support_links l
    on l.candidate_id = i.candidate_id and l.user_id = i.user_id
 where i.user_id = %(user_id)s and i.review_epoch = %(epoch)s
on conflict do nothing
"""

LINK_REVIEW_ROUTES = """
insert into semantic_private.review_item_routes
  (review_item_id, user_id, route_id, is_primary)
select i.id, i.user_id, i.primary_route_id, true
  from semantic_private.review_items i
 where i.user_id = %(user_id)s and i.review_epoch = %(epoch)s
on conflict do nothing
"""


def build_review_items(job) -> dict[str, Any]:
    """Build one epoch's review page for a person.

    `review_items` is append-only by trigger, so this can be run twice and the
    second run writes nothing — `review_items_one_card_per_epoch` refuses the
    duplicate rather than the trigger having to.
    """
    import psycopg
    from psycopg.rows import dict_row

    from handler import database_url  # noqa: PLC0415

    contract = load_contract()
    arguments = {
        "user_id": job.payload["user_id"],
        "epoch": job.payload["review_epoch"],
        "page": REVIEW_PAGE,
        # The presentation is versioned so a feedback label stays interpretable:
        # "they struck this" means nothing except against the arrangement it was
        # struck in.
        "presentation": contract.versions["grammar"],
    }

    with psycopg.connect(
        database_url(), row_factory=dict_row, prepare_threshold=None
    ) as connection:
        with connection.cursor() as cursor:
            cursor.execute(BUILD_REVIEW, arguments)
            items = cursor.rowcount
            cursor.execute(LINK_REVIEW_ROUTES, arguments)
            cursor.execute(LINK_REVIEW_EVIDENCE, arguments)
            evidence = cursor.rowcount
        connection.commit()

    return {
        "status": "succeeded",
        "item_count": items,
        "changed": bool(items or evidence),
    }


# ---------------------------------------------------------------------------
# 6. apply_feedback — a person's answers take effect
# ---------------------------------------------------------------------------

#: A strike suppresses the term for that predicate. **`on conflict do nothing`
#: against the partial unique index**, so striking the same term twice is one
#: suppression rather than an error — a person tapping twice is not a conflict.
#:
#: **It selected both target columns and then threw the provisional half away.**
#: `and c.concept_id is not null` is exactly `and not provisional-backed`, the
#: schema's own single-term check making it so, and the conflict target named
#: only the concept index. A strike on a provisional-backed candidate produced no
#: suppression at all — silently, since the receipt counts rows.
#:
#: Two statements rather than one predicate, because the two partial indexes are
#: two arbiters and `on conflict` infers one at a time. Deleting the filter
#: without splitting the statement would turn a silent drop into a `23505` on the
#: second strike of the same provisional, which is worse only in that it is
#: louder.
SUPPRESS_CONCEPT = """
insert into semantic_private.user_term_suppressions
  (user_id, concept_id, provisional_entity_id, user_facing_predicate,
   source_review_item_id, source_review_epoch)
select e.user_id, c.concept_id, c.provisional_entity_id,
       c.user_facing_predicate, i.id, i.review_epoch
  from semantic_private.review_events e
  join semantic_private.review_items i on i.id = e.review_item_id
  join semantic_private.user_term_candidates c on c.id = i.candidate_id
 where e.user_id = %(user_id)s
   and e.action = 'strike_off'
   and c.concept_id is not null
on conflict (user_id, concept_id, user_facing_predicate)
  where active and concept_id is not null
do nothing
"""

SUPPRESS_PROVISIONAL = """
insert into semantic_private.user_term_suppressions
  (user_id, concept_id, provisional_entity_id, user_facing_predicate,
   source_review_item_id, source_review_epoch)
select e.user_id, c.concept_id, c.provisional_entity_id,
       c.user_facing_predicate, i.id, i.review_epoch
  from semantic_private.review_events e
  join semantic_private.review_items i on i.id = e.review_item_id
  join semantic_private.user_term_candidates c on c.id = i.candidate_id
 where e.user_id = %(user_id)s
   and e.action = 'strike_off'
   and c.provisional_entity_id is not null
on conflict (user_id, provisional_entity_id, user_facing_predicate)
  where active and provisional_entity_id is not null
do nothing
"""

#: A struck candidate is withdrawn, not deleted. The evidence under it stays —
#: what somebody declined to be described by is not evidence that the underlying
#: observation never happened.
#:
#: **Both identity columns, and the second one is not symmetry for its own sake.**
#: The schema forces exactly one of them non-null on each side, so for a
#: provisional-backed suppression meeting a provisional-backed candidate
#: `s.concept_id is not distinct from c.concept_id` reads `null is not distinct
#: from null`, which is true. With the lane holding one predicate that left
#: `user_id`, `active` and `lifecycle_state` as the only discriminators: **one
#: strike would have withdrawn every active provisional candidate that person
#: had.** `BUILD_REVIEW` a hundred lines above already gets this right with `=`,
#: which yields unknown on two nulls; the two statements disagreed.
#:
#: It is latent only because `SUPPRESS` never wrote a provisional row. Repairing
#: that alone would have armed this from the other side, which is why they are
#: one change.
WITHDRAW = """
update semantic_private.user_term_candidates c
   set lifecycle_state = 'withdrawn', updated_at = now()
  from semantic_private.user_term_suppressions s
 where c.user_id = %(user_id)s
   and s.user_id = c.user_id
   and s.active
   and s.user_facing_predicate = c.user_facing_predicate
   and s.concept_id is not distinct from c.concept_id
   and s.provisional_entity_id is not distinct from c.provisional_entity_id
   and c.lifecycle_state = 'active'
"""


def apply_feedback(job) -> dict[str, Any]:
    """Turn one person's review answers into suppressions.

    **Only `strike_off` acts.** `keep` and `confirm` are signal for ranking and
    change nothing about what is stored, and `edit` needs a corrected term that
    the exact lane has no way to mint yet — recorded, not acted on, which is
    better than acting on it wrongly.
    """
    import psycopg
    from psycopg.rows import dict_row

    from handler import database_url  # noqa: PLC0415

    arguments = {"user_id": job.payload["user_id"]}

    with psycopg.connect(
        database_url(), row_factory=dict_row, prepare_threshold=None
    ) as connection:
        with connection.cursor() as cursor:
            cursor.execute(SUPPRESS_CONCEPT, arguments)
            suppressed = cursor.rowcount
            cursor.execute(SUPPRESS_PROVISIONAL, arguments)
            suppressed += cursor.rowcount
            cursor.execute(WITHDRAW, arguments)
            withdrawn = cursor.rowcount
        connection.commit()

    return {
        "status": "succeeded",
        "item_count": suppressed,
        "changed": bool(suppressed or withdrawn),
    }


# ---------------------------------------------------------------------------
# 7. aggregate_feedback — how each route is doing
# ---------------------------------------------------------------------------

#: Keep and strike counts per route, across everybody. **A route rather than a
#: term**: the question this answers is which way of reaching a term produces
#: ones people accept, which is what decides whether a route is worth running.
ROUTE_STATS = """
select i.primary_route_id as route,
       count(*) filter (where e.action in ('keep', 'confirm')) as kept,
       count(*) filter (where e.action = 'strike_off') as struck,
       count(*) as answered
  from semantic_private.review_events e
  join semantic_private.review_items i on i.id = e.review_item_id
 group by i.primary_route_id
 order by answered desc
 limit 8
"""


def aggregate_feedback(job) -> dict[str, Any]:
    """Fleet-wide keep/strike rates per route.

    A system job: it names no user, and `worker_job_payload_is_valid_v03` allows
    that only where the queue row's `user_id` is null too.

    **It writes nothing.** Precision per route is a number to read before
    changing a route, and storing it would mean a table whose schema encodes
    which statistics matter — a decision worth making when there is enough
    feedback to make it. Today there is none, and the receipt says so.
    """
    import psycopg
    from psycopg.rows import dict_row

    from handler import database_url  # noqa: PLC0415

    with psycopg.connect(
        database_url(), row_factory=dict_row, prepare_threshold=None
    ) as connection:
        with connection.cursor() as cursor:
            cursor.execute(ROUTE_STATS)
            rows = cursor.fetchall()

    answered = sum(row["answered"] for row in rows)
    struck = sum(row["struck"] for row in rows)
    return {
        "status": "succeeded" if answered else "no_op",
        "item_count": answered,
        "changed": bool(rows),
        "struck_count": struck,
    }


# ---------------------------------------------------------------------------
# 8. evaluate_release — the gate report
# ---------------------------------------------------------------------------

#: Which evaluator reached a verdict. Bumped when what the job checks changes,
#: so two reports on one manifest are comparable rather than merely consecutive.
EVALUATION_REVISION = "release-eval-0.2.0"

#: **A verdict is appended, never overwritten.** This was a blind
#: `update ... set gate_report`, so every re-run destroyed the previous verdict
#: and the question *"did this release ever pass, and when did it stop"* had no
#: answer. `0235` makes the table append-only by trigger and revokes the column
#: privilege that allowed the overwrite.
RECORD_GATE = """
insert into ontology.release_gate_reports
  (release_manifest_id, evaluation_revision, environment, report)
values (%(release_manifest_id)s, %(evaluation_revision)s, %(environment)s,
        %(report)s::jsonb)
"""

#: **Every field the runtime attestation declares, and the query is built from
#: those keys.** It selected three columns and compared one, while reading a
#: fourth — `model_lane_mode` — that the select did not carry and the table did
#: not have, so that test was `failed` for every row that could ever exist. A
#: query written by hand beside a comparison written by hand is two lists, and
#: this is what happens to two lists.
#:
#: `0235` gives each of these a column. A key added to `attestation()` with no
#: column here raises at the start of the job rather than going uncompared.
ATTESTED_COLUMNS = (
    "compiled_contract_sha256",
    "workbook_sha256",
    "schema_sha256",
    "grammar_version",
    "prompt_version",
    "model_id",
    "model_revision",
    "gateway_revision",
    "model_lane_mode",
)

MANIFEST = f"""
select {', '.join(ATTESTED_COLUMNS)}, environment, promotion_decision
  from ontology.release_manifests
 where id = %(release_manifest_id)s
"""


def evaluate_release(job) -> dict[str, Any]:
    """Check a release manifest against the contract the worker is running.

    The one gate a *running* Lambda can answer that CI cannot: whether the
    contract this deployed bundle actually loaded is the one the manifest was
    recorded against. CI compares artifacts to each other; only this compares an
    artifact to what is in production.

    A mismatch is written into the report rather than raised. The job's purpose
    is to produce the report, and a job that dies instead of recording the
    failure it found leaves the manifest looking unevaluated.
    """
    import json

    import psycopg
    from psycopg.rows import dict_row

    from handler import database_url  # noqa: PLC0415

    contract = load_contract()
    manifest_id = job.payload["release_manifest_id"]

    # **A field the attestation declares and the manifest has no column for is a
    # field nothing compares.** Raised here rather than skipped, because the
    # failure this job exists to prevent is exactly a test that looks present and
    # cannot run.
    uncompared = sorted(set(contract.attestation()) - set(ATTESTED_COLUMNS))
    if uncompared:
        raise RuntimeError(
            f"the runtime attestation declares {uncompared} and the release "
            "manifest has no column for them; add the column before attesting"
        )

    with psycopg.connect(
        database_url(), row_factory=dict_row, prepare_threshold=None
    ) as connection:
        with connection.cursor() as cursor:
            cursor.execute(MANIFEST, {"release_manifest_id": manifest_id})
            manifest = cursor.fetchone()
            if manifest is None:
                return {"status": "no_op", "abstained": True, "item_count": 0}

            attested = contract.attestation()
            # One test per attested field, in the attestation's own order. The
            # **deployed mode must match what the manifest attested**, rather
            # than being required to be off unconditionally — the pre-`0230`
            # test could never pass once the lane ran at all, which made
            # `candidate_attestation` and `staging_e2e` unreachable: both
            # require the lane to have run, and the gate demanded it had not.
            tests = [
                {
                    "id": f"{field}_matches_manifest",
                    "status": "passed" if manifest[field] == value else "failed",
                }
                for field, value in attested.items()
            ]
            passed = all(test["status"] == "passed" for test in tests)
            report = {
                "schema_version": "semantic_gate_report_v1",
                "test_results": tests,
                # The verdict, stated once. It was derivable from the list and
                # the receipt derived something else.
                "all_required_tests_passed": passed,
                **attested,
            }
            cursor.execute(
                RECORD_GATE,
                {
                    "release_manifest_id": manifest_id,
                    "evaluation_revision": EVALUATION_REVISION,
                    "environment": manifest["environment"],
                    "report": json.dumps(report),
                },
            )
        connection.commit()

    return {
        "status": "succeeded",
        "item_count": len(report["test_results"]),
        # **`changed` means the release is attested**, which is what a caller
        # reading a receipt wants to know. It was the contract-hash comparison
        # alone, so this said `true` over a report whose second test read
        # `failed` — a green receipt covering a red gate, which is worse than a
        # red one.
        "changed": passed,
    }
