-- 0069 — two more reads the run guard needs, found by being refused.
--
-- `guard_semantic_run_contract` fires on `semantic_runs` insert and checks three
-- things the worker never queries itself: that the ontology version is
-- `published`, that the resolver and scorer models are active, and that the
-- embedding model is active. It is `security invoker`, so those reads happen as
-- `semantic_worker` — and `0068` granted `model_versions` while missing the
-- other two. The failure was `permission denied for table versions`, which reads
-- like the worker touching something it should not and is in fact a trigger
-- doing its job.
--
-- **The guard is also the answer to a design question.** *"Semantic runs must
-- start on the published ontology version"* — so a job queued before a version
-- change cannot open a run against the version it was queued with. Exactly one
-- version is published at a time; a mapping is only meaningful against the
-- ontology in force; and `recompute_user` exists so outputs can be rebuilt when
-- it moves. The resolver reads the published version live because of this.
--
-- Read-only, both of them. The worker still cannot edit the ontology.

begin;

grant select on ontology.versions to semantic_worker;
grant select on ontology.embedding_models to semantic_worker;

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

  if pg_catalog.has_table_privilege('semantic_worker', 'ontology.versions', 'update')
     or pg_catalog.has_table_privilege('semantic_worker', 'ontology.versions', 'insert') then
    raise exception 'semantic_worker can publish an ontology version';
  end if;
end
$$;

commit;
