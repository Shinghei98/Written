-- 0140 — a superseded recompute is dead on arrival.
--
-- **`0139` enqueued 581 recompute jobs for one account where one was wanted**,
-- and the mechanism is worth stating exactly because nothing here is broken in
-- isolation. `0139` excluded 580 Spotify observations in one statement.
-- `observation_lifecycle_bump_semantic_revision` is a row-level trigger, so the
-- revision moved 580 times, 33 → 612. `0131` put a `for each row` trigger on
-- `user_state_versions` so that a moved revision enqueues its own recompute —
-- correct, and it fired 580 times, each enqueuing at the revision current at
-- that instant.
--
-- The result is 581 jobs with 581 distinct `idempotency_key`s, because the key
-- carries the revision and every revision genuinely differed. Idempotency was
-- working; the jobs were not duplicates. They were **580 obsolete jobs and one
-- live one**, and only the job at 612 can produce assertions that
-- `api.list_assertions` will show, since it withholds any inferred assertion
-- whose score run is not at the account's current revision. The other 580 would
-- each cost a Lambda invocation to build a run nothing may read.
--
-- CLAUDE.md already names this shape, under the enqueue that `0115` left owed:
-- *"one job per user, keyed on the revision and the three analysis ids, not one
-- per tap — ten confirmations must not queue ten recomputations of the same
-- answer."* That was written about feedback. This is the same defect reached by
-- a bulk lifecycle change instead, and it will be reached again the first time
-- the YouTube thirty-day sweep expires a month of observations in one
-- statement.
--
-- ## The fix goes on `worker_jobs`, not on either trigger
--
-- Statement-level would not help: the 580 updates to `user_state_versions`
-- arrive as 580 separate statements, one per observation row, so a statement
-- trigger fires 580 times too. Nor does the fix belong in
-- `enqueue_recompute_on_analysis_change`, which is already correct — it selects
-- one row per user at that user's current revision, and a migration calling it
-- gets exactly one job per account.
--
-- So it goes where every path meets: a `before insert` on `worker_jobs`. An
-- arriving `recompute_user` supersedes any queued sibling for the same account
-- and the same `(ontology, resolver, scorer)` triple at a **lower**
-- `input_revision`. Both enqueue paths are covered by one rule, and a third
-- written later is covered without being taught.
--
-- **Superseding, not deleting.** `worker_jobs.status` permits `queued`,
-- `running`, `succeeded`, `failed` and `dead` — there is no `cancelled`, and
-- `dead` is the honest terminal state for work that will never be run. The row
-- stays, because a queue that silently drops entries cannot be audited
-- afterwards and this is precisely the kind of thing somebody will want to
-- count later.
--
-- **And it carries no reason, which cost a rejected push to learn.** A first
-- draft wrote an explanation into `last_error` and
-- `guard_worker_job_contract_v03` refused the whole statement:
-- `worker_job_row_is_safe_v03` holds `last_error` to a closed vocabulary —
-- null, `lease_expired_after_max_attempts`, `handler_error`, `no_handler:*` or
-- `invalid_payload:*`. That is the same decision already recorded inside
-- `enqueue_recompute_on_analysis_change`, which refuses to put its `p_reason`
-- in the payload for the same reason: *"the reason belongs to the migration
-- that supplies it… `worker_jobs` is swept, and `git log` is not."* This
-- paragraph is where the reason lives.
--
-- **Strictly lower, and never equal.** Two jobs at the same revision have the
-- same `idempotency_key` and the existing unique index already refuses the
-- second, so equality is handled and reaching for it here would be a second
-- answer to a settled question. **And a `running` job is never touched**: the
-- worker has claimed it and may be most of the way through it, so killing its
-- row underneath it would make the run it is writing an orphan.

begin;

create or replace function semantic_private.supersede_stale_recompute_jobs()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
  if new.job_type <> 'recompute_user' or new.status <> 'queued' then
    return new;
  end if;

  update semantic_private.worker_jobs as stale
     set status = 'dead',
         updated_at = now()
   where stale.job_type = 'recompute_user'
     and stale.status = 'queued'
     and stale.user_id = new.user_id
     -- The analysis identity, minus the revision. A job computed against a
     -- different ontology or a different model is not superseded by this one:
     -- it answers a different question and `semantic_runs` keys on the same
     -- triple for exactly that reason.
     and stale.payload ->> 'ontology_version_id'
           is not distinct from new.payload ->> 'ontology_version_id'
     and stale.payload ->> 'resolver_model_id'
           is not distinct from new.payload ->> 'resolver_model_id'
     and stale.payload ->> 'scorer_model_id'
           is not distinct from new.payload ->> 'scorer_model_id'
     and (stale.payload ->> 'input_revision')::bigint
           < (new.payload ->> 'input_revision')::bigint;

  return new;
end
$function$;

drop trigger if exists worker_jobs_supersede_stale_recompute
  on semantic_private.worker_jobs;
create trigger worker_jobs_supersede_stale_recompute
before insert on semantic_private.worker_jobs
for each row execute function semantic_private.supersede_stale_recompute_jobs();

-- The 580 already queued. The trigger cannot reach backwards, and draining them
-- by hand is 580 invocations of a Lambda to build runs nothing may read.
update semantic_private.worker_jobs as stale
   set status = 'dead',
       updated_at = now()
 where stale.job_type = 'recompute_user'
   and stale.status = 'queued'
   and exists (
     select 1
     from semantic_private.worker_jobs as newer
     where newer.job_type = 'recompute_user'
       and newer.status = 'queued'
       and newer.user_id = stale.user_id
       and newer.payload ->> 'ontology_version_id'
             is not distinct from stale.payload ->> 'ontology_version_id'
       and newer.payload ->> 'resolver_model_id'
             is not distinct from stale.payload ->> 'resolver_model_id'
       and newer.payload ->> 'scorer_model_id'
             is not distinct from stale.payload ->> 'scorer_model_id'
       and (newer.payload ->> 'input_revision')::bigint
             > (stale.payload ->> 'input_revision')::bigint
   );

do $$
declare
  survivors integer;
  wrong_revision integer;
begin
  -- **At most one live recompute per account per analysis identity**, which is
  -- the property the trigger exists to hold and the one the back-fill has to
  -- have reached. Asserted over the whole table rather than over the accounts
  -- `0139` touched, because a rule that holds only where it was applied is a
  -- clean-up rather than an invariant.
  select count(*) into survivors
  from (
    select user_id,
           payload ->> 'ontology_version_id',
           payload ->> 'resolver_model_id',
           payload ->> 'scorer_model_id'
    from semantic_private.worker_jobs
    where job_type = 'recompute_user' and status = 'queued'
    group by 1, 2, 3, 4
    having count(*) > 1
  ) as duplicated;
  if survivors <> 0 then
    raise exception
      '% analysis identities still hold more than one queued recompute', survivors;
  end if;

  -- Every survivor must be at its account's *current* revision. A queue left
  -- holding only stale work would satisfy the check above and be useless — the
  -- failure this migration is about is obsolete jobs, not plural ones, and
  -- counting the right number of unusable things is what a structural check
  -- gets wrong.
  select count(*) into wrong_revision
  from semantic_private.worker_jobs as job
  join semantic_private.user_state_versions as state
    on state.user_id = job.user_id
  where job.job_type = 'recompute_user'
    and job.status = 'queued'
    and (job.payload ->> 'input_revision')::bigint is distinct from state.revision;
  if wrong_revision <> 0 then
    raise exception
      '% queued recompute(s) are not at their account''s current revision',
      wrong_revision;
  end if;
end
$$;

commit;
