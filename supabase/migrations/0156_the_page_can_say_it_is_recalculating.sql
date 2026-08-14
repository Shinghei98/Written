-- 0156 — the page can say it is recalculating instead of looking empty.
--
-- **A blank Memories page and a recalculating one are the same picture, and
-- that has now been mistaken for a bug three times in one evening.** The cause
-- is by design: every distillation bumps the account's revision, and
-- `list_assertions` withholds any inferred assertion whose score was not
-- computed at the current revision — the difference between a claim about
-- somebody and a claim about who they used to be. Correct, and indistinguishable
-- from having nothing to say.
--
-- The client cannot tell the two apart on its own. Zero rows is zero rows. So
-- the server has to say which it is, and this is the smallest function that can.
--
-- ## What "recomputing" means here
--
-- Two conditions, either of which makes the page provisional:
--
--   * the newest scored run is behind the account's revision — the data moved
--     and the scores have not caught up; or
--   * a job is queued or running — the worker is on its way.
--
-- The first is what the reader actually experiences. The second matters because
-- the queue drains on a schedule now, so "nothing is late, work is simply in
-- flight" is a real state and reads better than a bare emptiness.
--
-- **Nothing about a person crosses this boundary.** It answers a boolean and a
-- timestamp about *machinery*, and holds no label, no concept and no count of
-- what somebody has. It is still `security definer` and still scoped to
-- `auth.uid()` with no parameter for whose, because that is how every function
-- on this surface is built and a status endpoint is exactly where an exception
-- would look harmless.

begin;

create or replace function api.memories_status()
returns table(recomputing boolean, scored_revision bigint, current_revision bigint)
language plpgsql
stable
security definer
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
  ),
  pending as (
    select exists (
      select 1 from semantic_private.worker_jobs j
      where j.user_id = auth.uid() and j.status in ('queued', 'running')
    ) as waiting
  )
  select
    (coalesce(scored.revision, -1) <> state.revision or pending.waiting),
    scored.revision,
    state.revision
  from state, scored, pending;
end;
$function$;

revoke all on function api.memories_status() from public;
revoke all on function api.memories_status() from anon;
grant execute on function api.memories_status() to authenticated;

do $$
declare
  granted boolean;
begin
  -- `0124`'s lesson: Supabase's default privileges grant every new public
  -- function to anon and authenticated, and `revoke ... from public` names the
  -- pseudo-role and leaves the direct grant untouched. Revoke from anon by name,
  -- then check the catalog rather than trusting the statement.
  select has_function_privilege('anon', 'api.memories_status()', 'execute')
    into granted;
  if granted then
    raise exception 'anon can execute memories_status';
  end if;

  select has_function_privilege('authenticated', 'api.memories_status()', 'execute')
    into granted;
  if not granted then
    raise exception 'authenticated cannot execute memories_status';
  end if;

  raise notice '0156: memories_status is authenticated-only';
end;
$$;

commit;
