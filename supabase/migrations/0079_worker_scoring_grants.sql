-- 0079 — the scorer's four write targets.
--
-- `observation_mappings` holds 12,017 rows and everything downstream of it is
-- empty: no `concept_scores`, no `user_assertions`, no `assertion_score_versions`,
-- no `assertion_evidence`. Nothing in this system has ever computed a score or
-- produced a claim. The worker was never granted the tables to do it — the same
-- shape as `0063` and `0070`–`0073`, each of which existed because a worker was
-- refused something it needed.
--
-- **What is deliberately *not* granted, and why the split survives.**
-- `assertion_current_scores` is written only by `finalize_semantic_run`
-- (`0043`), which is `security definer` and which `0074` gave the worker
-- execute on. That function re-locks user state and marks the run **stale** if
-- the input revision moved while it was running. A worker able to write current
-- scores directly could publish a score computed against state it no longer
-- matches — so promotion stays a transition performed *for* the worker rather
-- than a table it can reach. `0074` states the principle: a finalizer is a
-- transition, not a write.
--
-- `update` on `user_assertions` is granted and the others are insert-only.
-- Assertions are long-lived and their `machine_state` moves between runs —
-- a concept that stops being evidenced becomes `inactive` rather than being
-- deleted. Scores are per-run and immutable: a new run writes a new row, which
-- is what `unique (semantic_run_id, concept_id)` already assumes.

begin;

grant select, insert on semantic_private.concept_scores to semantic_worker;
grant select, insert on semantic_private.assertion_score_versions to semantic_worker;
grant select, insert on semantic_private.assertion_evidence to semantic_worker;
grant select, insert, update on semantic_private.user_assertions to semantic_worker;
grant select on ontology.relation_types to semantic_worker;

do $$
begin
  if not pg_catalog.has_table_privilege(
       'semantic_worker', 'semantic_private.concept_scores', 'insert') then
    raise exception 'semantic_worker cannot write concept scores';
  end if;
  if not pg_catalog.has_table_privilege(
       'semantic_worker', 'semantic_private.assertion_score_versions', 'insert') then
    raise exception 'semantic_worker cannot write assertion score versions';
  end if;
  if not pg_catalog.has_table_privilege(
       'semantic_worker', 'semantic_private.assertion_evidence', 'insert') then
    raise exception 'semantic_worker cannot write assertion evidence';
  end if;
  if not pg_catalog.has_table_privilege(
       'semantic_worker', 'semantic_private.user_assertions', 'update') then
    raise exception 'semantic_worker cannot retire an assertion';
  end if;

  -- **The assertion that matters most is a negative one.** If this ever passes,
  -- the worker can promote a score without the staleness check that
  -- `finalize_semantic_run` exists to perform, and the guarantee in `0074` is
  -- gone silently — nothing would fail, scores would simply become publishable
  -- by a path that never checks whether they are still valid.
  if pg_catalog.has_table_privilege(
       'semantic_worker', 'semantic_private.assertion_current_scores', 'insert')
     or pg_catalog.has_table_privilege(
       'semantic_worker', 'semantic_private.assertion_current_scores', 'update') then
    raise exception 'semantic_worker must not write assertion_current_scores directly';
  end if;

  -- Scores are per-run and immutable; an update path would let a finished run
  -- be rewritten after the fact, which no consumer could detect.
  if pg_catalog.has_table_privilege(
       'semantic_worker', 'semantic_private.concept_scores', 'update')
     or pg_catalog.has_table_privilege(
       'semantic_worker', 'semantic_private.concept_scores', 'delete') then
    raise exception 'concept scores must be insert-only for the worker';
  end if;
end
$$;

commit;
