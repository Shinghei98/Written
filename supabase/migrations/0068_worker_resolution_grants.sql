-- 0068 — what the resolver needs, and nothing else.
--
-- Resolution is the first stage that turns an observation into a claim about a
-- concept, and it is genuinely the worker's job — unlike writing observations,
-- which could never work from here. The difference is structural rather than a
-- privilege: `guard_semantic_output_writable` requires a **running**
-- `semantic_runs` row owned by the same user, and the worker *opens that run
-- itself*. An observation belongs to the ingestion run that captured it, and a
-- worker running minutes later has no running run of its own.
--
-- Four grants:
--
--   * `semantic_runs` (select, insert, update) — the run this process owns. It
--     opens one, writes under it and closes it; `update` is for the close, and
--     `semantic_runs_check` makes a `finished_at` mandatory the moment status
--     leaves `running`, so a run cannot be quietly abandoned in a terminal
--     state.
--   * `observation_mappings` (select, insert) — the output. **No update**:
--     `guard_semantic_output_writable` treats the run identity as immutable, and
--     a mapping is written once inside the run that produced it. A correction is
--     a new run, not an edit.
--   * `ontology.concepts`, `concept_revisions`, `concept_labels`,
--     `concept_edges` (select) — the graph, read for the version the *job
--     payload names* rather than "latest published", so a job queued before a
--     version change still resolves against the ontology it was queued for.
--
-- The worker still cannot write the vault, cannot record consent, and cannot
-- touch the ontology it reads. All three are re-checked below, because a grant
-- migration is exactly where that would be lost by accident.
--
-- Ships no product behaviour: nothing in Swift reads any of this.

begin;

grant select, insert, update on semantic_private.semantic_runs to semantic_worker;
grant select, insert on semantic_private.observation_mappings to semantic_worker;

grant select on ontology.concepts to semantic_worker;
grant select on ontology.concept_revisions to semantic_worker;
grant select on ontology.concept_labels to semantic_worker;
grant select on ontology.concept_edges to semantic_worker;

-- ---------------------------------------------------------------------------

-- **The whole reach, pinned — not appended to.** `0057`'s argument was that the
-- worker's access must be readable in one place; a migration that only added
-- grants would spread it over however many migrations have run. Widening it
-- anywhere means failing here.
do $$
declare
  actual text[];
  expected text[] := array[
    'ontology.concept_edges:SELECT',
    'ontology.concept_labels:SELECT',
    'ontology.concept_revisions:SELECT',
    'ontology.concepts:SELECT',
    'ontology.model_versions:SELECT',
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
end
$$;

-- The three things it must never be able to do. Reading the ontology is not
-- editing it: a worker that could write `concept_labels` could teach itself a
-- vocabulary, which is the one decision that belongs to a curator and a new
-- ontology version.
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
  if pg_catalog.has_table_privilege('semantic_worker', 'ontology.concept_labels', 'insert')
     or pg_catalog.has_table_privilege('semantic_worker', 'ontology.concepts', 'insert')
     or pg_catalog.has_table_privilege('semantic_worker', 'ontology.concept_edges', 'insert') then
    raise exception 'semantic_worker can edit the ontology it resolves against';
  end if;
end
$$;

commit;
