-- 0141 — retiring a model kills the queued work that names it.
--
-- **A job pinned to a retired scorer retries forever and can never succeed.**
-- `0139` published scorer 0.8.0 and retired 0.7.0. One recompute for David had
-- already been enqueued by `0131`'s revision trigger while 0.7.0 was active, so
-- its payload names 0.7.0 — and `guard_semantic_run_contract` refuses the run
-- outright: *"semantic run model roles or statuses are invalid"*, P0001, raised
-- the moment the worker opens it. Observed twice in one drain: job `26584a80`
-- came back `retry_scheduled`, `attempts` 2, `last_error` `handler_error`.
--
-- `0140` could not catch it and should not have. That migration supersedes a
-- queued recompute when a *newer revision* arrives for the same analysis
-- identity; this job sits at the current revision (612) under a *different*
-- identity, because the scorer id is part of the identity. Both rules are
-- right and they are about different things.
--
-- **The defect is a permanent refusal treated as transient**, which is its own
-- rule in CLAUDE.md: *"A permanent refusal is dropped, not retried; 401 is
-- transient."* Retirement is one-way here, so the job's inputs never become
-- valid again. Left alone the row burns an invocation on every drain until
-- `attempts` hits the ceiling and it dead-letters as
-- `lease_expired_after_max_attempts` — wasteful, and a lie about what happened:
-- the lease did not expire, the model retired.
--
-- ## The check is the run guard's, all four conditions, re-asked
--
-- `guard_semantic_run_contract` refuses a run on four grounds — ontology
-- version not `published`, resolver not `active`, scorer not `active`, and an
-- embedding model that is present and not `active`. **This function re-asks all
-- four** rather than checking whichever row just changed, so the three triggers
-- below are three callers of one rule rather than three partial copies of it,
-- and a fifth condition added to that guard needs this function updated and
-- nothing else. Checking only the changed row is how a deny-list starts, and
-- the failure mode of a deny-list is silence — `0133` paid for that on five
-- calendar literals and `0139` paid for it again on the ingestion Lambda's
-- source list.
--
-- ## The ordering this depends on, stated so it is not discovered later
--
-- **A migration must retire the old model *before* it enqueues.** `0138` and
-- `0139` both do, and `enqueue_recompute_on_analysis_change` is the last
-- statement in each — right anyway, since that function selects the currently
-- active model and would otherwise name the one about to be retired. Enqueue
-- first and these triggers correctly kill the job just created, leaving nothing
-- queued and nothing to notice. **The assertion below cannot catch that**: a
-- queue that is empty for the wrong reason looks exactly like one that is empty
-- for the right one.
--
-- No `last_error` is written, for the reason `0140` records: it is a closed
-- vocabulary and none of its values means this. The reason lives here.

begin;

create or replace function semantic_private.dead_letter_unrunnable_recomputes()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
  update semantic_private.worker_jobs as job
     set status = 'dead',
         updated_at = now()
   where job.job_type = 'recompute_user'
     and job.status = 'queued'
     and not semantic_private.recompute_job_is_runnable(job.payload);
  return null;
end
$function$;

-- Split out so the sweep, the back-fill and the probe all ask the same
-- question. Three copies of this predicate would be three places to update the
-- day the run guard gains a condition, and the one left behind would fail
-- silently — which is the whole subject of this migration.
create or replace function semantic_private.recompute_job_is_runnable(payload jsonb)
returns boolean
language sql
stable
set search_path to ''
as $function$
  select exists (
      select 1 from ontology.versions as version
       where version.id = (payload ->> 'ontology_version_id')::uuid
         and version.status = 'published'
    )
    and exists (
      select 1 from ontology.model_versions as model
       where model.id = (payload ->> 'resolver_model_id')::uuid
         and model.model_role = 'resolver'
         and model.status = 'active'
    )
    and exists (
      select 1 from ontology.model_versions as model
       where model.id = (payload ->> 'scorer_model_id')::uuid
         and model.model_role = 'scorer'
         and model.status = 'active'
    )
    -- Null is permitted by the run guard, so it is permitted here: a job with
    -- no embedding model is runnable, one naming an inactive model is not.
    and (
      payload ->> 'embedding_model_id' is null
      or exists (
        select 1 from ontology.embedding_models as embedding
         where embedding.id = (payload ->> 'embedding_model_id')::uuid
           and embedding.status = 'active'
      )
    )
$function$;

drop trigger if exists model_versions_dead_letter_unrunnable
  on ontology.model_versions;
create trigger model_versions_dead_letter_unrunnable
after update on ontology.model_versions
for each statement execute function semantic_private.dead_letter_unrunnable_recomputes();

drop trigger if exists ontology_versions_dead_letter_unrunnable
  on ontology.versions;
create trigger ontology_versions_dead_letter_unrunnable
after update on ontology.versions
for each statement execute function semantic_private.dead_letter_unrunnable_recomputes();

drop trigger if exists embedding_models_dead_letter_unrunnable
  on ontology.embedding_models;
create trigger embedding_models_dead_letter_unrunnable
after update on ontology.embedding_models
for each statement execute function semantic_private.dead_letter_unrunnable_recomputes();

do $$
declare
  stranded integer;
  live_before integer;
  survived boolean := false;
  probed boolean := false;
begin
  select count(*) into stranded
  from semantic_private.worker_jobs as job
  where job.job_type = 'recompute_user' and job.status = 'queued'
    and not semantic_private.recompute_job_is_runnable(job.payload);

  select count(*) into live_before
  from semantic_private.worker_jobs
  where job_type = 'recompute_user' and status = 'queued';

  -- **The other direction, proved before the sweep removes the subject.**
  -- `0102` asserted that a guard *mentioned* a flag function and `0117`
  -- asserted a predicate over an empty table; both passed while being wrong. So
  -- the rule is made to answer *not-unrunnable* as well: inside a nested block,
  -- re-activate the retired scorer these jobs name, fire the sweep, and require
  -- that every queued job survives — then roll the experiment back by raising.
  --
  -- Skipped when the queue is empty, which is the honest state on a replay
  -- against a fresh database: there is no subject and pretending otherwise
  -- would be the vacuous pass this comment is about. Said out loud in that case
  -- rather than passing quietly.
  if live_before > 0 then
    begin
      update ontology.model_versions as model
         set status = 'active'
       where model.model_role = 'scorer'
         and model.status = 'retired'
         and model.id in (
           select (job.payload ->> 'scorer_model_id')::uuid
           from semantic_private.worker_jobs as job
           where job.job_type = 'recompute_user' and job.status = 'queued'
         );

      if (
        select count(*) from semantic_private.worker_jobs
         where job_type = 'recompute_user' and status = 'queued'
      ) <> live_before then
        raise exception
          'the sweep killed a runnable recompute: % of % survived',
          (select count(*) from semantic_private.worker_jobs
            where job_type = 'recompute_user' and status = 'queued'),
          live_before;
      end if;

      survived := true;
      raise exception 'rollback the probe';
    exception
      when others then
        if not survived then
          raise;
        end if;
        probed := true;
    end;

    if not probed then
      raise exception 'the probe did not complete';
    end if;
  else
    raise notice
      'no queued recompute to probe; the survival half of this rule is untested here';
  end if;

  -- Now the sweep itself, for the jobs already stranded. The triggers fire only
  -- on a future status change, and the model that stranded these was retired by
  -- `0139`.
  update semantic_private.worker_jobs as job
     set status = 'dead',
         updated_at = now()
   where job.job_type = 'recompute_user'
     and job.status = 'queued'
     and not semantic_private.recompute_job_is_runnable(job.payload);

  if (
    select count(*) from semantic_private.worker_jobs as job
     where job.job_type = 'recompute_user' and job.status = 'queued'
       and not semantic_private.recompute_job_is_runnable(job.payload)
  ) <> 0 then
    raise exception 'queued recomputes still name a model the run guard refuses';
  end if;

  raise notice
    'dead-lettered % stranded recompute(s); % were queued before', stranded, live_before;
end
$$;

commit;
