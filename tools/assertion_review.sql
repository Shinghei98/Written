-- Reviewing assertions, and recording verdicts that survive a re-score.
--
-- Run in the dashboard SQL editor. Replace the id in `subject`.
--
-- **Why the SQL editor and not a tool.** `semantic_private` is reachable by
-- exactly three identities: `semantic_ingestor` (one function, no tables),
-- `semantic_worker` (an enumerated grant list), and the owner. **`service_role`
-- has no access to a single table in it** — checked, not assumed, and stronger
-- than this file previously implied. So a script holding `SUPABASE_SECRET_KEY`
-- cannot read any of this, and granting it in order to write a review tool
-- would widen the exact posture the semantic schema exists to hold. The
-- integration plan names that as a failure condition in its own words: *"an
-- adapted grant broadens access"*.
--
-- If a standing reviewer identity is ever wanted, `0052`'s `semantic_ingestor`
-- is the pattern — a role with execute on two functions and insert on one
-- table, and nothing else. Today there is one reviewer and they own the
-- database, so that role would be ceremony.
--
-- ## Why a verdict attaches to the assertion
--
-- Phase 2's outputs moved three times in the hour it closed: the assertion set
-- went 81 → 53 → 65 in one afternoon as the hub rule, the performer rule and
-- the era/sphere work landed. **A review keyed to a run is stale before it is
-- finished.** `user_assertions` rows are stable, though — keyed on
-- `(user, predicate, concept)`, and a re-score updates `machine_state` and adds
-- an `assertion_score_versions` row rather than replacing the assertion. So a
-- verdict on an assertion id outlives any number of re-scores.
--
-- `assertions_awaiting_review` therefore returns two populations and nothing
-- else: never reviewed, and reviewed but the machine state has changed since.
-- **A strength that drifted within one state is not re-asked** — the model
-- refining something already agreed with is not new information for a person.

-- ---------------------------------------------------------------------------
-- 1. What is waiting

select * from semantic_private.assertions_awaiting_review(
  'eb769605-5e2c-4175-8b9d-e3864ceaafb1'::uuid
);

-- ---------------------------------------------------------------------------
-- 2. Recording a verdict
--
-- `reviewed_machine_state` is what makes the re-ask work and must be the state
-- as it stands now — which is why it is read from the row rather than typed.
-- `reviewed_strength` and the two model ids are the context a later reader
-- needs to tell a review of a 0.92 claim from one of the same concept at 0.36.

insert into semantic_private.assertion_reviews (
  assertion_id, user_id, verdict, note,
  reviewed_strength, reviewed_machine_state,
  reviewed_ontology_version_id, reviewed_scorer_model_id
)
select a.id, a.user_id,
       'correct',                      -- correct | wrong | unsure
       null,                           -- a note, if the verdict needs one
       latest.strength, a.machine_state,
       (select id from ontology.versions where status = 'published'),
       (select id from ontology.model_versions
         where model_role = 'scorer' and status = 'active'
         order by created_at desc limit 1)
  from semantic_private.user_assertions a
  join ontology.concepts c on c.id = a.concept_id
  left join lateral (
    select v.strength
      from semantic_private.assertion_score_versions v
      join semantic_private.semantic_runs r on r.id = v.semantic_run_id
     where v.assertion_id = a.id
     order by r.started_at desc
     limit 1
  ) latest on true
 where a.user_id = 'eb769605-5e2c-4175-8b9d-e3864ceaafb1'::uuid
   and c.concept_key = 'creator:johann_sebastian_bach'   -- the one being judged
on conflict (assertion_id) do update
  set verdict = excluded.verdict,
      note = excluded.note,
      reviewed_strength = excluded.reviewed_strength,
      reviewed_machine_state = excluded.reviewed_machine_state,
      reviewed_ontology_version_id = excluded.reviewed_ontology_version_id,
      reviewed_scorer_model_id = excluded.reviewed_scorer_model_id,
      reviewed_at = now();

-- ---------------------------------------------------------------------------
-- 3. Where the review stands
--
-- Derivable at any moment, which is the point: "N of M reviewed" replaces a
-- remembered total that goes stale with the next model version. Every figure
-- this project has quoted about assertion counts — 542 scores, 81 assertions —
-- was a snapshot of one run being read as a standing fact.

select r.verdict, count(*) as assertions
  from semantic_private.assertion_reviews r
 where r.user_id = 'eb769605-5e2c-4175-8b9d-e3864ceaafb1'::uuid
 group by r.verdict
union all
select 'unreviewed', count(*)
  from semantic_private.assertions_awaiting_review(
    'eb769605-5e2c-4175-8b9d-e3864ceaafb1'::uuid)
 where reason = 'never reviewed';
