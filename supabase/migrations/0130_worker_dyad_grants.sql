-- 0130 — what the worker needs to compute a dyad, found by reading rather than
-- by failing.
--
-- **`0090`'s lesson, applied at the first opportunity since.** Five migrations
-- — `0086`–`0090`, after `0063` and `0070`–`0073` — each discovered one missing
-- grant by deploying, invoking, and watching it fail. Every one of those facts
-- was static the whole time. `0090` stopped guessing and read `pg_trigger` for
-- the tables being written, followed what each trigger calls, and granted the
-- set; it recorded that this *should be the first move, not the sixth*.
--
-- So this is the first move. Nothing has been deployed and nothing has failed:
-- the whole set below comes from reading the four triggers on `dyad_runs` and
-- `dyad_alignment_pairs`, following each helper they call, and measuring what
-- `semantic_worker` already holds.
--
-- **All four guards are `security invoker`**, which is what makes this
-- necessary at all. They run as the *worker*, not as their owner — unlike the
-- ingestion path, where `ingest_source_records_v031` is `security definer` and
-- `0059` could assert that `semantic_ingestor` gains no table privilege
-- whatever its triggers touch. Here the caller's own privileges are what the
-- guards run with, so every table they read has to be readable by the worker.
--
--     guard_dyad_run_current            user_state_versions ✓,
--                                       match_authorizations ✗,
--                                       active_match_authorization_id_v031 ✗
--     guard_dyad_data_use_purpose       healthkit_use_grants ✓,
--                                       dyad_alignment_pairs ✗,
--                                       healthkit_grant_allows ✗
--     guard_dyad_alignment_current      dyad_runs ✗, dyad_run_is_current ✗,
--                                       assertion_surface_permissions ✓
--     guard_dyad_alignment_healthkit_purpose
--                                       dyad_runs ✗, healthkit_derived_assertions ✓,
--                                       fitness_habit_candidates ✓
--
-- Plus what the handler reads to *compute* rather than to pass a guard:
-- `assertion_current_scores` and `user_terms`, both of which it lacks. The
-- ontology tables it needs for graph distance — `concepts`, `concept_revisions`,
-- `concept_labels`, `relation_types` — it already reads.
--
-- **The enumerated style is `0057`'s and is kept deliberately.** No
-- `on all tables`: that binds at execution time, so a table added later would
-- silently inherit nothing (`0043`'s trap) or, worse, everything.

begin;

-- The two tables the dyad handler owns.
grant select, insert, update on semantic_private.dyad_runs to semantic_worker;
grant select, insert on semantic_private.dyad_alignment_pairs to semantic_worker;

-- **No delete on either.** A dyad run is superseded by a newer one and marked
-- `stale`; nothing about this work removes history, and a worker that could
-- delete a run could erase the record of what it computed.

-- Read-only, for the guards and for the computation.
grant select on semantic_private.match_authorizations to semantic_worker;
grant select on semantic_private.assertion_current_scores to semantic_worker;
grant select on semantic_private.user_terms to semantic_worker;

-- **The guards call these, and the worker could not.** An invoker-security
-- trigger calling a function the caller may not execute fails at the call
-- rather than at the check, which reads as the guard being broken.
grant execute on function
  semantic_private.active_match_authorization_id_v031(uuid, uuid) to semantic_worker;
grant execute on function
  semantic_private.dyad_run_is_current(uuid) to semantic_worker;
grant execute on function
  semantic_private.healthkit_grant_allows(uuid, text, text) to semantic_worker;

-- ---------------------------------------------------------------------------
-- What must be true afterwards
-- ---------------------------------------------------------------------------
--
-- **Asserted narrowly**, on `0089`'s caution: its first draft demanded
-- privileges for paths nobody had asked for, and a check broad enough to do
-- that is an argument for granting them. So this asserts exactly the set above
-- and the two properties that bound it.
do $$
declare
  missing text := '';
begin
  -- Everything a dyad insert will touch, in one list, so a future reader can
  -- see the whole requirement without re-deriving it from four triggers.
  if not has_table_privilege('semantic_worker','semantic_private.dyad_runs','select,insert,update')
    then missing := missing || ' dyad_runs'; end if;
  if not has_table_privilege('semantic_worker','semantic_private.dyad_alignment_pairs','select,insert')
    then missing := missing || ' dyad_alignment_pairs'; end if;
  if not has_table_privilege('semantic_worker','semantic_private.match_authorizations','select')
    then missing := missing || ' match_authorizations'; end if;
  if not has_table_privilege('semantic_worker','semantic_private.assertion_current_scores','select')
    then missing := missing || ' assertion_current_scores'; end if;
  if not has_table_privilege('semantic_worker','semantic_private.user_terms','select')
    then missing := missing || ' user_terms'; end if;
  if not has_table_privilege('semantic_worker','semantic_private.user_state_versions','select')
    then missing := missing || ' user_state_versions'; end if;
  if not has_table_privilege('semantic_worker','semantic_private.assertion_surface_permissions','select')
    then missing := missing || ' assertion_surface_permissions'; end if;
  if not has_function_privilege('semantic_worker',
        'semantic_private.active_match_authorization_id_v031(uuid,uuid)','execute')
    then missing := missing || ' active_match_authorization_id_v031'; end if;
  if not has_function_privilege('semantic_worker',
        'semantic_private.dyad_run_is_current(uuid)','execute')
    then missing := missing || ' dyad_run_is_current'; end if;
  if not has_function_privilege('semantic_worker',
        'semantic_private.healthkit_grant_allows(uuid,text,text)','execute')
    then missing := missing || ' healthkit_grant_allows'; end if;

  if missing <> '' then
    raise exception 'the worker still cannot reach:%', missing;
  end if;

  -- **The bounds.** A dyad worker that could rewrite an authorization could
  -- authorise its own comparison, and one that could delete a run could erase
  -- what it did.
  if has_table_privilege('semantic_worker','semantic_private.match_authorizations','insert')
     or has_table_privilege('semantic_worker','semantic_private.match_authorizations','update')
     or has_table_privilege('semantic_worker','semantic_private.match_authorizations','delete') then
    raise exception 'the worker can write match authorizations; it may only read them';
  end if;
  if has_table_privilege('semantic_worker','semantic_private.dyad_runs','delete')
     or has_table_privilege('semantic_worker','semantic_private.dyad_alignment_pairs','delete') then
    raise exception 'the worker can delete dyad history';
  end if;

  -- And nothing here reached a client role. `semantic_private` grants none of
  -- them usage, so this is belt and braces — and it is the check that would
  -- catch a `to public` typed where `to semantic_worker` was meant.
  if has_table_privilege('authenticated','semantic_private.dyad_runs','select')
     or has_table_privilege('anon','semantic_private.dyad_alignment_pairs','select') then
    raise exception 'a client role can read dyad output';
  end if;
end
$$;

commit;
