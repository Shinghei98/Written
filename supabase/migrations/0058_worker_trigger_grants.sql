-- 0058 — the grants the worker needs to satisfy its own triggers.
--
-- **`0057` granted what the worker's *code* reads and missed what its *writes*
-- set off.** Inserting one observation fires six triggers, every one of them
-- `security invoker` — so they run as `semantic_worker` and need its
-- privileges, not the owner's. The first real invocation failed with
-- `InsufficientPrivilege` (42501) and, because `SemanticWorker` records only
-- the stable code `handler_error`, said nothing about which privilege.
--
-- Found by reading what the trigger functions touch rather than by guessing:
--
--   * `guard_connector_record_source_v031` reads
--     `connector_record_source_matrix` — the `0048` provenance check, on every
--     insert.
--   * `bump_user_state_revision` **upserts** `user_state_versions`, which needs
--     `select` as well as `insert` and `update`: `on conflict do update` has to
--     be able to *see* the row it might update, the trap `0021` paid for when
--     `device_tokens` had insert, update and delete policies and no select one
--     and every registration answered 42501.
--   * `guard_private_observation_projection_v03` reaches
--     `fitness_habit_candidates` and `fitness_feature_snapshots`, but only down
--     a HealthKit branch this worker never takes — plpgsql checks privileges
--     when a statement *executes*, so the grant is not needed and is not given.
--     It will be, by whichever migration first projects HealthKit.
--
-- And one that is not a trigger at all: `observations.id` defaults to
-- `extensions.gen_random_uuid()`, and a column default is evaluated as the
-- **inserting** role. `has_function_privilege` answers true for it while the
-- call still fails, because that function does not account for schema usage —
-- which is exactly the sort of check that looks like it proves something.
--
-- Ships no product behaviour.

begin;

grant usage on schema extensions to semantic_worker;

grant select on semantic_private.connector_record_source_matrix to semantic_worker;
grant select, insert, update on semantic_private.user_state_versions to semantic_worker;

-- ---------------------------------------------------------------------------

-- **This restates `0057`'s assertion rather than amending it.** That one
-- describes the grant set at `0057`, which was wrong; this one describes it
-- here. Each migration asserting the state at its own point is how the adapted
-- contracts already work, and it keeps a replay honest: `0057` still passes
-- where it sits in the chain.
do $$
declare
  readable text;
  writable text;
  outside_count integer;
begin
  select pg_catalog.string_agg(c.relname, ', ' order by c.relname)
    into readable
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'semantic_private'
     and c.relkind in ('r', 'p')
     and pg_catalog.has_table_privilege('semantic_worker', c.oid, 'select');

  if readable is distinct from
     'connector_record_source_matrix, current_source_items, ingestion_run_items, '
     || 'ingestion_run_scopes, ingestion_runs, observations, raw_source_records, '
     || 'source_state_heads, sources, user_encryption_keys, user_state_versions, '
     || 'worker_jobs' then
    raise exception 'semantic_worker reads an unexpected set of tables: %', readable;
  end if;

  select pg_catalog.string_agg(c.relname, ', ' order by c.relname)
    into writable
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'semantic_private'
     and c.relkind in ('r', 'p')
     and (pg_catalog.has_table_privilege('semantic_worker', c.oid, 'insert')
       or pg_catalog.has_table_privilege('semantic_worker', c.oid, 'update')
       or pg_catalog.has_table_privilege('semantic_worker', c.oid, 'delete'));

  if writable is distinct from 'observations, user_state_versions, worker_jobs' then
    raise exception 'semantic_worker writes an unexpected set of tables: %', writable;
  end if;

  -- The claim that actually matters, unchanged by any of the above: nothing in
  -- `public`, nothing in the app's own `private`, nothing in `ontology`.
  select pg_catalog.count(*)
    into outside_count
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
   where n.nspname in ('public', 'private', 'ontology')
     and c.relkind in ('r', 'v', 'm', 'p')
     and pg_catalog.has_table_privilege('semantic_worker', c.oid, 'select');

  if outside_count <> 0 then
    raise exception
      'semantic_worker can read % tables outside semantic_private', outside_count;
  end if;
end
$$;

commit;
