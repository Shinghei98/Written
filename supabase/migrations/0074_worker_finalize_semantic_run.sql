-- 0074 — a semantic run may only be succeeded by its finalizer.
--
-- `guard_semantic_run_update` refuses a direct move to `succeeded`:
-- *"semantic runs must be succeeded by finalization"*, enforced through a GUC
-- that only `finalize_semantic_run` sets. That is not ceremony —
-- `finalize_semantic_run` re-locks user state and marks the run **stale** if the
-- input revision moved while it was running, then promotes any assertion scores
-- the run produced. Writing `succeeded` by hand would skip the staleness check
-- and claim a run was computed against state it no longer matches.
--
-- It is `security definer`, so execute is the whole grant: the worker gains no
-- new table access, and the update it could not perform directly is performed
-- for it by a function that also does the check it would have skipped.
--
-- **The same shape as `0055`**, where `ingest_source_records_v031` calls
-- `finalize_ingestion_run_v031` from the inside rather than the endpoint being
-- granted it. A finalizer is a transition, not a write.

begin;

grant execute on function semantic_private.finalize_semantic_run(uuid)
  to semantic_worker;

do $$
begin
  if not pg_catalog.has_function_privilege(
       'semantic_worker', 'semantic_private.finalize_semantic_run(uuid)', 'execute') then
    raise exception 'semantic_worker cannot finalize a semantic run';
  end if;
  -- Still no direct route to a terminal state: `update` on `semantic_runs`
  -- exists for metrics while the run is running, and the guard is what stops it
  -- being used for anything else.
  if not pg_catalog.has_table_privilege(
       'semantic_worker', 'semantic_private.semantic_runs', 'update') then
    raise exception 'semantic_worker cannot record run metrics';
  end if;
end
$$;

commit;
