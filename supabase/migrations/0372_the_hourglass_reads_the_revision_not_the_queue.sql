-- 0372 — the hourglass reads the revision, not the queue.
--
-- **Third recurrence, so the fix moves to the root.** `api.memories_status`
-- reported `recomputing` whenever a queued worker job existed — correct
-- when the Lambda consumed the queue, and false ever since the pipeline
-- moved to RIS: every analysis migration dutifully enqueues (0359, 0366,
-- 0369 — the convention stands for the day a consumer returns), the queue
-- holds the promise forever, and the owner sees a permanent hourglass.
-- 0363 and 0368 settled the jobs by hand; a fix that has to be reapplied
-- after every migration is not a fix.
--
-- The honest signal in the RIS era is the one the function already
-- computes: **scored revision ≠ current revision**. A queued job says
-- nothing the revision comparison does not say better — when the RIS run
-- lands, the revision matches and the hourglass drops, with no queue in
-- the story. The queued-jobs clause goes; the standing jobs settle dead
-- as before; the enqueue convention in migrations is untouched.

begin;

create or replace function api.memories_status()
returns table(recomputing boolean, scored_revision bigint, current_revision bigint)
language plpgsql
stable security definer
set search_path to ''
as $function$
begin
  perform semantic_private.assert_surface_allowed('memories');
  return query
  with state as (
    select coalesce(
      (select s.revision from semantic_private.user_state_versions s
        where s.user_id = auth.uid()), 0) as revision
  ),
  scored as (
    select max(run.input_revision) as revision
    from semantic_private.assertion_current_scores cs
    join semantic_private.semantic_runs run on run.id = cs.semantic_run_id
    where cs.user_id = auth.uid() and run.status = 'succeeded'
  )
  -- 0372: the queued-jobs clause is gone. The queue is not the delivery
  -- mechanism while the pipeline runs from RIS; the revision comparison is
  -- the whole truth about whether the page is stale.
  select
    (coalesce(scored.revision, -1) <> state.revision),
    scored.revision,
    state.revision
  from state, scored;
end;
$function$;

update semantic_private.worker_jobs
   set status = 'dead'
 where status in ('queued', 'running');

do $$
begin
  if position('worker_jobs' in
       pg_get_functiondef('api.memories_status()'::regprocedure)) > 0 then
    raise exception '0372: memories_status still reads the queue';
  end if;
  if exists (select 1 from semantic_private.worker_jobs
              where status in ('queued', 'running')) then
    raise exception '0372: jobs still pending';
  end if;
  raise notice '0372: the hourglass keys on the revision alone';
end;
$$;

commit;
