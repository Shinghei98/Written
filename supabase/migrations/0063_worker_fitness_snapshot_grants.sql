-- 0063 — what the fitness habit builder needs, and nothing else.
--
-- Phase 2 runs the contract's own HealthKit classifier over the vault and
-- records what it found in `semantic_private.fitness_feature_snapshots`. The
-- worker could not write one: `0057` grants by name rather than by schema, so
-- every table added since is unreachable to it until a migration says
-- otherwise. That is the design working — `on all tables` binds at execution
-- time and would have handed the worker every table a later migration adds.
--
-- Three grants, each for one reason:
--
--   * `healthkit_use_grants` (select) — **the builder checks the grant itself.**
--     Capture already refuses a HealthKit row without one, so this is the second
--     check of the same fact, deliberately: the vault holds rows captured under
--     a grant that may since have been revoked, and "it was allowed in" is not
--     "it is allowed now". A classifier that trusted the presence of rows would
--     be a classifier that kept deriving from a withdrawn consent.
--   * `fitness_feature_snapshots` (select, insert) — the output. **No update**:
--     a snapshot is written once, finished, in one statement. `building` exists
--     for a builder that fills a row in over several steps and this is not one,
--     so the state that could be left dangling is unreachable rather than
--     merely unused.
--   * `ontology.model_versions` (select) — to resolve `fitness_habit_builder` to
--     the id the snapshot's foreign key wants. Read at runtime rather than
--     compiled into the worker, so a model version bump is a row and not a
--     deploy.
--
-- **`insert` without `update` is safe here only because the conflict clause is
-- `do nothing`.** `on conflict do update` demands update on every column named,
-- whether or not a row exists — this project's `42501` lesson from `0009`, paid
-- for twice. Re-running the builder for an unchanged revision must be a no-op,
-- which `do nothing` is and `do update` cannot be without a wider grant.
--
-- Ships no product behaviour: nothing in Swift reads any of this.

begin;

grant select on semantic_private.healthkit_use_grants to semantic_worker;
grant select, insert on semantic_private.fitness_feature_snapshots to semantic_worker;

grant usage on schema ontology to semantic_worker;
grant select on ontology.model_versions to semantic_worker;

-- ---------------------------------------------------------------------------

-- **The list is pinned, not appended to.** `0057`'s argument was that the
-- worker's reach must be readable in one place; a migration that only added
-- grants would leave the reach spread over however many migrations have run.
-- This asserts the whole set, so widening it anywhere means failing here.
do $$
declare
  actual text[];
  expected text[] := array[
    'ontology.model_versions:SELECT',
    'semantic_private.connector_record_source_matrix:SELECT',
    'semantic_private.current_source_items:SELECT',
    'semantic_private.fitness_feature_snapshots:INSERT,SELECT',
    'semantic_private.healthkit_use_grants:SELECT',
    'semantic_private.ingestion_run_items:SELECT',
    'semantic_private.ingestion_run_scopes:SELECT',
    'semantic_private.ingestion_runs:SELECT',
    'semantic_private.observations:INSERT,SELECT',
    'semantic_private.raw_source_records:SELECT',
    'semantic_private.source_state_heads:SELECT',
    'semantic_private.sources:SELECT',
    'semantic_private.user_encryption_keys:SELECT',
    'semantic_private.user_state_versions:INSERT,SELECT,UPDATE',
    'semantic_private.worker_jobs:SELECT,UPDATE'
  ];
begin
  select pg_catalog.array_agg(entry order by entry) into actual
  from (
    select n.nspname || '.' || c.relname || ':' ||
           pg_catalog.string_agg(distinct a.privilege_type, ',' order by a.privilege_type)
             as entry
      from pg_catalog.pg_class c
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
      cross join pg_catalog.aclexplode(c.relacl) a
     where a.grantee = 'semantic_worker'::regrole
     group by n.nspname, c.relname
  ) reached;

  if actual is distinct from expected then
    raise exception 'semantic_worker reaches % — expected %', actual, expected;
  end if;
end
$$;

-- The worker reads the vault and writes evidence; it must never be able to
-- capture. Re-checked here because a grant migration is exactly where that
-- would be lost by accident.
do $$
begin
  if pg_catalog.has_table_privilege(
       'semantic_worker', 'semantic_private.raw_source_records', 'insert') then
    raise exception 'semantic_worker can write raw vault records';
  end if;
  if pg_catalog.has_table_privilege(
       'semantic_worker', 'semantic_private.healthkit_use_grants', 'insert')
     or pg_catalog.has_table_privilege(
       'semantic_worker', 'semantic_private.healthkit_use_grants', 'update') then
    raise exception 'semantic_worker can write its own consent';
  end if;
end
$$;

commit;
