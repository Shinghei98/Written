-- 0070 — opening a run writes a YouTube policy row, and the worker could not.
--
-- `initialize_youtube_run_policy` fires on every `semantic_runs` insert and
-- writes one `youtube_run_policies` row with all gates at their defaults. It is
-- `security invoker`, so it runs as `semantic_worker` — and a run could not be
-- opened at all without this grant, for a table that has nothing to do with the
-- music this worker resolves.
--
-- **Insert only, and the `on conflict do nothing` is why that is enough.** A
-- `do update` would demand update on every column named whether or not a row
-- exists (this project's `42501` lesson from `0009`), and update here would let
-- the worker widen its own YouTube gates — precisely what
-- `guard_youtube_run_policy` exists to prevent. Nothing about YouTube is enabled
-- by this: the row is written with every gate false, and YouTube is archived.
--
-- Read-only elsewhere. Third and last of the grants the run guards demanded,
-- each found by being refused rather than by reading the schema first — which is
-- the honest way round for triggers, since a `security invoker` trigger's reads
-- are invisible at the call site.

begin;

grant insert on semantic_private.youtube_run_policies to semantic_worker;

do $$
declare
  actual text[];
  expected text[] := array[
    'ontology.concept_edges:SELECT',
    'ontology.concept_labels:SELECT',
    'ontology.concept_revisions:SELECT',
    'ontology.concepts:SELECT',
    'ontology.embedding_models:SELECT',
    'ontology.model_versions:SELECT',
    'ontology.versions:SELECT',
    'semantic_private.connector_record_source_matrix:SELECT',
    'semantic_private.current_source_items:SELECT',
    'semantic_private.fitness_feature_snapshots:INSERT,SELECT',
    'semantic_private.healthkit_use_grants:SELECT',
    'semantic_private.ingestion_run_items:SELECT',
    'semantic_private.ingestion_run_scopes:SELECT',
    'semantic_private.ingestion_runs:SELECT',
    'semantic_private.observation_mappings:INSERT,SELECT',
    'semantic_private.observations:INSERT,SELECT',
    'semantic_private.raw_source_records:SELECT',
    'semantic_private.semantic_runs:INSERT,SELECT,UPDATE',
    'semantic_private.source_state_heads:SELECT',
    'semantic_private.sources:SELECT',
    'semantic_private.user_encryption_keys:SELECT',
    'semantic_private.user_state_versions:INSERT,SELECT,UPDATE',
    'semantic_private.worker_jobs:SELECT,UPDATE',
    'semantic_private.youtube_run_policies:INSERT'
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

  if pg_catalog.has_table_privilege('semantic_worker', 'ontology.versions', 'update')
     or pg_catalog.has_table_privilege('semantic_worker', 'ontology.versions', 'insert') then
    raise exception 'semantic_worker can publish an ontology version';
  end if;
  -- Insert only. A run policy is written once by the trigger that opens the run;
  -- an `update` here would let the worker widen its own YouTube gates, which is
  -- the one thing `guard_youtube_run_policy` exists to prevent.
  if pg_catalog.has_table_privilege(
       'semantic_worker', 'semantic_private.youtube_run_policies', 'update') then
    raise exception 'semantic_worker can rewrite a run''s YouTube policy';
  end if;
end
$$;

commit;
