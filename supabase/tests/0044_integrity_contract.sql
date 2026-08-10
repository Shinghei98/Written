-- Adapted from the v0.3.1 reference `sql/tests/002_integrity_contract.sql`.
-- Gates application migration 0044.
--
-- The reference chain numbers its files 001-006 while this repository's
-- are 0042-0047, so contract numbering is off by two and the two
-- fixture lanes are off by one -- reference fixture `004` gates the
-- app's 0046, and reference fixture `005` gates 0047. The file name
-- states which migration it gates so nobody re-derives that each time.
--
-- Substituted from the reference: 9 `private.` -> `semantic_private.`
-- and 6 bare `'private'` schema arguments. Privacy-class VALUES
-- such as `'private_text'` are deliberately untouched: they are
-- check-constraint values, not schema names, and rewriting them is how
-- a mechanical rename corrupts a contract while still passing.

-- Run after 001_schema.sql, 002_rls_and_rpc.sql, and 003_seed.sql.
-- Catalog checks and rejected writes run inside a rolled-back transaction.
begin;

do $$
declare
  missing_rls_tables text[];
  missing_triggers text[];
  draft_version_id uuid := ontology.stable_uuid('written:test:contract-version');
  published_version_id uuid;
begin
  select array_agg(expected.table_name order by expected.table_name)
  into missing_rls_tables
  from unnest(array[
    'assertion_current_scores', 'assertion_evidence', 'assertion_exposures',
    'assertion_preferences', 'assertion_score_versions', 'concept_scores',
    'concept_source_scores', 'emergent_term_relations', 'emergent_terms',
    'feedback_events', 'ingestion_runs', 'mapping_feedback_labels',
    'motif_instances', 'motif_support', 'observation_mappings',
    'observation_mentions', 'observations', 'rule_feedback_stats',
    'semantic_runs', 'source_connections', 'source_coverage', 'sources',
    'user_assertions', 'user_state_versions', 'user_suppressions',
    'user_terms', 'worker_jobs'
  ]) as expected(table_name)
  left join pg_class as relation
    on relation.relname = expected.table_name
   and relation.relnamespace = 'semantic_private'::regnamespace
   and relation.relrowsecurity
  where relation.oid is null;
  if missing_rls_tables is not null then
    raise exception 'private tables missing RLS: %', missing_rls_tables;
  end if;

  if has_schema_privilege('anon', 'semantic_private', 'usage')
     or has_schema_privilege('authenticated', 'semantic_private', 'usage')
     or has_table_privilege(
       'authenticated', 'semantic_private.user_assertions', 'select'
     )
     or has_function_privilege(
       'authenticated', 'semantic_private.finalize_semantic_run(uuid)', 'execute'
     )
     or has_table_privilege(
       'service_role', 'semantic_private.observations', 'delete'
     )
     or has_table_privilege(
       'service_role', 'ontology.concepts', 'insert'
     )
  then
    raise exception 'Data API roles received internal schema/table/function access';
  end if;
  if not has_function_privilege(
       'authenticated', 'api.list_assertions()', 'execute'
     ) or not has_schema_privilege('service_role', 'semantic_private', 'usage')
     or not has_table_privilege(
       'service_role', 'semantic_private.semantic_runs', 'insert'
     ) or not has_table_privilege(
       'service_role', 'ontology.external_entities', 'insert'
     ) or not has_function_privilege(
       'service_role', 'semantic_private.finalize_semantic_run(uuid)', 'execute'
     )
  then
    raise exception 'explicit client or worker grants are incomplete';
  end if;

  if not exists (
    select 1 from pg_indexes
    where schemaname = 'semantic_private'
      and indexname = 'user_assertion_concept_identity_idx'
      and indexdef like '%WHERE (concept_id IS NOT NULL)%'
  ) or not exists (
    select 1 from pg_indexes
    where schemaname = 'semantic_private'
      and indexname = 'user_assertion_term_identity_idx'
      and indexdef like '%WHERE (user_term_id IS NOT NULL)%'
  ) then
    raise exception 'stable partial assertion identity indexes are missing';
  end if;

  select array_agg(expected.trigger_name order by expected.trigger_name)
  into missing_triggers
  from unnest(array[
    'concept_embeddings_guard_published',
    'concept_edges_guard_published',
    'concept_labels_guard_published',
    'concept_revisions_guard_published',
    'external_concept_links_guard_published',
    'motif_rules_guard_published'
  ]) as expected(trigger_name)
  left join pg_trigger as trigger
    on trigger.tgname = expected.trigger_name
   and not trigger.tgisinternal
  where trigger.oid is null;
  if missing_triggers is not null then
    raise exception 'version-bound immutability triggers missing: %', missing_triggers;
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'semantic_private.assertion_exposures'::regclass
      and pg_get_constraintdef(oid) like '%surface = ''memories''%'
  ) or not exists (
    select 1
    from pg_constraint
    where conrelid = 'semantic_private.user_suppressions'::regclass
      and pg_get_constraintdef(oid) like '%surface = ''memories''%'
  ) then
    raise exception 'surface whitelist is not enforced at table level';
  end if;

  if not exists (
    select 1
    from ontology.motif_rules as rule
    join ontology.concepts as evidence_target
      on evidence_target.id = rule.evidence_target_concept_id
    join ontology.concepts as output_concept
      on output_concept.id = rule.output_concept_id
    where rule.rule_key = 'cultural_affinity_convergence:italy'
      and rule.evidence_predicate_key = 'supports_cultural_affinity_candidate'
      and rule.evidence_predicate_key <> 'associated_with_place'
      and rule.output_predicate_key = 'affinity_to'
      and evidence_target.concept_key = 'place:italy'
      and output_concept.concept_key = 'affinity:culture:italy'
  ) then
    raise exception 'cultural-affinity motif does not use the curated support relation';
  end if;

  if (
    select count(*)
    from ontology.concept_edges as edge
    join ontology.concepts as target on target.id = edge.object_concept_id
    where edge.predicate_key = 'supports_cultural_affinity_candidate'
      and edge.status = 'active'
      and target.concept_key = 'place:italy'
  ) <> 3 then
    raise exception 'expected three curated cultural-affinity support edges';
  end if;
  if exists (
    select 1 from ontology.concept_edges
    where predicate_key = 'associated_with_place'
      and status = 'active'
  ) then
    raise exception 'generic place associations must remain candidate-only';
  end if;

  if exists (
    select 1 from semantic_private.sources
    where source_code = 'healthkit'
      and (
        active
        or coalesce((action_weights->>'activity_day')::double precision, 1) <> 0
        or coalesce((action_weights->>'activity_hour')::double precision, 1) <> 0
        or coalesce((action_weights->>'completed_activity')::double precision, 1) <> 0
      )
  ) then
    raise exception 'HealthKit must remain inactive for Written ontology inference';
  end if;
  if not exists (
    select 1 from semantic_private.sources
    where source_code = 'youtube'
      and (action_weights->>'liked_video')::double precision = 0.90
  ) then
    raise exception 'YouTube liked_video weight is missing';
  end if;

  select id into published_version_id
  from ontology.versions
  where status = 'published';
  insert into ontology.versions (
    id, version, parent_version_id, status, description
  ) values (
    draft_version_id, 'test-contract-version', published_version_id,
    'draft', 'integrity contract test'
  );

  insert into ontology.concept_revisions (
    ontology_version_id, concept_id, preferred_label, concept_kind,
    definition, sensitivity, inference_policy, status, metadata
  )
  select
    draft_version_id, revision.concept_id, revision.preferred_label,
    revision.concept_kind, revision.definition, revision.sensitivity,
    revision.inference_policy, revision.status, revision.metadata
  from ontology.concept_revisions as revision
  join ontology.concepts as concept on concept.id = revision.concept_id
  where revision.ontology_version_id = published_version_id
    and concept.concept_key in (
      'concept:italian_music', 'affinity:culture:italy'
    );

  begin
    insert into ontology.concept_edges (
      ontology_version_id, subject_concept_id, predicate_key,
      object_concept_id, confidence, provenance_type, provenance, status
    )
    select
      draft_version_id, subject.id, 'affinity_to', object.id,
      1.0, 'curated', '{}'::jsonb, 'active'
    from ontology.concepts as subject
    cross join ontology.concepts as object
    where subject.concept_key = 'concept:italian_music'
      and object.concept_key = 'affinity:culture:italy';
    raise exception 'user_claim predicate unexpectedly accepted as a concept edge';
  exception
    when raise_exception then
      if sqlerrm = 'user_claim predicate unexpectedly accepted as a concept edge' then
        raise;
      end if;
  end;

  begin
    update ontology.motif_rules
    set minimum_strength = minimum_strength + 0.01
    where ontology_version_id = published_version_id;
    raise exception 'published motif rule unexpectedly allowed mutation';
  exception
    when raise_exception then
      if sqlerrm = 'published motif rule unexpectedly allowed mutation' then
        raise;
      end if;
  end;

  begin
    update ontology.relation_types
    set assertion_safe = not assertion_safe
    where predicate_key = 'supports_cultural_affinity_candidate';
    raise exception 'referenced relation contract unexpectedly allowed mutation';
  exception
    when raise_exception then
      if sqlerrm = 'referenced relation contract unexpectedly allowed mutation' then
        raise;
      end if;
  end;
end;
$$;

rollback;
