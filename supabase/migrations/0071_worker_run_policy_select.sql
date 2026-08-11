-- 0071 — `on conflict do nothing` needs `select`, not only `insert`.
--
-- `0070` granted insert on `youtube_run_policies` and opening a run still failed
-- with `permission denied for table youtube_run_policies`. The insert that
-- `initialize_youtube_run_policy` performs carries
-- `on conflict (semantic_run_id) do nothing`, and probing the arbiter index to
-- find out whether there *is* a conflict is a read — so the statement needs
-- `select` on the table as well.
--
-- **This is the third face of the same trap this project keeps meeting.** `0009`
-- found that `on conflict do update` demands `update` on every column named
-- whether or not a row exists; `0021` found that it also needs a *select
-- policy*, so a table with RLS and no select policy cannot be upserted into at
-- all. This is the same lesson for the milder form: `do nothing` needs less than
-- `do update`, and it does not need nothing.
--
-- Still no `update`: a run policy is written once, and letting the worker
-- rewrite one would let it widen its own YouTube gates.

begin;

grant select on semantic_private.youtube_run_policies to semantic_worker;

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
    'semantic_private.youtube_run_policies:INSERT,SELECT'
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
