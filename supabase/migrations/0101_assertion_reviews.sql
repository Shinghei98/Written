-- 0101 — a review that survives being re-scored.
--
-- **The problem this solves is that Phase 2's outputs moved three times in the
-- hour it closed.** Spheres, scenes and composer periods landed after the
-- shadow comparison ran, so its numbers described a scoring model two versions
-- old; the assertion set went 81 → 53 → 65 the same afternoon. Any review keyed
-- to a run is stale the moment a model version changes, and model versions now
-- change several times a day.
--
-- **The fix is that a verdict attaches to the assertion, never to the run.**
-- `user_assertions` rows are stable — keyed on `(user, predicate, concept)`,
-- and a re-score updates `machine_state` and adds an
-- `assertion_score_versions` row rather than replacing the assertion. So the
-- identity a reviewer judged survives any number of re-scores, and what changes
-- underneath it is exactly what makes a re-review worth asking for.
--
-- The reviewable set then becomes derivable rather than remembered, which is
-- what `semantic_private.assertions_awaiting_review` returns: never reviewed, or
-- reviewed and materially changed since.
--
-- **Why not `assertion_preferences`.** It already holds
-- `(assertion_id, user_id, display_state, …)` and looks like the same shape.
-- It is Phase 3's mechanism for the *user* saying "don't show me this", and a
-- reviewer's *"this claim is wrong"* is a different fact about the same row.
-- Storing them in one column means a diagnostic judgement silently becomes a
-- product-level hide — and worse, that a later product change to what
-- `display_state` means would rewrite the review history. Two facts, two tables.
--
-- **`verdict` is closed and small on purpose.** `correct` and `wrong` are the
-- two that matter; `unsure` exists because forcing a reviewer to choose between
-- them when they genuinely cannot is how a review stops being evidence. There
-- is no `skip` — an unreviewed assertion is already represented by having no
-- row here.

begin;

create table if not exists semantic_private.assertion_reviews (
  id uuid primary key default gen_random_uuid(),
  assertion_id uuid not null
    references semantic_private.user_assertions(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  verdict text not null check (verdict in ('correct', 'wrong', 'unsure')),
  note text check (note is null or char_length(note) <= 2000),
  -- **What was true when the verdict was given**, so a later reader can tell a
  -- review of a 0.92 claim from a review of the same concept at 0.36. Recorded
  -- rather than joined, because the score version it refers to belongs to a run
  -- that may since have been superseded.
  reviewed_strength double precision
    check (reviewed_strength is null
           or (reviewed_strength >= 0 and reviewed_strength <= 1)),
  reviewed_machine_state text not null,
  reviewed_ontology_version_id uuid references ontology.versions(id),
  reviewed_scorer_model_id uuid references ontology.model_versions(id),
  reviewed_at timestamptz not null default now(),
  -- One current verdict per assertion. A change of mind is an update, and the
  -- history of verdicts is not something this table promises — `git`-style
  -- versioning of an opinion is a bigger feature than the gate needs.
  unique (assertion_id)
);

comment on table semantic_private.assertion_reviews is
  'Owner/reviewer verdicts on inferred assertions. Keyed to the assertion so a '
  're-score does not invalidate the review; distinct from assertion_preferences, '
  'which is the user product-level display choice.';

create index if not exists assertion_reviews_user_idx
  on semantic_private.assertion_reviews (user_id, reviewed_at desc);

-- **RLS on, no policy, like every other table in this schema.** The posture is
-- statable in one sentence and stays that way: nothing in `semantic_private` is
-- reachable by a client role, and reviews are read through the function below
-- or by the owner of the database.
alter table semantic_private.assertion_reviews enable row level security;
revoke all on table semantic_private.assertion_reviews from public;

create or replace function semantic_private.assertions_awaiting_review(
  p_user_id uuid
) returns table (
  assertion_id uuid,
  concept_key text,
  strength double precision,
  machine_state text,
  reason text
)
language sql
stable
security definer
set search_path = semantic_private, ontology, pg_catalog
as $$
  with latest as (
    select distinct on (v.assertion_id)
           v.assertion_id, v.strength, v.semantic_run_id
      from semantic_private.assertion_score_versions v
      join semantic_private.semantic_runs r on r.id = v.semantic_run_id
     where v.user_id = p_user_id
     order by v.assertion_id, r.started_at desc
  )
  select a.id,
         c.concept_key,
         latest.strength,
         a.machine_state,
         case
           when rev.assertion_id is null then 'never reviewed'
           -- **A state change is what makes a verdict worth revisiting**, not a
           -- score that drifted by a hundredth. A concept that was eligible and
           -- is now inactive has had its claim withdrawn; one that has crossed
           -- the other way is being asserted for the first time since it was
           -- judged. A strength move within one state is the model refining
           -- something the reviewer already agreed with.
           else 'state changed since review'
         end
    from semantic_private.user_assertions a
    join ontology.concepts c on c.id = a.concept_id
    left join latest on latest.assertion_id = a.id
    left join semantic_private.assertion_reviews rev
           on rev.assertion_id = a.id
   where a.user_id = p_user_id
     and a.assertion_origin = 'inferred'
     and (rev.assertion_id is null
          or rev.reviewed_machine_state is distinct from a.machine_state)
   order by latest.strength desc nulls last
$$;

revoke all on function semantic_private.assertions_awaiting_review(uuid) from public;

do $$
declare
  policies integer;
  awaiting integer;
begin
  -- The schema-wide posture: still no policies anywhere in `semantic_private`.
  select count(*) into policies from pg_policies where schemaname = 'semantic_private';
  if policies <> 0 then
    raise exception 'semantic_private gained % policy/policies', policies;
  end if;

  -- And the function answers on real data rather than merely compiling. Every
  -- assertion is unreviewed today, so this must equal the inferred assertion
  -- count for a user who has some — a query that returned zero here would look
  -- exactly like "nothing to review".
  select count(*) into awaiting
  from semantic_private.assertions_awaiting_review(
    (select user_id from semantic_private.user_assertions
      group by user_id order by count(*) desc limit 1));
  if awaiting = 0 and exists (select 1 from semantic_private.user_assertions) then
    raise exception 'assertions exist but none is awaiting review';
  end if;
  raise notice '% assertion(s) awaiting review for the busiest user', awaiting;
end
$$;

commit;
