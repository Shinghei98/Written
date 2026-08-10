-- Adapted from the v0.3.1 reference `sql/tests/005_private_ingestion_and_fitness_contract.sql`.
-- Gates application migration 0046.
--
-- The reference chain numbers its files 001-006 while this repository's
-- are 0042-0047, so contract numbering is off by two and the two
-- fixture lanes are off by one -- reference fixture `004` gates the
-- app's 0046, and reference fixture `005` gates 0047. The file name
-- states which migration it gates so nobody re-derives that each time.
--
-- Substituted from the reference: 264 `private.` -> `semantic_private.`
-- and 5 bare `'private'` schema arguments. Privacy-class VALUES
-- such as `'private_text'` are deliberately untouched: they are
-- check-constraint values, not schema names, and rewriting them is how
-- a mechanical rename corrupts a contract while still passing.

-- Run after 001_schema.sql through 005_private_ingestion_and_fitness.sql.
-- All identities, timestamps, payloads, and records below are synthetic.
begin;

do $contract_catalog$
declare
  missing_objects text[];
begin
  select array_agg(expected.object_name order by expected.object_name)
  into missing_objects
  from unnest(array[
    'semantic_private.raw_source_records',
    'semantic_private.healthkit_use_grants',
    'semantic_private.fitness_feature_snapshots',
    'semantic_private.fitness_habit_candidates',
    'semantic_private.fitness_candidate_support',
    'semantic_private.fitness_candidate_observations',
    'semantic_private.healthkit_derived_assertions'
  ]) as expected(object_name)
  where to_regclass(expected.object_name) is null;
  if missing_objects is not null then
    raise exception 'v0.3 private-ingestion tables are missing: %', missing_objects;
  end if;

  select array_agg(expected.table_name order by expected.table_name)
  into missing_objects
  from (values
    ('raw_source_records'),
    ('healthkit_use_grants'),
    ('fitness_feature_snapshots'),
    ('fitness_habit_candidates'),
    ('fitness_candidate_support'),
    ('fitness_candidate_observations'),
    ('healthkit_derived_assertions')
  ) as expected(table_name)
  left join pg_namespace as namespace
    on namespace.nspname = 'semantic_private'
  left join pg_class as relation
    on relation.relnamespace = namespace.oid
   and relation.relname = expected.table_name
   and relation.relrowsecurity
  where relation.oid is null;
  if missing_objects is not null then
    raise exception 'v0.3 internal tables are missing RLS: %', missing_objects;
  end if;

  if exists (
    select 1
    from pg_policies
    where schemaname = 'semantic_private'
      and tablename in (
        'raw_source_records', 'healthkit_use_grants',
        'fitness_feature_snapshots', 'fitness_habit_candidates',
        'fitness_candidate_support', 'fitness_candidate_observations',
        'healthkit_derived_assertions'
      )
  ) then
    raise exception 'v0.3 server-internal tables expose a Data API policy';
  end if;

  if has_table_privilege(
       'authenticated', 'semantic_private.raw_source_records', 'select'
     ) or has_table_privilege(
       'authenticated', 'semantic_private.healthkit_use_grants', 'select'
     ) or has_table_privilege(
       'authenticated', 'semantic_private.fitness_habit_candidates', 'select'
     ) or has_table_privilege(
       'authenticated', 'semantic_private.fitness_candidate_observations', 'select'
     ) or not has_table_privilege(
       'service_role', 'semantic_private.raw_source_records', 'insert'
     ) or not has_table_privilege(
       'service_role', 'semantic_private.healthkit_use_grants', 'update'
     ) or not has_table_privilege(
       'service_role', 'semantic_private.fitness_feature_snapshots', 'insert'
     ) or not has_table_privilege(
       'service_role', 'semantic_private.fitness_candidate_support', 'insert'
     ) or not has_table_privilege(
       'service_role', 'semantic_private.healthkit_derived_assertions', 'insert'
     ) then
    raise exception 'v0.3 grants are not default-deny/service-only';
  end if;

  select array_agg(
           expected.table_name || ':' || expected.constraint_name
           order by expected.table_name, expected.constraint_name
         )
  into missing_objects
  from (values
    ('semantic_private.observations', 'observations_privacy_class_v03_check'),
    ('semantic_private.observations', 'observations_no_raw_private_payload_v03_check'),
    ('semantic_private.raw_source_records', 'raw_source_records_payload_location_check'),
    ('semantic_private.raw_source_records', 'raw_source_records_ciphertext_size_check'),
    ('semantic_private.raw_source_records', 'raw_source_records_opaque_identity_check'),
    ('semantic_private.raw_source_records', 'raw_source_records_token_fields_check'),
    ('semantic_private.raw_source_records', 'raw_source_records_purpose_check'),
    ('semantic_private.raw_source_records', 'raw_source_records_source_purpose_v03_check'),
    ('semantic_private.healthkit_use_grants', 'healthkit_use_grants_lattice_check'),
    ('semantic_private.fitness_feature_snapshots', 'fitness_feature_snapshots_coverage_check'),
    ('semantic_private.fitness_habit_candidates', 'fitness_habit_candidates_support_check'),
    ('semantic_private.fitness_habit_candidates', 'fitness_habit_candidates_purpose_check'),
    ('semantic_private.fitness_habit_candidates', 'fitness_habit_candidates_freshness_check'),
    ('semantic_private.fitness_candidate_support', 'fitness_candidate_support_role_check'),
    ('semantic_private.fitness_candidate_support', 'fitness_candidate_support_attestation_check'),
    ('semantic_private.fitness_candidate_support', 'fitness_candidate_support_week_check'),
    ('semantic_private.fitness_candidate_observations', 'fitness_candidate_observations_purpose_check'),
    ('semantic_private.healthkit_derived_assertions', 'healthkit_derived_assertions_purpose_check'),
    ('semantic_private.calendar_event_classifications', 'calendar_classifications_version_v03_fkey'),
    ('semantic_private.calendar_event_classifications', 'calendar_classifications_revision_v03_check'),
    ('semantic_private.calendar_event_classifications', 'calendar_classifications_safe_payload_check'),
    ('semantic_private.travel_segments', 'travel_segments_destination_active_place_v03_fkey'),
    ('semantic_private.travel_journeys', 'travel_journeys_terminal_active_place_v03_fkey'),
    ('semantic_private.booked_activity_candidates', 'booked_activity_candidates_target_binding_v03_check'),
    ('ontology.model_versions', 'model_versions_model_role_v03_check'),
    ('semantic_private.worker_jobs', 'worker_jobs_job_type_v03_check'),
    ('semantic_private.dyad_runs', 'dyad_runs_data_use_purpose_v03_check'),
    ('semantic_private.validated_surface_facts', 'validated_surface_facts_evidence_class_v03_check'),
    ('semantic_private.validated_surface_facts', 'validated_surface_facts_data_use_purpose_v03_check'),
    ('semantic_private.icebreaker_frames', 'icebreaker_frames_exposure_v03_check')
  ) as expected(table_name, constraint_name)
  left join pg_constraint as constraint_row
    on constraint_row.conrelid = to_regclass(expected.table_name)
   and constraint_row.conname = expected.constraint_name
  where constraint_row.oid is null;
  if missing_objects is not null then
    raise exception 'v0.3 constraints are missing: %', missing_objects;
  end if;

  if to_regclass(
       'semantic_private.fitness_candidate_support_sleep_night_uidx'
     ) is null then
    raise exception 'sleep support lacks a one-record-per-night uniqueness gate';
  end if;
  if to_regprocedure(
       'semantic_private.fitness_candidate_is_current(uuid,uuid)'
     ) is null
     or has_function_privilege(
       'authenticated',
       'semantic_private.fitness_candidate_is_current(uuid,uuid)', 'execute'
     )
     or not has_function_privilege(
       'service_role',
       'semantic_private.fitness_candidate_is_current(uuid,uuid)', 'execute'
     ) or has_function_privilege(
       'authenticated',
       'semantic_private.scheduled_travel_candidate_is_current_v03(uuid,uuid)',
       'execute'
     ) or not has_function_privilege(
       'service_role',
       'semantic_private.scheduled_travel_candidate_is_current_v03(uuid,uuid)',
       'execute'
     ) then
    raise exception 'current fitness-candidate gate is not service-only';
  end if;

  select array_agg(
           expected.table_name || ':' || expected.trigger_name
           order by expected.table_name, expected.trigger_name
         )
  into missing_objects
  from (values
    ('semantic_private.fitness_feature_snapshots', 'fitness_feature_snapshots_guard_builder'),
    ('semantic_private.worker_jobs', 'worker_jobs_guard_contract_v03'),
    ('semantic_private.worker_jobs', 'worker_jobs_guard_derive_fitness_payload'),
    ('semantic_private.raw_source_records', 'raw_source_records_guard_update'),
    ('semantic_private.raw_source_records', 'raw_source_records_guard_healthkit_grant'),
    ('semantic_private.healthkit_use_grants', 'healthkit_use_grants_guard_delete'),
    ('semantic_private.fitness_habit_candidates', 'fitness_habit_candidates_guard_semantics'),
    ('semantic_private.fitness_habit_candidates', 'fitness_habit_candidates_validate_support'),
    ('semantic_private.fitness_candidate_support', 'fitness_candidate_support_validate_candidate'),
    ('semantic_private.fitness_candidate_observations', 'fitness_candidate_observations_guard_projection'),
    ('semantic_private.observation_mappings', 'observation_mappings_guard_healthkit_candidate'),
    ('semantic_private.observation_mappings', 'observation_mappings_guard_calendar_classification'),
    ('semantic_private.observation_mentions', 'observation_mentions_guard_private_sources_v03'),
    ('semantic_private.mapping_feedback_labels', 'mapping_feedback_labels_guard_private_sources_v03'),
    ('semantic_private.observations', 'observations_guard_private_projection_v03'),
    ('semantic_private.calendar_event_classifications', 'calendar_classifications_guard_current_v03'),
    ('semantic_private.travel_segments', 'travel_segments_guard_current_classification_v03'),
    ('semantic_private.travel_journeys', 'travel_journeys_guard_payload_v03'),
    ('semantic_private.recurring_place_candidates', 'recurring_place_candidates_guard_payload_v03'),
    ('semantic_private.booked_activity_candidates', 'booked_activity_candidates_guard_target_binding_v03'),
    ('semantic_private.memories_snapshot_items', 'memories_snapshot_items_guard_calendar_labels_v03'),
    ('semantic_private.assertion_evidence', 'assertion_evidence_guard_run_alignment_v03'),
    ('semantic_private.healthkit_derived_assertions', 'healthkit_derived_assertions_guard_alignment'),
    ('semantic_private.assertion_surface_permissions', 'assertion_surface_permissions_guard_healthkit'),
    ('semantic_private.dyad_runs', 'dyad_runs_guard_data_use_purpose'),
    ('semantic_private.dyad_alignment_pairs', 'dyad_alignment_pairs_guard_healthkit_purpose'),
    ('semantic_private.validated_surface_facts', 'validated_surface_facts_guard_healthkit'),
    ('semantic_private.healthkit_use_grants', 'healthkit_use_grants_invalidate_on_revocation'),
    ('semantic_private.icebreaker_frames', 'icebreaker_frames_guard_exposed_immutability'),
    ('semantic_private.icebreaker_frame_facts', 'icebreaker_frame_facts_guard_exposed'),
    ('semantic_private.user_state_versions', 'user_state_versions_invalidate_product_outputs')
  ) as expected(table_name, trigger_name)
  left join pg_trigger as trigger_row
    on trigger_row.tgrelid = to_regclass(expected.table_name)
   and trigger_row.tgname = expected.trigger_name
   and not trigger_row.tgisinternal
  where trigger_row.oid is null;
  if missing_objects is not null then
    raise exception 'v0.3 triggers are missing: %', missing_objects;
  end if;

  if to_regprocedure(
       'semantic_private.worker_job_payload_is_valid_v03(text,uuid,jsonb)'
     ) is null
     or to_regprocedure(
       'semantic_private.worker_job_result_is_safe_v03(jsonb)'
     ) is null
     or to_regprocedure(
       'semantic_private.sanitize_invalid_worker_jobs_v03()'
     ) is null
     or has_function_privilege(
       'authenticated',
       'semantic_private.worker_job_payload_is_valid_v03(text,uuid,jsonb)', 'execute'
     )
     or has_function_privilege(
       'service_role',
       'semantic_private.worker_job_payload_is_valid_v03(text,uuid,jsonb)', 'execute'
     )
     or has_function_privilege(
       'authenticated',
       'semantic_private.sanitize_invalid_worker_jobs_v03()', 'execute'
     )
     or has_function_privilege(
       'service_role',
       'semantic_private.sanitize_invalid_worker_jobs_v03()', 'execute'
     )
     or not exists (
       select 1
       from pg_proc as procedure
       join pg_namespace as namespace on namespace.oid = procedure.pronamespace
       where namespace.nspname = 'semantic_private'
         and procedure.proname = 'guard_worker_job_contract_v03'
         and procedure.prosecdef
         and procedure.proconfig @> array['search_path=""']::text[]
     ) then
    raise exception 'worker-job validators or remediation have unsafe ACLs';
  end if;

  if not exists (
    select 1
    from pg_proc as procedure
    join pg_namespace as namespace on namespace.oid = procedure.pronamespace
    where namespace.nspname = 'semantic_private'
      and procedure.proname = 'mark_icebreaker_exposed'
      and procedure.prosecdef
      and procedure.proconfig @> array['search_path=""']::text[]
  ) or has_function_privilege(
       'authenticated', 'semantic_private.mark_icebreaker_exposed(uuid)', 'execute'
     ) or not has_function_privilege(
       'service_role', 'semantic_private.mark_icebreaker_exposed(uuid)', 'execute'
     ) then
    raise exception 'icebreaker exposure is not a fixed-path service-only function';
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'semantic_private.observations'::regclass
      and conname = 'observations_privacy_class_v03_check'
      and pg_get_constraintdef(oid) like '%private_calendar_sanitized%'
      and pg_get_constraintdef(oid) like '%private_fitness_sanitized%'
  ) then
    raise exception 'sanitized private observation classes are incomplete';
  end if;

  if (
    select count(*)
    from pg_constraint
    where conrelid = 'semantic_private.observations'::regclass
      and conname in (
        'observations_no_raw_private_payload_v03_check',
        'observations_private_identity_v03_check'
      )
      and convalidated
  ) <> 2 then
    raise exception 'private observation projection constraints are not validated';
  end if;
  if not exists (
    select 1
    from pg_proc as procedure
    join pg_namespace as namespace on namespace.oid = procedure.pronamespace
    where namespace.nspname = 'semantic_private'
      and procedure.proname =
        'private_observation_projection_is_valid_v03'
      and procedure.pronargs = 19
      and procedure.provolatile = 'i'
      and procedure.proconfig @> array['search_path=""']::text[]
      and not has_function_privilege(
        'authenticated', procedure.oid, 'execute'
      )
      and has_function_privilege('service_role', procedure.oid, 'execute')
  ) then
    raise exception 'private observation projection validator ACL/config drifted';
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'semantic_private.worker_jobs'::regclass
      and conname = 'worker_jobs_job_type_v03_check'
      and pg_get_constraintdef(oid) like '%derive_fitness_habits%'
  ) or not exists (
    select 1
    from pg_constraint
    where conrelid = 'ontology.model_versions'::regclass
      and conname = 'model_versions_model_role_v03_check'
      and pg_get_constraintdef(oid) like '%fitness_habit_builder%'
  ) then
    raise exception 'fitness job/model roles are not registered';
  end if;

  if not exists (
    select 1
    from semantic_private.sources
    where source_code = 'healthkit'
      and provider = 'apple'
      and evidence_channel = 'fitness'
      and independence_group = 'fitness'
      and online_resolution_policy = 'disabled_private'
      and default_reliability = 0.90
      and active
      and action_weights ->> 'activity_day' = '0.0'
      and action_weights ->> 'activity_hour' = '0.0'
      and action_weights ->> 'workout' = '0.0'
      and action_weights ->> 'sleep' = '0.0'
      and action_weights ->> 'routine' = '0.85'
  ) then
    raise exception 'HealthKit source activation or action weights drifted';
  end if;

  if not exists (
    select 1
    from ontology.model_versions
    where id = ontology.stable_uuid(
            'written:model:fitness-habit-builder:v1.0.0'
          )
      and model_key = 'healthkit_fitness_habit_builder'
      and version = '1.0.0'
      and model_role = 'fitness_habit_builder'
      and status = 'active'
      and parameters ->> 'purpose' = 'fitness_connection'
      and parameters ->> 'policy_version' = 'written-healthkit-fitness-v1.0.0'
      and parameters ->> 'raw_term_mapping' = 'false'
      and parameters ->> 'aggregate_only_abstains' = 'true'
      and parameters ->> 'workout_window_days' = '42'
      and parameters ->> 'daypart_min_concentration' = '0.70'
      and parameters ->> 'sleep_semantic_promotion' = 'false'
      and parameters ->> 'candidate_ttl_days' = '7'
  ) then
    raise exception 'active HealthKit fitness builder registration drifted';
  end if;
end
$contract_catalog$;

do $worker_job_contract$
declare
  queue_user_id uuid := ontology.stable_uuid('written:test:v0.3-worker-user');
  subject_user_id uuid := ontology.stable_uuid('written:test:v0.3-worker-subject');
  fixture_id uuid := ontology.stable_uuid('written:test:v0.3-worker-fixture');
  valid_job_id uuid := ontology.stable_uuid('written:test:v0.3-worker-valid-job');
  legacy_job_id uuid := ontology.stable_uuid('written:test:v0.3-worker-legacy-job');
  fixture record;
  fixture_count integer := 0;
  map_payload jsonb;
  recompute_payload jsonb;
  dyad_payload jsonb;
  refresh_payload jsonb;
  retained_text text;
begin
  insert into auth.users (id, aud, role, created_at, updated_at) values
    (queue_user_id, 'authenticated', 'authenticated', now(), now()),
    (subject_user_id, 'authenticated', 'authenticated', now(), now());

  map_payload := jsonb_build_object(
    'observation_id', fixture_id::text,
    'user_id', queue_user_id::text,
    'input_revision', 7,
    'semantic_run_id', fixture_id::text,
    'ontology_version_id', fixture_id::text,
    'resolver_model_id', fixture_id::text
  );
  recompute_payload := jsonb_build_object(
    'user_id', queue_user_id::text,
    'input_revision', 7,
    'ontology_version_id', fixture_id::text,
    'resolver_model_id', fixture_id::text,
    'scorer_model_id', fixture_id::text,
    'embedding_model_id', fixture_id::text
  );
  dyad_payload := jsonb_build_object(
    'viewer_user_id', queue_user_id::text,
    'subject_user_id', subject_user_id::text,
    'viewer_revision', 5,
    'subject_revision', 9,
    'ontology_version_id', fixture_id::text,
    'ranker_model_id', fixture_id::text,
    'run_purpose', 'both',
    'data_use_purpose', 'general_social'
  );
  refresh_payload := jsonb_build_object(
    'external_entity_id', fixture_id::text,
    'refresher_version', 'external-refresh-v1'
  );

  for fixture in
    select * from (values
      ('map_observation', queue_user_id, map_payload),
      ('classify_calendar', queue_user_id, jsonb_build_object(
        'observation_id', fixture_id::text,
        'user_id', queue_user_id::text,
        'input_revision', 7,
        'ontology_version_id', fixture_id::text,
        'classifier_model_id', fixture_id::text
      )),
      ('resolve_youtube_channel', null::uuid, jsonb_build_object(
        'youtube_channel_row_id', fixture_id::text,
        'youtube_channel_id', 'UC' || repeat('A', 22),
        'ontology_version_id', fixture_id::text,
        'resolver_model_id', fixture_id::text,
        'resolution_version', 'youtube-resolver-v0.2.0'
      )),
      ('recompute_user', queue_user_id, recompute_payload),
      ('build_memories', queue_user_id, jsonb_build_object(
        'user_id', queue_user_id::text,
        'input_revision', 7,
        'ontology_version_id', fixture_id::text,
        'builder_model_id', fixture_id::text,
        'presentation_version', 'memories-v0.2.0'
      )),
      ('compute_dyad', queue_user_id, dyad_payload),
      ('render_bio', queue_user_id, jsonb_build_object(
        'dyad_run_id', fixture_id::text,
        'viewer_user_id', queue_user_id::text,
        'subject_user_id', subject_user_id::text,
        'viewer_revision', 5,
        'subject_revision', 9,
        'renderer_model_id', fixture_id::text,
        'presentation_version', 'bio-v0.2.0'
      )),
      ('render_icebreaker', queue_user_id, jsonb_build_object(
        'match_authorization_id', fixture_id::text,
        'dyad_run_id', fixture_id::text,
        'viewer_user_id', queue_user_id::text,
        'subject_user_id', subject_user_id::text,
        'viewer_revision', 5,
        'subject_revision', 9,
        'renderer_model_id', fixture_id::text,
        'template_version', 'icebreaker-v0.2.0'
      )),
      ('mine_terms', null::uuid, jsonb_build_object(
        'aggregate_snapshot_id', fixture_id::text,
        'base_ontology_version_id', fixture_id::text,
        'miner_model_id', fixture_id::text,
        'minimum_distinct_users', 5,
        'mining_policy_version', 'privacy-floor-v1'
      )),
      ('refresh_external_entity', null::uuid, refresh_payload),
      ('derive_fitness_habits', queue_user_id, jsonb_build_object(
        'user_id', queue_user_id::text,
        'input_revision', 7,
        'fitness_snapshot_id', fixture_id::text,
        'builder_model_id', fixture_id::text,
        'policy_version', 'written-healthkit-fitness-v1.0.0'
      ))
    ) as valid_fixture(job_type, owner_user_id, payload)
  loop
    fixture_count := fixture_count + 1;
    if not semantic_private.worker_job_payload_is_valid_v03(
      fixture.job_type, fixture.owner_user_id, fixture.payload
    ) then
      raise exception 'valid worker schema was rejected: %', fixture.job_type;
    end if;
  end loop;
  if fixture_count <> 11 then
    raise exception 'worker schema fixture count drifted';
  end if;

  -- Both Python optional-field encodings remain valid only when absent or typed.
  if not semantic_private.worker_job_payload_is_valid_v03(
       'recompute_user', queue_user_id,
       recompute_payload - 'embedding_model_id'
     )
     or not semantic_private.worker_job_payload_is_valid_v03(
       'compute_dyad', queue_user_id,
       dyad_payload - 'data_use_purpose'
     )
     or semantic_private.worker_job_payload_is_valid_v03(
       'recompute_user', queue_user_id,
       jsonb_set(recompute_payload, '{embedding_model_id}', 'null'::jsonb)
     ) then
    raise exception 'worker optional-field contract drifted';
  end if;

  -- Closed keys, canonical UUIDs, integer revisions, queue ownership, dyad
  -- direction, enums, privacy floors, versions, and fitness policy all fail shut.
  if semantic_private.worker_job_payload_is_valid_v03(
       'map_observation', queue_user_id,
       map_payload || '{"raw_calendar":"Synthetic Private Event"}'::jsonb
     )
     or semantic_private.worker_job_payload_is_valid_v03(
       'map_observation', null, map_payload
     )
     or semantic_private.worker_job_payload_is_valid_v03(
       'map_observation', subject_user_id, map_payload
     )
     or semantic_private.worker_job_payload_is_valid_v03(
       'map_observation', queue_user_id,
       jsonb_set(map_payload, '{observation_id}', to_jsonb(upper(fixture_id::text)))
     )
     or semantic_private.worker_job_payload_is_valid_v03(
       'map_observation', queue_user_id,
       jsonb_set(map_payload, '{input_revision}', '7.0'::jsonb)
     )
     or semantic_private.worker_job_payload_is_valid_v03(
       'map_observation', queue_user_id,
       jsonb_set(map_payload, '{input_revision}', '9223372036854775808'::jsonb)
     )
     or semantic_private.worker_job_payload_is_valid_v03(
       'refresh_external_entity', queue_user_id, refresh_payload
     )
     or semantic_private.worker_job_payload_is_valid_v03(
       'refresh_external_entity', null,
       jsonb_set(refresh_payload, '{refresher_version}', '"unsafe version"'::jsonb)
     )
     or semantic_private.worker_job_payload_is_valid_v03(
       'compute_dyad', queue_user_id,
       jsonb_set(dyad_payload, '{subject_user_id}', to_jsonb(queue_user_id::text))
     )
     or semantic_private.worker_job_payload_is_valid_v03(
       'compute_dyad', queue_user_id,
       jsonb_set(dyad_payload, '{run_purpose}', '"dating"'::jsonb)
     )
     or semantic_private.worker_job_payload_is_valid_v03(
       'mine_terms', null, jsonb_build_object(
         'aggregate_snapshot_id', fixture_id::text,
         'base_ontology_version_id', fixture_id::text,
         'miner_model_id', fixture_id::text,
         'minimum_distinct_users', 4,
         'mining_policy_version', 'privacy-floor-v1'
       )
     )
     or semantic_private.worker_job_payload_is_valid_v03(
       'derive_fitness_habits', queue_user_id, jsonb_build_object(
         'user_id', queue_user_id::text,
         'input_revision', 7,
         'fitness_snapshot_id', fixture_id::text,
         'builder_model_id', fixture_id::text,
         'policy_version', 'written-healthkit-fitness-v0.9.0'
       )
     ) then
    raise exception 'malformed worker payload crossed the SQL registry';
  end if;

  if not semantic_private.worker_job_result_is_safe_v03('{}'::jsonb)
     or not semantic_private.worker_job_result_is_safe_v03(jsonb_build_object(
       'output_id', fixture_id::text, 'candidate_count', 3,
       'abstained', false, 'outcome', 'created'
     ))
     or semantic_private.worker_job_result_is_safe_v03(
       '{"outcome":"Synthetic Private Person"}'::jsonb
     )
     or semantic_private.worker_job_result_is_safe_v03(
       '{"debug":"Synthetic Private Result"}'::jsonb
     )
     or semantic_private.worker_job_result_is_safe_v03(
       '{"output_id":{"nested":"value"}}'::jsonb
     ) then
    raise exception 'worker result scalar/ID firewall drifted';
  end if;
  if not semantic_private.worker_job_row_is_safe_v03(
       'refresh_external_entity', null, refresh_payload,
       'synthetic-v0.3-handler-error', null, 'handler_error', '{}'::jsonb
     )
     or not semantic_private.worker_job_row_is_safe_v03(
       'refresh_external_entity', null, refresh_payload,
       'synthetic-v0.3-no-handler', null,
       'no_handler:refresh_external_entity', '{}'::jsonb
     )
     or not semantic_private.worker_job_row_is_safe_v03(
       'refresh_external_entity', null, refresh_payload,
       'synthetic-v0.3-invalid-payload', null,
       'invalid_payload:invalid_uuid', '{}'::jsonb
     )
     or not semantic_private.worker_job_row_is_safe_v03(
       'refresh_external_entity', null, refresh_payload,
       'synthetic-v0.3-lease-expired', null,
       'lease_expired_after_max_attempts', '{}'::jsonb
     )
     or semantic_private.worker_job_row_is_safe_v03(
       'refresh_external_entity', null, refresh_payload,
       'synthetic-v0.3-handler-class', null, 'ValueError', '{}'::jsonb
     )
     or semantic_private.worker_job_row_is_safe_v03(
       'refresh_external_entity', null, refresh_payload,
       'synthetic-v0.3-wrong-handler', null,
       'no_handler:map_observation', '{}'::jsonb
     )
     or semantic_private.worker_job_row_is_safe_v03(
       'refresh_external_entity', null, refresh_payload,
       'synthetic-v0.3-private-error', null,
       'invalid_payload:private_person_name', '{}'::jsonb
     ) then
    raise exception 'worker error-code allowlist drifted';
  end if;

  insert into semantic_private.worker_jobs (
    id, job_type, user_id, payload, idempotency_key
  ) values (
    valid_job_id, 'map_observation', queue_user_id, map_payload,
    'synthetic-v0.3-worker-valid'
  );
  update semantic_private.worker_jobs
  set status = 'succeeded',
      result = jsonb_build_object('mapped', valid_job_id::text)
  where id = valid_job_id;

  begin
    update semantic_private.worker_jobs
    set result = '{"outcome":"Synthetic Private Person"}'::jsonb
    where id = valid_job_id;
    raise exception 'private worker result was persisted';
  exception
    when raise_exception then
      if sqlerrm = 'private worker result was persisted' then raise; end if;
  end;
  begin
    update semantic_private.worker_jobs
    set last_error = 'Synthetic private exception message'
    where id = valid_job_id;
    raise exception 'free-text worker error was persisted';
  exception
    when raise_exception then
      if sqlerrm = 'free-text worker error was persisted' then raise; end if;
  end;
  begin
    update semantic_private.worker_jobs
    set locked_by = 'Synthetic private worker name'
    where id = valid_job_id;
    raise exception 'free-text worker lock owner was persisted';
  exception
    when raise_exception then
      if sqlerrm = 'free-text worker lock owner was persisted' then raise; end if;
  end;
  begin
    insert into semantic_private.worker_jobs (
      job_type, user_id, payload, idempotency_key
    ) values (
      'refresh_external_entity', null, refresh_payload,
      'Synthetic private idempotency key'
    );
    raise exception 'free-text worker idempotency key was persisted';
  exception
    when raise_exception then
      if sqlerrm = 'free-text worker idempotency key was persisted' then raise; end if;
  end;
  begin
    insert into semantic_private.worker_jobs (
      job_type, user_id, payload, idempotency_key
    ) values (
      'refresh_external_entity', null,
      refresh_payload || '{"raw_calendar":"Synthetic Private Event"}'::jsonb,
      'synthetic-v0.3-private-payload'
    );
    raise exception 'private worker payload was persisted';
  exception
    when raise_exception then
      if sqlerrm = 'private worker payload was persisted' then raise; end if;
  end;

  -- Simulate one pre-005 row, then prove the migration sanitizer destroys every
  -- content-bearing field instead of retaining a private queue artifact.
  execute 'alter table semantic_private.worker_jobs disable trigger worker_jobs_guard_contract_v03';
  insert into semantic_private.worker_jobs (
    id, job_type, user_id, payload, idempotency_key, status,
    locked_at, locked_by, last_error, result
  ) values (
    legacy_job_id, 'refresh_external_entity', null,
    '{"raw_calendar":"Synthetic Private Queue Payload"}'::jsonb,
    'Synthetic Private Queue Key', 'running', now(),
    'Synthetic Private Worker', 'Synthetic Private Error',
    '{"debug":"Synthetic Private Result"}'::jsonb
  );
  execute 'alter table semantic_private.worker_jobs enable trigger worker_jobs_guard_contract_v03';
  perform semantic_private.sanitize_invalid_worker_jobs_v03();

  select payload::text || result::text || idempotency_key
         || coalesce(locked_by, '') || coalesce(last_error, '')
  into retained_text
  from semantic_private.worker_jobs
  where id = legacy_job_id;
  if retained_text like '%Synthetic Private%'
     or not exists (
       select 1 from semantic_private.worker_jobs
       where id = legacy_job_id
         and status = 'dead'
         and payload = '{}'::jsonb
         and result = '{}'::jsonb
         and idempotency_key = 'legacy-invalid:' || legacy_job_id::text
         and locked_at is null
         and locked_by is null
         and last_error = 'invalid_payload:sql_contract'
     ) then
    raise exception 'legacy worker row retained private queue content';
  end if;

  delete from semantic_private.worker_jobs where id in (valid_job_id, legacy_job_id);
  delete from auth.users where id in (queue_user_id, subject_user_id);
end
$worker_job_contract$;

do $contract_behavior$
declare
  published_version_id uuid;
  viewer_user_id uuid := ontology.stable_uuid('written:test:v0.3-viewer');
  subject_user_id uuid := ontology.stable_uuid('written:test:v0.3-subject');
  aggregate_user_id uuid := ontology.stable_uuid('written:test:v0.3-aggregate-user');
  sleep_user_id uuid := ontology.stable_uuid('written:test:v0.3-sleep-user');
  unstable_sleep_user_id uuid := ontology.stable_uuid('written:test:v0.3-unstable-sleep-user');
  viewer_ingestion_id uuid := ontology.stable_uuid('written:test:v0.3-viewer-ingestion');
  subject_ingestion_id uuid := ontology.stable_uuid('written:test:v0.3-subject-ingestion');
  calendar_ingestion_id uuid := ontology.stable_uuid('written:test:v0.3-calendar-ingestion');
  sleep_ingestion_id uuid := ontology.stable_uuid('written:test:v0.3-sleep-ingestion');
  unstable_sleep_ingestion_id uuid := ontology.stable_uuid('written:test:v0.3-unstable-sleep-ingestion');
  viewer_run_id uuid := ontology.stable_uuid('written:test:v0.3-viewer-run');
  viewer_other_run_id uuid := ontology.stable_uuid(
    'written:test:v0.3-viewer-other-run'
  );
  subject_run_id uuid := ontology.stable_uuid('written:test:v0.3-subject-run');
  builder_model_id uuid;
  resolver_model_id uuid;
  scorer_model_id uuid;
  ranker_model_id uuid;
  renderer_model_id uuid;
  calendar_classifier_model_id uuid;
  memories_builder_model_id uuid;
  running_concept_id uuid;
  walking_concept_id uuid;
  morning_concept_id uuid;
  sleep_concept_id uuid;
  italy_concept_id uuid;
  sports_concept_id uuid;
  viewer_snapshot_id uuid := ontology.stable_uuid('written:test:v0.3-viewer-snapshot');
  subject_snapshot_id uuid := ontology.stable_uuid('written:test:v0.3-subject-snapshot');
  aggregate_snapshot_id uuid := ontology.stable_uuid('written:test:v0.3-aggregate-snapshot');
  sleep_snapshot_id uuid := ontology.stable_uuid('written:test:v0.3-sleep-snapshot');
  unstable_sleep_snapshot_id uuid := ontology.stable_uuid('written:test:v0.3-unstable-sleep-snapshot');
  viewer_candidate_id uuid := ontology.stable_uuid('written:test:v0.3-viewer-candidate');
  subject_candidate_id uuid := ontology.stable_uuid('written:test:v0.3-subject-candidate');
  daypart_candidate_id uuid := ontology.stable_uuid('written:test:v0.3-daypart-candidate');
  weak_daypart_candidate_id uuid := ontology.stable_uuid('written:test:v0.3-weak-daypart-candidate');
  sleep_candidate_id uuid := ontology.stable_uuid('written:test:v0.3-sleep-candidate');
  unstable_sleep_candidate_id uuid := ontology.stable_uuid('written:test:v0.3-unstable-sleep-candidate');
  viewer_assertion_id uuid := ontology.stable_uuid('written:test:v0.3-viewer-assertion');
  subject_assertion_id uuid := ontology.stable_uuid('written:test:v0.3-subject-assertion');
  mismatched_assertion_id uuid := ontology.stable_uuid('written:test:v0.3-mismatched-assertion');
  raw_viewer_1 uuid := ontology.stable_uuid('written:test:v0.3-raw-viewer-1');
  raw_viewer_2 uuid := ontology.stable_uuid('written:test:v0.3-raw-viewer-2');
  raw_viewer_3 uuid := ontology.stable_uuid('written:test:v0.3-raw-viewer-3');
  raw_viewer_4 uuid := ontology.stable_uuid('written:test:v0.3-raw-viewer-4');
  raw_viewer_5 uuid := ontology.stable_uuid('written:test:v0.3-raw-viewer-5');
  raw_viewer_6 uuid := ontology.stable_uuid('written:test:v0.3-raw-viewer-6');
  raw_viewer_7 uuid := ontology.stable_uuid('written:test:v0.3-raw-viewer-7');
  raw_viewer_8 uuid := ontology.stable_uuid('written:test:v0.3-raw-viewer-8');
  raw_viewer_9 uuid := ontology.stable_uuid('written:test:v0.3-raw-viewer-9');
  raw_viewer_10 uuid := ontology.stable_uuid('written:test:v0.3-raw-viewer-10');
  raw_viewer_old uuid := ontology.stable_uuid('written:test:v0.3-raw-viewer-old');
  raw_lifecycle_id uuid := ontology.stable_uuid(
    'written:test:v0.3-raw-lifecycle-record'
  );
  raw_subject_1 uuid := ontology.stable_uuid('written:test:v0.3-raw-subject-1');
  raw_subject_2 uuid := ontology.stable_uuid('written:test:v0.3-raw-subject-2');
  raw_subject_3 uuid := ontology.stable_uuid('written:test:v0.3-raw-subject-3');
  raw_subject_4 uuid := ontology.stable_uuid('written:test:v0.3-raw-subject-4');
  raw_subject_5 uuid := ontology.stable_uuid('written:test:v0.3-raw-subject-5');
  raw_subject_6 uuid := ontology.stable_uuid('written:test:v0.3-raw-subject-6');
  raw_subject_7 uuid := ontology.stable_uuid('written:test:v0.3-raw-subject-7');
  raw_subject_8 uuid := ontology.stable_uuid('written:test:v0.3-raw-subject-8');
  raw_subject_9 uuid := ontology.stable_uuid('written:test:v0.3-raw-subject-9');
  raw_subject_10 uuid := ontology.stable_uuid('written:test:v0.3-raw-subject-10');
  raw_health_observation_id uuid := ontology.stable_uuid('written:test:v0.3-raw-health-observation');
  routine_observation_id uuid := ontology.stable_uuid('written:test:v0.3-routine-observation');
  subject_routine_observation_id uuid := ontology.stable_uuid('written:test:v0.3-subject-routine-observation');
  calendar_observation_id uuid := ontology.stable_uuid('written:test:v0.3-calendar-observation');
  calendar_semantic_observation_id uuid := ontology.stable_uuid(
    'written:test:v0.3-calendar-semantic-observation'
  );
  calendar_classification_id uuid := ontology.stable_uuid(
    'written:test:v0.3-calendar-current-classification'
  );
  calendar_candidate_id uuid := ontology.stable_uuid(
    'written:test:v0.3-calendar-booked-candidate'
  );
  calendar_memories_snapshot_id uuid := ontology.stable_uuid(
    'written:test:v0.3-calendar-memories-snapshot'
  );
  calendar_memories_item_id uuid := ontology.stable_uuid(
    'written:test:v0.3-calendar-memories-item'
  );
  routine_mapping_id uuid := ontology.stable_uuid('written:test:v0.3-routine-mapping');
  subject_routine_mapping_id uuid := ontology.stable_uuid('written:test:v0.3-subject-routine-mapping');
  viewer_other_mapping_id uuid := ontology.stable_uuid(
    'written:test:v0.3-viewer-other-mapping'
  );
  viewer_score_id uuid := ontology.stable_uuid(
    'written:test:v0.3-viewer-assertion-score'
  );
  general_dyad_id uuid := ontology.stable_uuid('written:test:v0.3-general-dyad');
  fitness_dyad_id uuid := ontology.stable_uuid('written:test:v0.3-fitness-dyad');
  fitness_without_grant_id uuid := ontology.stable_uuid('written:test:v0.3-no-grant-dyad');
  match_authorization_id uuid := ontology.stable_uuid('written:test:v0.3-match-authorization');
  exposed_frame_id uuid := ontology.stable_uuid('written:test:v0.3-exposed-frame');
  provisional_frame_id uuid := ontology.stable_uuid('written:test:v0.3-provisional-frame');
  viewer_fact_id uuid := ontology.stable_uuid('written:test:v0.3-viewer-fact');
  subject_fact_id uuid := ontology.stable_uuid('written:test:v0.3-subject-fact');
  fitness_policy constant text := 'written-healthkit-fitness-v1.0.0';
  booked_event_hub_id constant uuid :=
    '8816b5e8-ce07-582b-abdf-86f7359d1f1e'::uuid;
  calendar_lineage constant text := repeat('e', 64);
  workout_start_day date := date_trunc(
    'week', now() at time zone 'UTC'
  )::date - 28;
  workout_window_end timestamptz := now();
  sleep_start_day date := date_trunc(
    'week', now() at time zone 'UTC'
  )::date - 14;
begin
  select id into published_version_id
  from ontology.versions where status = 'published';
  select id into builder_model_id
  from ontology.model_versions
  where model_key = 'healthkit_fitness_habit_builder' and version = '1.0.0';
  select id into resolver_model_id
  from ontology.model_versions
  where model_key = 'ontology_first_resolver' and version = '0.1.0';
  select id into scorer_model_id
  from ontology.model_versions
  where model_key = 'missing_aware_late_fusion' and version = '0.1.0';
  select id into ranker_model_id
  from ontology.model_versions
  where model_key = 'typed_graph_dyad_ranker' and version = '0.2.0';
  select id into renderer_model_id
  from ontology.model_versions
  where model_key = 'deterministic_icebreaker_renderer' and version = '0.2.0';
  select id into calendar_classifier_model_id
  from ontology.model_versions
  where model_role = 'calendar_classifier' and status = 'active'
  order by created_at desc, id limit 1;
  select id into memories_builder_model_id
  from ontology.model_versions
  where model_role = 'memories_builder' and status = 'active'
  order by created_at desc, id limit 1;
  select id into running_concept_id
  from ontology.concepts where concept_key = 'activity:running';
  select id into walking_concept_id
  from ontology.concepts where concept_key = 'activity:walking';
  select id into morning_concept_id
  from ontology.concepts where concept_key = 'routine:morning_workouts';
  select id into sleep_concept_id
  from ontology.concepts where concept_key = 'routine:consistent_sleep_schedule';
  select id into italy_concept_id
  from ontology.concepts where concept_key = 'place:italy';
  select id into sports_concept_id
  from ontology.concepts where concept_key = 'hub:sports_movement';

  if published_version_id is null or builder_model_id is null
     or resolver_model_id is null or scorer_model_id is null
     or ranker_model_id is null or renderer_model_id is null
     or calendar_classifier_model_id is null
     or memories_builder_model_id is null
     or running_concept_id is null or walking_concept_id is null
     or morning_concept_id is null or sleep_concept_id is null
     or italy_concept_id is null or sports_concept_id is null then
    raise exception 'v0.3 contract fixtures are missing seeded identifiers';
  end if;

  insert into auth.users (id, aud, role, created_at, updated_at) values
    (viewer_user_id, 'authenticated', 'authenticated', now(), now()),
    (subject_user_id, 'authenticated', 'authenticated', now(), now()),
    (aggregate_user_id, 'authenticated', 'authenticated', now(), now()),
    (sleep_user_id, 'authenticated', 'authenticated', now(), now()),
    (unstable_sleep_user_id, 'authenticated', 'authenticated', now(), now());
  insert into semantic_private.user_state_versions (user_id, revision) values
    (viewer_user_id, 0), (subject_user_id, 0), (aggregate_user_id, 0),
    (sleep_user_id, 0), (unstable_sleep_user_id, 0);

  -- Matching and public naming are separate user choices. Explanation still
  -- requires at least one naming surface so it cannot become a broader grant.
  begin
    insert into semantic_private.healthkit_use_grants (
      user_id, allow_fitness_matching, allow_bio_naming,
      allow_icebreaker_naming, allow_controlled_explanation, consent_version
    ) values (
      aggregate_user_id, false, false, false, true, 'synthetic-invalid-v1'
    );
    raise exception 'invalid HealthKit grant lattice was accepted';
  exception
    when check_violation then null;
  end;

  insert into semantic_private.healthkit_use_grants (
    user_id, allow_fitness_matching, allow_bio_naming,
    allow_icebreaker_naming, allow_controlled_explanation, consent_version
  ) values (
    unstable_sleep_user_id, false, true, false, false,
    'synthetic-independent-v1'
  );
  if semantic_private.healthkit_grant_allows(
       unstable_sleep_user_id, 'matching', 'select'
     ) or not semantic_private.healthkit_grant_allows(
       unstable_sleep_user_id, 'bio', 'name'
     ) then
    raise exception 'HealthKit matching and naming grants are not independent';
  end if;

  insert into semantic_private.healthkit_use_grants (
    user_id, allow_fitness_matching, allow_bio_naming,
    allow_icebreaker_naming, allow_controlled_explanation, consent_version
  ) values (
    viewer_user_id, true, true, true, true, 'synthetic-v1'
  );

  begin
    insert into semantic_private.dyad_runs (
      id, viewer_user_id, subject_user_id, viewer_revision, subject_revision,
      ontology_version_id, ranker_model_id, run_purpose, data_use_purpose,
      input_hash
    ) values (
      fitness_without_grant_id, viewer_user_id, subject_user_id, 0, 0,
      published_version_id, ranker_model_id, 'icebreaker',
      'fitness_connection', 'synthetic-fitness-without-bilateral-grant'
    );
    raise exception 'fitness dyad accepted a missing bilateral grant';
  exception
    when raise_exception then
      if sqlerrm = 'fitness dyad accepted a missing bilateral grant' then raise; end if;
  end;

  insert into semantic_private.healthkit_use_grants (
    user_id, allow_fitness_matching, allow_bio_naming,
    allow_icebreaker_naming, allow_controlled_explanation, consent_version
  ) values
    (subject_user_id, true, true, true, true, 'synthetic-v1'),
    (aggregate_user_id, false, false, false, false, 'synthetic-v1'),
    (sleep_user_id, false, false, false, false, 'synthetic-v1');

  if not semantic_private.healthkit_grant_allows(
       viewer_user_id, 'matching', 'select'
     ) or not semantic_private.healthkit_grant_allows(
       viewer_user_id, 'bio', 'name'
     ) or not semantic_private.healthkit_grant_allows(
       viewer_user_id, 'icebreaker', 'explain'
     ) or semantic_private.healthkit_grant_allows(
       viewer_user_id, 'matching', 'name'
     ) or semantic_private.healthkit_grant_allows(
       viewer_user_id, 'unknown', 'select'
     ) then
    raise exception 'HealthKit purpose-grant decision matrix is incorrect';
  end if;

  insert into semantic_private.ingestion_runs (
    id, user_id, source_code, connector_version, input_hash, status
  ) values
    (viewer_ingestion_id, viewer_user_id, 'healthkit', 'synthetic-v0.3',
     'synthetic-healthkit-viewer', 'running'),
    (subject_ingestion_id, subject_user_id, 'healthkit', 'synthetic-v0.3',
     'synthetic-healthkit-subject', 'running'),
    (sleep_ingestion_id, sleep_user_id, 'healthkit', 'synthetic-v0.3',
     'synthetic-healthkit-sleep', 'running'),
    (unstable_sleep_ingestion_id, unstable_sleep_user_id, 'healthkit',
     'synthetic-v0.3', 'synthetic-healthkit-unstable-sleep', 'running'),
    (calendar_ingestion_id, viewer_user_id, 'apple_calendar', 'synthetic-v0.3',
     'synthetic-calendar-viewer', 'running');

  -- Raw records are encrypted/blob-referenced vault rows. Source and consent
  -- purpose must agree; the vault is not an ontology-observation table.
  insert into semantic_private.raw_source_records (
    id, user_id, ingestion_run_id, source_code, data_type, occurred_at,
    source_item_hmac, record_fingerprint, encryption_key_version,
    encrypted_payload, consent_purpose, retention_policy_version,
    retained_until
  ) values
    (raw_viewer_1, viewer_user_id, viewer_ingestion_id, 'healthkit', 'workout',
     (workout_start_day::timestamp + interval '7 hours') at time zone 'UTC',
     repeat(md5('hmac-v1'), 2),
     repeat(md5('fitness-v1'), 2), 'key_synthetic_v1',
     decode(repeat('11', 16), 'hex'), 'fitness_connection', 'synthetic-retain-v1',
     now() + interval '365 days'),
    (raw_viewer_2, viewer_user_id, viewer_ingestion_id, 'healthkit', 'workout',
     ((workout_start_day + 7)::timestamp + interval '7 hours') at time zone 'UTC',
     repeat(md5('hmac-v2'), 2),
     repeat(md5('fitness-v2'), 2), 'key_synthetic_v1',
     decode(repeat('22', 16), 'hex'), 'fitness_connection', 'synthetic-retain-v1',
     now() + interval '365 days'),
    (raw_viewer_3, viewer_user_id, viewer_ingestion_id, 'healthkit', 'workout',
     ((workout_start_day + 14)::timestamp + interval '7 hours') at time zone 'UTC',
     repeat(md5('hmac-v3'), 2),
     repeat(md5('fitness-v3'), 2), 'key_synthetic_v1',
     decode(repeat('33', 16), 'hex'), 'fitness_connection', 'synthetic-retain-v1',
     now() + interval '365 days'),
    (raw_viewer_4, viewer_user_id, viewer_ingestion_id, 'healthkit', 'workout',
     ((workout_start_day + 21)::timestamp + interval '7 hours') at time zone 'UTC',
     repeat(md5('hmac-v4'), 2),
     repeat(md5('fitness-v4'), 2), 'key_synthetic_v1',
     decode(repeat('44', 16), 'hex'), 'fitness_connection', 'synthetic-retain-v1',
     now() + interval '365 days'),
    (raw_viewer_5, viewer_user_id, viewer_ingestion_id, 'healthkit', 'workout',
     ((workout_start_day + 2)::timestamp + interval '7 hours') at time zone 'UTC',
     repeat(md5('hmac-v5'), 2),
     repeat(md5('fitness-v5'), 2), 'key_synthetic_v1',
     decode(repeat('15', 16), 'hex'), 'fitness_connection', 'synthetic-retain-v1',
     now() + interval '365 days'),
    (raw_viewer_6, viewer_user_id, viewer_ingestion_id, 'healthkit', 'workout',
     ((workout_start_day + 9)::timestamp + interval '7 hours') at time zone 'UTC',
     repeat(md5('hmac-v6'), 2),
     repeat(md5('fitness-v6'), 2), 'key_synthetic_v1',
     decode(repeat('16', 16), 'hex'), 'fitness_connection', 'synthetic-retain-v1',
     now() + interval '365 days'),
    (raw_viewer_7, viewer_user_id, viewer_ingestion_id, 'healthkit', 'workout',
     ((workout_start_day + 16)::timestamp + interval '7 hours') at time zone 'UTC',
     repeat(md5('hmac-v7'), 2),
     repeat(md5('fitness-v7'), 2), 'key_synthetic_v1',
     decode(repeat('17', 16), 'hex'), 'fitness_connection', 'synthetic-retain-v1',
     now() + interval '365 days'),
    (raw_viewer_8, viewer_user_id, viewer_ingestion_id, 'healthkit', 'workout',
     ((workout_start_day + 3)::timestamp + interval '13 hours') at time zone 'UTC',
     repeat(md5('hmac-v8'), 2),
     repeat(md5('fitness-v8'), 2), 'key_synthetic_v1',
     decode(repeat('18', 16), 'hex'), 'fitness_connection', 'synthetic-retain-v1',
     now() + interval '365 days'),
    (raw_viewer_9, viewer_user_id, viewer_ingestion_id, 'healthkit', 'workout',
     ((workout_start_day + 10)::timestamp + interval '13 hours') at time zone 'UTC',
     repeat(md5('hmac-v9'), 2),
     repeat(md5('fitness-v9'), 2), 'key_synthetic_v1',
     decode(repeat('19', 16), 'hex'), 'fitness_connection', 'synthetic-retain-v1',
     now() + interval '365 days'),
    (raw_viewer_10, viewer_user_id, viewer_ingestion_id, 'healthkit', 'workout',
     ((workout_start_day + 17)::timestamp + interval '13 hours') at time zone 'UTC',
     repeat(md5('hmac-v10'), 2),
     repeat(md5('fitness-v10'), 2), 'key_synthetic_v1',
     decode(repeat('1a', 16), 'hex'), 'fitness_connection', 'synthetic-retain-v1',
     now() + interval '365 days'),
    (raw_viewer_old, viewer_user_id, viewer_ingestion_id, 'healthkit', 'workout',
     ((workout_start_day - 50)::timestamp + interval '7 hours') at time zone 'UTC',
     repeat(md5('hmac-v-old'), 2),
     repeat(md5('fitness-v-old'), 2), 'key_synthetic_v1',
     decode(repeat('1b', 16), 'hex'), 'fitness_connection', 'synthetic-retain-v1',
     now() + interval '365 days'),
    (raw_subject_1, subject_user_id, subject_ingestion_id, 'healthkit', 'workout',
     ((workout_start_day + 1)::timestamp + interval '7 hours') at time zone 'UTC',
     repeat(md5('hmac-s1'), 2),
     repeat(md5('fitness-s1'), 2), 'key_synthetic_v1',
     decode(repeat('55', 16), 'hex'), 'fitness_connection', 'synthetic-retain-v1',
     now() + interval '365 days'),
    (raw_subject_2, subject_user_id, subject_ingestion_id, 'healthkit', 'workout',
     ((workout_start_day + 8)::timestamp + interval '7 hours') at time zone 'UTC',
     repeat(md5('hmac-s2'), 2),
     repeat(md5('fitness-s2'), 2), 'key_synthetic_v1',
     decode(repeat('66', 16), 'hex'), 'fitness_connection', 'synthetic-retain-v1',
     now() + interval '365 days'),
    (raw_subject_3, subject_user_id, subject_ingestion_id, 'healthkit', 'workout',
     ((workout_start_day + 15)::timestamp + interval '7 hours') at time zone 'UTC',
     repeat(md5('hmac-s3'), 2),
     repeat(md5('fitness-s3'), 2), 'key_synthetic_v1',
     decode(repeat('77', 16), 'hex'), 'fitness_connection', 'synthetic-retain-v1',
     now() + interval '365 days'),
    (raw_subject_4, subject_user_id, subject_ingestion_id, 'healthkit', 'workout',
     ((workout_start_day + 22)::timestamp + interval '7 hours') at time zone 'UTC',
     repeat(md5('hmac-s4'), 2),
     repeat(md5('fitness-s4'), 2), 'key_synthetic_v1',
     decode(repeat('88', 16), 'hex'), 'fitness_connection', 'synthetic-retain-v1',
     now() + interval '365 days'),
    (raw_subject_5, subject_user_id, subject_ingestion_id, 'healthkit', 'workout',
     ((workout_start_day + 3)::timestamp + interval '7 hours') at time zone 'UTC',
     repeat(md5('hmac-s5'), 2),
     repeat(md5('fitness-s5'), 2), 'key_synthetic_v1',
     decode(repeat('75', 16), 'hex'), 'fitness_connection', 'synthetic-retain-v1',
     now() + interval '365 days'),
    (raw_subject_6, subject_user_id, subject_ingestion_id, 'healthkit', 'workout',
     ((workout_start_day + 10)::timestamp + interval '7 hours') at time zone 'UTC',
     repeat(md5('hmac-s6'), 2),
     repeat(md5('fitness-s6'), 2), 'key_synthetic_v1',
     decode(repeat('76', 16), 'hex'), 'fitness_connection', 'synthetic-retain-v1',
     now() + interval '365 days'),
    (raw_subject_7, subject_user_id, subject_ingestion_id, 'healthkit', 'workout',
     ((workout_start_day + 4)::timestamp + interval '13 hours') at time zone 'UTC',
     repeat(md5('hmac-s7'), 2),
     repeat(md5('fitness-s7'), 2), 'key_synthetic_v1',
     decode(repeat('7a', 16), 'hex'), 'fitness_connection', 'synthetic-retain-v1',
     now() + interval '365 days'),
    (raw_subject_8, subject_user_id, subject_ingestion_id, 'healthkit', 'workout',
     ((workout_start_day + 11)::timestamp + interval '13 hours') at time zone 'UTC',
     repeat(md5('hmac-s8'), 2),
     repeat(md5('fitness-s8'), 2), 'key_synthetic_v1',
     decode(repeat('7b', 16), 'hex'), 'fitness_connection', 'synthetic-retain-v1',
     now() + interval '365 days'),
    (raw_subject_9, subject_user_id, subject_ingestion_id, 'healthkit', 'workout',
     ((workout_start_day + 18)::timestamp + interval '13 hours') at time zone 'UTC',
     repeat(md5('hmac-s9'), 2),
     repeat(md5('fitness-s9'), 2), 'key_synthetic_v1',
     decode(repeat('7c', 16), 'hex'), 'fitness_connection', 'synthetic-retain-v1',
     now() + interval '365 days'),
    (raw_subject_10, subject_user_id, subject_ingestion_id, 'healthkit', 'workout',
     ((workout_start_day + 23)::timestamp + interval '13 hours') at time zone 'UTC',
     repeat(md5('hmac-s10'), 2),
     repeat(md5('fitness-s10'), 2), 'key_synthetic_v1',
     decode(repeat('7d', 16), 'hex'), 'fitness_connection', 'synthetic-retain-v1',
     now() + interval '365 days');

  insert into semantic_private.raw_source_records (
    id, user_id, ingestion_run_id, source_code, data_type, occurred_at,
    source_item_hmac, record_fingerprint, encryption_key_version,
    encrypted_payload, consent_purpose, retention_policy_version,
    retained_until
  ) values (
    raw_lifecycle_id, viewer_user_id, viewer_ingestion_id, 'healthkit',
    'activity_day', workout_window_end,
    repeat(md5('hmac-lifecycle'), 2),
    repeat(md5('record-lifecycle'), 2), 'key_synthetic_v1',
    decode(repeat('bc', 16), 'hex'), 'fitness_connection',
    'synthetic-retain-v1', now() + interval '30 days'
  );
  begin
    update semantic_private.raw_source_records
    set retained_until = retained_until + interval '1 day'
    where id = raw_lifecycle_id;
    raise exception 'raw-record retention was extended without renewed provenance';
  exception
    when raise_exception then
      if sqlerrm = 'raw-record retention was extended without renewed provenance' then
        raise;
      end if;
  end;
  update semantic_private.raw_source_records
  set lifecycle_state = 'deleted', encrypted_payload = null,
      deleted_at = now()
  where id = raw_lifecycle_id;
  begin
    update semantic_private.raw_source_records
    set lifecycle_state = 'active',
        encrypted_payload = decode(repeat('bc', 16), 'hex'),
        deleted_at = null
    where id = raw_lifecycle_id;
    raise exception 'deleted raw record was resurrected';
  exception
    when raise_exception then
      if sqlerrm = 'deleted raw record was resurrected' then raise; end if;
  end;

  begin
    insert into semantic_private.raw_source_records (
      user_id, ingestion_run_id, source_code, data_type, source_item_hmac,
      record_fingerprint, encryption_key_version, encrypted_payload,
      raw_blob_ref, consent_purpose, retention_policy_version
    ) values (
      viewer_user_id, viewer_ingestion_id, 'healthkit', 'workout',
      repeat(md5('hmac-invalid-both'), 2),
      repeat(md5('fitness-invalid-both'), 2),
      'key_synthetic_v1', decode(repeat('99', 16), 'hex'),
      'vault/' || repeat('9', 64),
      'fitness_connection', 'synthetic-retain-v1'
    );
    raise exception 'raw vault accepted two payload locations';
  exception
    when check_violation then null;
  end;

  begin
    insert into semantic_private.raw_source_records (
      user_id, ingestion_run_id, source_code, data_type, source_item_hmac,
      record_fingerprint, encryption_key_version, encrypted_payload,
      consent_purpose, retention_policy_version
    ) values (
      viewer_user_id, viewer_ingestion_id, 'healthkit', 'workout',
      repeat(md5('hmac-invalid-short'), 2),
      repeat(md5('fitness-invalid-short'), 2),
      'key_synthetic_v1',
      decode('0102', 'hex'), 'fitness_connection', 'synthetic-retain-v1'
    );
    raise exception 'raw vault accepted undersized ciphertext';
  exception
    when check_violation then null;
  end;

  begin
    insert into semantic_private.raw_source_records (
      user_id, ingestion_run_id, source_code, data_type, source_item_hmac,
      record_fingerprint, encryption_key_version, encrypted_payload,
      consent_purpose, retention_policy_version
    ) values (
      viewer_user_id, viewer_ingestion_id, 'healthkit', 'workout',
      repeat(md5('hmac-invalid-purpose'), 2),
      repeat(md5('fitness-invalid-purpose'), 2),
      'key_synthetic_v1',
      decode(repeat('aa', 16), 'hex'), 'source_distillation',
      'synthetic-retain-v1'
    );
    raise exception 'HealthKit raw record accepted a non-fitness purpose';
  exception
    when check_violation then null;
  end;

  begin
    insert into semantic_private.raw_source_records (
      user_id, ingestion_run_id, source_code, data_type, source_item_hmac,
      record_fingerprint, encryption_key_version, raw_blob_ref,
      consent_purpose, retention_policy_version
    ) values (
      viewer_user_id, viewer_ingestion_id, 'healthkit', 'workout title',
      'synthetic plaintext identity',
      repeat(md5('fitness-invalid-plaintext'), 2),
      'key_synthetic_v1', 'https://vault.invalid/private?label=plaintext',
      'fitness_connection', 'synthetic-retain-v1'
    );
    raise exception 'raw vault accepted plaintext identity fields or a URL blob reference';
  exception
    when check_violation then null;
  end;

  -- Both new sanitized privacy classes are storable, while the private-source
  -- payload firewall rejects arbitrary/raw root keys.
  insert into semantic_private.observations (
    id, user_id, ingestion_run_id, source_code, data_type, observation_kind,
    action_type, occurred_at, source_item_hmac, record_fingerprint,
    payload_schema_version, normalized_payload, field_quality, action_weight,
    privacy_class, allow_external_resolution
  ) values
    (calendar_observation_id, viewer_user_id, calendar_ingestion_id,
     'apple_calendar', 'calendar_event', 'sanitized_classification', 'scheduled',
     '2026-02-01T00:00:00Z', repeat(md5('obs-hmac-calendar'), 2),
     repeat(md5('obs-fingerprint-calendar'), 2), 'calendar-v03',
     '{"schema_version":"calendar-v03","record_kind":"calendar_classification","classification_state":"excluded"}'::jsonb,
     1.0, 0.0, 'private_calendar_sanitized', false);

  begin
    insert into semantic_private.observations (
      user_id, ingestion_run_id, source_code, data_type, observation_kind,
      action_type, occurred_at, source_item_hmac, record_fingerprint,
      payload_schema_version, normalized_payload, field_quality, action_weight,
      privacy_class, allow_external_resolution
    ) values (
      viewer_user_id, calendar_ingestion_id, 'apple_calendar',
      'calendar_event', 'sanitized_classification', 'scheduled', now(),
      repeat(md5('obs-hmac-calendar-hidden-schema'), 2),
      repeat(md5('obs-fingerprint-calendar-hidden-schema'), 2),
      'calendar-v03',
      '{"schema_version":"synthetic-private-caption","record_kind":"calendar_classification","classification_state":"review"}'::jsonb,
      1.0, 0.0, 'private_calendar_sanitized', false
    );
    raise exception 'Calendar raw text hid under an allowed schema key';
  exception
    when check_violation then null;
    when raise_exception then
      if sqlerrm = 'Calendar raw text hid under an allowed schema key' then
        raise;
      end if;
  end;

  begin
    insert into semantic_private.observations (
      user_id, ingestion_run_id, source_code, data_type, observation_kind,
      action_type, occurred_at, source_item_hmac, record_fingerprint,
      content_lineage_hmac, payload_schema_version, normalized_payload,
      field_quality, action_weight, privacy_class,
      allow_external_resolution
    ) values (
      viewer_user_id, calendar_ingestion_id, 'apple_calendar',
      'calendar_event', 'sanitized_classification', 'booked', now(),
      repeat(md5('obs-hmac-calendar-hidden-artifact'), 2),
      repeat(md5('obs-fingerprint-calendar-hidden-artifact'), 2),
      repeat(md5('obs-lineage-calendar-hidden-artifact'), 2),
      'calendar-v03',
      '{"schema_version":"calendar-v03","record_kind":"calendar_classification","classification_state":"candidate","artifact_type":"synthetic_private_caption"}'::jsonb,
      1.0, 0.0, 'private_calendar_sanitized', false
    );
    raise exception 'Calendar raw text hid under an allowed artifact key';
  exception
    when check_violation then null;
    when raise_exception then
      if sqlerrm = 'Calendar raw text hid under an allowed artifact key' then
        raise;
      end if;
  end;

  begin
    update semantic_private.observations
    set lifecycle_state = 'excluded',
        exclusion_code = 'Synthetic private calendar caption',
        excluded_at = now()
    where id = calendar_observation_id;
    raise exception 'Calendar raw text hid in an adjacent exclusion column';
  exception
    when check_violation then null;
    when raise_exception then
      if sqlerrm = 'Calendar raw text hid in an adjacent exclusion column' then
        raise;
      end if;
  end;

  begin
    insert into semantic_private.observations (
      id, user_id, ingestion_run_id, source_code, data_type, observation_kind,
      action_type, occurred_at, source_item_hmac, record_fingerprint,
      payload_schema_version, normalized_payload, field_quality, action_weight,
      privacy_class, allow_external_resolution
    ) values (
      raw_health_observation_id, viewer_user_id, viewer_ingestion_id,
      'healthkit', 'workout', 'raw_action', 'workout',
      '2026-01-05T07:00:00Z', repeat(md5('obs-hmac-raw-health'), 2),
      repeat(md5('obs-fingerprint-raw-health'), 2), 'synthetic-v1',
      '{"schema_version":"synthetic-v1","record_kind":"workout","classification_state":"raw"}'::jsonb,
      1.0, 0.0, 'private_fitness_sanitized', false
    );
    raise exception 'raw HealthKit sample entered the semantic observation table';
  exception
    when raise_exception then
      if sqlerrm = 'raw HealthKit sample entered the semantic observation table' then
        raise;
      end if;
  end;

  insert into semantic_private.observations (
    id, user_id, ingestion_run_id, source_code, data_type, observation_kind,
    action_type, occurred_at, source_item_hmac, record_fingerprint,
    content_lineage_hmac, payload_schema_version, normalized_payload,
    field_quality, action_weight, privacy_class, allow_external_resolution
  ) values (
    calendar_semantic_observation_id, viewer_user_id, calendar_ingestion_id,
    'apple_calendar', 'calendar_event', 'sanitized_classification', 'booked',
    now(), repeat(md5('obs-hmac-calendar-semantic'), 2),
    repeat(md5('obs-fingerprint-calendar-semantic'), 2), calendar_lineage,
    'calendar-v03',
    '{"schema_version":"calendar-v03","record_kind":"calendar_classification","classification_state":"candidate","artifact_type":"public_ticket"}'::jsonb,
    1.0, 0.0, 'private_calendar_sanitized', false
  );

  begin
    insert into semantic_private.observation_mentions (
      observation_id, user_id, mention_text, normalized_text, mention_role,
      source_field, extraction_method, confidence,
      safe_for_global_mining, safe_for_external_resolution
    ) values (
      calendar_semantic_observation_id, viewer_user_id,
      'Synthetic Private Caption', 'synthetic private caption',
      'generic_topic', 'sanitized_projection', 'synthetic', 0.99,
      true, false
    );
    raise exception 'Calendar text entered the generic mention/mining lane';
  exception
    when raise_exception then
      if sqlerrm = 'Calendar text entered the generic mention/mining lane' then
        raise;
      end if;
  end;

  begin
    insert into semantic_private.observations (
      user_id, ingestion_run_id, source_code, data_type, observation_kind,
      action_type, source_item_hmac, record_fingerprint,
      payload_schema_version, normalized_payload, privacy_class
    ) values (
      viewer_user_id, viewer_ingestion_id, 'healthkit', 'fitness_habit',
      'routine_projection', 'routine', repeat(md5('obs-hmac-invalid-privacy'), 2),
      repeat(md5('obs-fingerprint-invalid-privacy'), 2), 'synthetic-v1',
      '{"record_kind":"fitness_habit"}'::jsonb, 'private_health_raw'
    );
    raise exception 'unknown private observation class was accepted';
  exception
    when check_violation then null;
    when raise_exception then
      if sqlerrm = 'unknown private observation class was accepted' then
        raise;
      end if;
  end;

  begin
    insert into semantic_private.observations (
      user_id, ingestion_run_id, source_code, data_type, observation_kind,
      action_type, source_item_hmac, record_fingerprint,
      payload_schema_version, normalized_payload, privacy_class
    ) values (
      viewer_user_id, viewer_ingestion_id, 'healthkit', 'fitness_habit',
      'routine_projection', 'routine', repeat(md5('obs-hmac-invalid-payload'), 2),
      repeat(md5('obs-fingerprint-invalid-payload'), 2), 'synthetic-v1',
      '{"record_kind":"fitness_habit","title":"synthetic forbidden raw field"}'::jsonb,
      'private_fitness_sanitized'
    );
    raise exception 'raw private payload key passed the observation firewall';
  exception
    when check_violation then null;
    when raise_exception then
      if sqlerrm = 'raw private payload key passed the observation firewall' then
        raise;
      end if;
  end;

  -- Calendar classification may inspect broad private input, but its durable
  -- feature JSON and every product label are rebuilt from controlled columns
  -- and active ontology labels. Allowed key names do not authorize raw values.
  begin
    insert into semantic_private.calendar_event_classifications (
      observation_id, user_id, classifier_model_id, event_class, disposition,
      mapping_agreement, evidence_quality, feature_snapshot,
      ontology_version_id, input_revision
    ) values (
      calendar_semantic_observation_id, viewer_user_id,
      calendar_classifier_model_id, 'public_ticketed_event',
      'eligible_private_semantics', 0.97, 0.95,
      '{"reason_codes":["Synthetic Private Caption"]}'::jsonb,
      published_version_id, 1
    );
    raise exception 'stale-revision Calendar classification was accepted';
  exception
    when raise_exception then
      if sqlerrm = 'stale-revision Calendar classification was accepted' then
        raise;
      end if;
  end;

  insert into semantic_private.calendar_event_classifications (
    id, observation_id, user_id, classifier_model_id, event_class,
    disposition, mapping_agreement, evidence_quality, feature_snapshot,
    ontology_version_id, input_revision
  ) values (
    calendar_classification_id, calendar_semantic_observation_id,
    viewer_user_id, calendar_classifier_model_id, 'public_ticketed_event',
    'eligible_private_semantics', 0.97, 0.95,
    '{"reason_codes":["Synthetic Private Caption"]}'::jsonb,
    published_version_id, 0
  );
  if exists (
    select 1 from semantic_private.calendar_event_classifications
    where id = calendar_classification_id
      and feature_snapshot::text like '%Synthetic Private Caption%'
  ) then
    raise exception 'raw Calendar value survived controlled classifier JSON';
  end if;

  begin
    insert into semantic_private.booked_activity_candidates (
      user_id, calendar_classification_id, source_observation_id,
      ontology_version_id, predicate_key, target_concept_id, place_concept_id,
      booking_lineage_hmac, action_semantics, booking_state,
      strength, mapping_agreement, evidence_quality, display_payload
    ) values (
      viewer_user_id, calendar_classification_id,
      calendar_semantic_observation_id, published_version_id, 'booked_event',
      booked_event_hub_id, running_concept_id, calendar_lineage,
      'booked', 'planned', 0.90, 0.97, 0.95,
      '{"target_label":"Synthetic Private Caption"}'::jsonb
    );
    raise exception 'non-place concept was accepted as a Calendar place';
  exception
    when raise_exception then
      if sqlerrm = 'non-place concept was accepted as a Calendar place' then
        raise;
      end if;
  end;

  insert into semantic_private.booked_activity_candidates (
    id, user_id, calendar_classification_id, source_observation_id,
    ontology_version_id, predicate_key, target_concept_id,
    booking_lineage_hmac, action_semantics, booking_state,
    strength, mapping_agreement, evidence_quality, recency_weight,
    recency_quality, recency_policy_version, recency_rule_id,
    recency_status, recency_timestamp_quality, recency_as_of, display_payload
  ) values (
    calendar_candidate_id, viewer_user_id, calendar_classification_id,
    calendar_semantic_observation_id, published_version_id, 'booked_event',
    booked_event_hub_id, calendar_lineage, 'booked', 'planned',
    0.90, 0.97, 0.95, 0.90, 1.0, 'written-recency-v1.0.0',
    'calendar.scheduled.anticipation', 'future_anticipation', 'known', now(),
    '{"template_key":"booked_event","target_label":"Synthetic Private Caption"}'::jsonb
  );
  if not exists (
    select 1
    from semantic_private.booked_activity_candidates as candidate
    join ontology.concept_revisions as revision
      on revision.ontology_version_id = candidate.ontology_version_id
     and revision.concept_id = candidate.target_concept_id
    where candidate.id = calendar_candidate_id
      and candidate.target_concept_kind = 'hub'
      and candidate.display_payload ->> 'target_label' = revision.preferred_label
      and candidate.display_payload ->> 'predicate_label' = 'Booked event'
      and candidate.display_payload::text not like '%Synthetic Private Caption%'
  ) then
    raise exception 'Calendar candidate label was not canonically rendered';
  end if;

  insert into semantic_private.memories_snapshots (
    id, user_id, ontology_version_id, builder_model_id, input_revision,
    presentation_version, state
  ) values (
    calendar_memories_snapshot_id, viewer_user_id, published_version_id,
    memories_builder_model_id, 0, 'calendar-v03-contract', 'building'
  );
  insert into semantic_private.memories_snapshot_items (
    id, snapshot_id, user_id, booked_activity_candidate_id, item_key,
    item_kind, display_label, rank, display_payload
  ) values (
    calendar_memories_item_id, calendar_memories_snapshot_id, viewer_user_id,
    calendar_candidate_id, 'calendar-v03-booked-item',
    'booked_activity_candidate', 'Synthetic Private Caption', 0,
    '{"target_label":"Synthetic Private Caption","subtitle":"Synthetic Private Caption"}'::jsonb
  );
  if not exists (
    select 1
    from semantic_private.memories_snapshot_items as item
    join semantic_private.booked_activity_candidates as candidate
      on candidate.id = item.booked_activity_candidate_id
     and candidate.user_id = item.user_id
    where item.id = calendar_memories_item_id
      and item.display_label = 'Booked event: ' ||
        (candidate.display_payload ->> 'target_label')
      and item.display_payload = candidate.display_payload
      and item.display_payload::text not like '%Synthetic Private Caption%'
  ) then
    raise exception 'Calendar Memory retained a worker-supplied raw label';
  end if;

  -- Snapshots must use the active builder. Aggregate-only coverage must
  -- abstain, and only the explicit fitness/routine concept allowlist is valid.
  begin
    insert into semantic_private.fitness_feature_snapshots (
      user_id, input_revision, builder_model_id, policy_version,
      window_end_at,
      coverage_state, accepted_record_count, rejected_record_count,
      activity_day_count, activity_hour_count, workout_count,
      sleep_session_count, state, finalized_at
    ) values (
      viewer_user_id, 0, ranker_model_id, fitness_policy, workout_window_end,
      'workout_typed', 4, 0, 0, 0, 4, 0, 'ready', now()
    );
    raise exception 'fitness snapshot accepted a non-builder model role';
  exception
    when raise_exception then
      if sqlerrm = 'fitness snapshot accepted a non-builder model role' then raise; end if;
  end;

  begin
    insert into semantic_private.fitness_feature_snapshots (
      user_id, input_revision, builder_model_id, policy_version,
      window_end_at,
      coverage_state, accepted_record_count, rejected_record_count,
      activity_day_count, activity_hour_count, workout_count,
      sleep_session_count, feature_payload, state, finalized_at
    ) values (
      viewer_user_id, 0, builder_model_id, fitness_policy, workout_window_end,
      'aggregate_only', 1, 0, 1, 0, 0, 0,
      '{"activity_days":[{"date":"2026-01-01","steps":1234}]}'::jsonb,
      'ready', now()
    );
    raise exception 'fitness snapshot persisted private feature detail';
  exception
    when check_violation then null;
  end;

  begin
    insert into semantic_private.fitness_feature_snapshots (
      user_id, input_revision, builder_model_id, policy_version,
      window_end_at, coverage_state, accepted_record_count,
      rejected_record_count, activity_day_count, activity_hour_count,
      workout_count, sleep_session_count, state, finalized_at
    ) values (
      aggregate_user_id, 1, builder_model_id, fitness_policy,
      workout_window_end, 'aggregate_only', 1, 0, 1, 0, 0, 0,
      'ready', now()
    );
    raise exception 'fitness snapshot accepted a stale input revision';
  exception
    when raise_exception then
      if sqlerrm = 'fitness snapshot accepted a stale input revision' then raise; end if;
  end;

  insert into semantic_private.fitness_feature_snapshots (
    id, user_id, input_revision, builder_model_id, policy_version,
    window_end_at,
    coverage_state, accepted_record_count, rejected_record_count,
    activity_day_count, activity_hour_count, workout_count,
    sleep_session_count, feature_payload, state, finalized_at
  ) values
    (viewer_snapshot_id, viewer_user_id, 0, builder_model_id,
     fitness_policy, workout_window_end, 'workout_typed', 10, 0, 0, 0, 10, 0,
     '{}'::jsonb,
     'ready', now()),
    (subject_snapshot_id, subject_user_id, 0, builder_model_id,
     fitness_policy, workout_window_end, 'workout_typed', 10, 0, 0, 0, 10, 0,
     '{}'::jsonb,
     'ready', now()),
    (aggregate_snapshot_id, aggregate_user_id, 0, builder_model_id,
     fitness_policy, workout_window_end, 'aggregate_only', 389, 0, 365, 24, 0, 0,
     '{}'::jsonb,
     'ready', now());

  begin
    insert into semantic_private.fitness_habit_candidates (
      user_id, feature_snapshot_id, ontology_version_id, concept_id,
      candidate_kind, controlled_label, support_record_count,
      distinct_day_count, distinct_week_count, last_supported_at,
      mapping_agreement, evidence_quality, policy_version, window_end_at,
      derivation_as_of, expires_at
    ) values (
      aggregate_user_id, aggregate_snapshot_id, published_version_id,
      running_concept_id, 'activity_routine', 'Running', 4, 4, 3,
      workout_window_end, 0.95, 0.95, fitness_policy, workout_window_end,
      now(), now() + interval '7 days'
    );
    raise exception 'aggregate-only snapshot emitted a fitness candidate';
  exception
    when raise_exception then
      if sqlerrm = 'aggregate-only snapshot emitted a fitness candidate' then raise; end if;
  end;

  begin
    insert into semantic_private.fitness_habit_candidates (
      user_id, feature_snapshot_id, ontology_version_id, concept_id,
      candidate_kind, controlled_label, support_record_count,
      distinct_day_count, distinct_week_count, last_supported_at,
      mapping_agreement, evidence_quality, policy_version, window_end_at,
      derivation_as_of, expires_at
    ) values (
      viewer_user_id, viewer_snapshot_id, published_version_id,
      italy_concept_id, 'activity_routine', 'Italy',
      4, 4, 3,
      ((workout_start_day + 21)::timestamp + interval '7 hours') at time zone 'UTC',
      0.95, 0.95, fitness_policy, workout_window_end,
      now(), now() + interval '7 days'
    );
    raise exception 'unallowlisted concept became a fitness routine';
  exception
    when raise_exception then
      if sqlerrm = 'unallowlisted concept became a fitness routine' then raise; end if;
  end;

  begin
    insert into semantic_private.fitness_habit_candidates (
      user_id, feature_snapshot_id, ontology_version_id, concept_id,
      candidate_kind, controlled_label, support_record_count,
      distinct_day_count, distinct_week_count, last_supported_at,
      mapping_agreement, evidence_quality, policy_version, window_end_at,
      derivation_as_of, expires_at
    ) values (
      viewer_user_id, viewer_snapshot_id, published_version_id,
      running_concept_id, 'activity_routine', 'Runs regularly', 4, 4, 4,
      ((workout_start_day + 21)::timestamp + interval '7 hours') at time zone 'UTC',
      0.98, 0.96, fitness_policy, workout_window_end,
      now(), now() + interval '7 days'
    );
    raise exception 'fitness candidate accepted a noncanonical controlled label';
  exception
    when raise_exception then
      if sqlerrm = 'fitness candidate accepted a noncanonical controlled label' then raise; end if;
  end;

  insert into semantic_private.fitness_habit_candidates (
    id, user_id, feature_snapshot_id, ontology_version_id, concept_id,
    candidate_kind, controlled_label, support_record_count,
    distinct_day_count, distinct_week_count, last_supported_at,
    mapping_agreement, evidence_quality, policy_version, window_end_at,
    derivation_as_of, expires_at
  ) values
    (viewer_candidate_id, viewer_user_id, viewer_snapshot_id,
     published_version_id, running_concept_id, 'activity_routine',
     'Running', 4, 4, 4,
     ((workout_start_day + 21)::timestamp + interval '7 hours') at time zone 'UTC',
     0.98, 0.96, fitness_policy, workout_window_end,
     now(), now() + interval '7 days'),
    (subject_candidate_id, subject_user_id, subject_snapshot_id,
     published_version_id, walking_concept_id, 'activity_routine',
     'Walking', 4, 4, 4,
     ((workout_start_day + 22)::timestamp + interval '7 hours') at time zone 'UTC',
     0.97, 0.95, fitness_policy, workout_window_end,
     now(), now() + interval '7 days'),
    (daypart_candidate_id, viewer_user_id, viewer_snapshot_id,
     published_version_id, morning_concept_id, 'workout_daypart',
     'Morning workouts', 7, 7, 4,
     ((workout_start_day + 21)::timestamp + interval '7 hours') at time zone 'UTC',
     1.0, 0.70, fitness_policy, workout_window_end,
     now(), now() + interval '7 days');

  insert into semantic_private.fitness_candidate_support (
    candidate_id, user_id, raw_source_record_id, support_role,
    attested_builder_model_id, attested_input_revision,
    attested_policy_version, activity_concept_id, coarse_daypart,
    utc_offset_minutes, supports_candidate, support_day, support_week_start
  ) values
    (viewer_candidate_id, viewer_user_id, raw_viewer_1, 'workout_session',
     builder_model_id, 0, fitness_policy, running_concept_id, 'morning',
     0, true, workout_start_day, workout_start_day),
    (viewer_candidate_id, viewer_user_id, raw_viewer_2, 'workout_session',
     builder_model_id, 0, fitness_policy, running_concept_id, 'morning',
     0, true, workout_start_day + 7, workout_start_day + 7),
    (viewer_candidate_id, viewer_user_id, raw_viewer_3, 'workout_session',
     builder_model_id, 0, fitness_policy, running_concept_id, 'morning',
     0, true, workout_start_day + 14, workout_start_day + 14),
    (viewer_candidate_id, viewer_user_id, raw_viewer_4, 'workout_session',
     builder_model_id, 0, fitness_policy, running_concept_id, 'morning',
     0, true, workout_start_day + 21, workout_start_day + 21),
    (subject_candidate_id, subject_user_id, raw_subject_1, 'workout_session',
     builder_model_id, 0, fitness_policy, walking_concept_id, 'morning',
     0, true, workout_start_day + 1, workout_start_day),
    (subject_candidate_id, subject_user_id, raw_subject_2, 'workout_session',
     builder_model_id, 0, fitness_policy, walking_concept_id, 'morning',
     0, true, workout_start_day + 8, workout_start_day + 7),
    (subject_candidate_id, subject_user_id, raw_subject_3, 'workout_session',
     builder_model_id, 0, fitness_policy, walking_concept_id, 'morning',
     0, true, workout_start_day + 15, workout_start_day + 14),
    (subject_candidate_id, subject_user_id, raw_subject_4, 'workout_session',
     builder_model_id, 0, fitness_policy, walking_concept_id, 'morning',
     0, true, workout_start_day + 22, workout_start_day + 21),
    (daypart_candidate_id, viewer_user_id, raw_viewer_1, 'workout_session',
     builder_model_id, 0, fitness_policy, running_concept_id, 'morning',
     0, true, workout_start_day, workout_start_day),
    (daypart_candidate_id, viewer_user_id, raw_viewer_2, 'workout_session',
     builder_model_id, 0, fitness_policy, running_concept_id, 'morning',
     0, true, workout_start_day + 7, workout_start_day + 7),
    (daypart_candidate_id, viewer_user_id, raw_viewer_3, 'workout_session',
     builder_model_id, 0, fitness_policy, running_concept_id, 'morning',
     0, true, workout_start_day + 14, workout_start_day + 14),
    (daypart_candidate_id, viewer_user_id, raw_viewer_4, 'workout_session',
     builder_model_id, 0, fitness_policy, running_concept_id, 'morning',
     0, true, workout_start_day + 21, workout_start_day + 21),
    (daypart_candidate_id, viewer_user_id, raw_viewer_5, 'workout_session',
     builder_model_id, 0, fitness_policy, running_concept_id, 'morning',
     0, true, workout_start_day + 2, workout_start_day),
    (daypart_candidate_id, viewer_user_id, raw_viewer_6, 'workout_session',
     builder_model_id, 0, fitness_policy, running_concept_id, 'morning',
     0, true, workout_start_day + 9, workout_start_day + 7),
    (daypart_candidate_id, viewer_user_id, raw_viewer_7, 'workout_session',
     builder_model_id, 0, fitness_policy, running_concept_id, 'morning',
     0, true, workout_start_day + 16, workout_start_day + 14),
    (daypart_candidate_id, viewer_user_id, raw_viewer_8, 'workout_session',
     builder_model_id, 0, fitness_policy, running_concept_id, 'afternoon',
     0, false, workout_start_day + 3, workout_start_day),
    (daypart_candidate_id, viewer_user_id, raw_viewer_9, 'workout_session',
     builder_model_id, 0, fitness_policy, running_concept_id, 'afternoon',
     0, false, workout_start_day + 10, workout_start_day + 7),
    (daypart_candidate_id, viewer_user_id, raw_viewer_10, 'workout_session',
     builder_model_id, 0, fitness_policy, running_concept_id, 'afternoon',
     0, false, workout_start_day + 17, workout_start_day + 14);

  begin
    insert into semantic_private.fitness_candidate_support (
      candidate_id, user_id, raw_source_record_id, support_role,
      attested_builder_model_id, attested_input_revision,
      attested_policy_version, activity_concept_id, coarse_daypart,
      utc_offset_minutes, supports_candidate, support_day, support_week_start
    ) values (
      viewer_candidate_id, viewer_user_id, raw_subject_1, 'workout_session',
      builder_model_id, 0, fitness_policy, running_concept_id, 'morning',
      0, true, workout_start_day + 1, workout_start_day
    );
    raise exception 'candidate accepted another user''s raw support';
  exception
    when foreign_key_violation then null;
  end;

  set constraints all immediate;
  set constraints all deferred;

  if not semantic_private.fitness_candidate_is_current(
       viewer_candidate_id, viewer_user_id
     ) or not semantic_private.fitness_candidate_is_current(
       subject_candidate_id, subject_user_id
     ) or not semantic_private.fitness_candidate_is_current(
       daypart_candidate_id, viewer_user_id
     ) then
    raise exception 'validated fitness candidates did not become current';
  end if;

  begin
    insert into semantic_private.raw_source_records (
      id, user_id, ingestion_run_id, source_code, data_type, occurred_at,
      source_item_hmac, record_fingerprint, encryption_key_version,
      encrypted_payload, consent_purpose, retention_policy_version,
      retained_until
    )
    select ontology.stable_uuid('written:test:v0.3-conflicting-workout-revision'),
           raw.user_id, raw.ingestion_run_id, raw.source_code, raw.data_type,
           raw.occurred_at + interval '1 minute', raw.source_item_hmac,
           repeat(md5('conflicting-workout-revision'), 2),
           raw.encryption_key_version, decode(repeat('cd', 16), 'hex'),
           raw.consent_purpose, raw.retention_policy_version,
           raw.retained_until
    from semantic_private.raw_source_records as raw
    where raw.id = raw_viewer_1;
    update semantic_private.fitness_candidate_support
    set created_at = created_at
    where candidate_id = viewer_candidate_id
      and raw_source_record_id = raw_viewer_1;
    set constraints all immediate;
    raise exception 'conflicting provider-item revisions remained promotable';
  exception
    when raise_exception then
      if sqlerrm = 'conflicting provider-item revisions remained promotable' then
        raise;
      end if;
  end;
  set constraints all deferred;

  begin
    update semantic_private.fitness_candidate_support
    set support_day = '2026-02-02', support_week_start = '2026-02-02'
    where candidate_id = viewer_candidate_id
      and raw_source_record_id = raw_viewer_1;
    set constraints all immediate;
    raise exception 'fitness support accepted a forged recurrence day/week';
  exception
    when raise_exception then
      if sqlerrm = 'fitness support accepted a forged recurrence day/week' then
        raise;
      end if;
  end;
  set constraints all deferred;

  begin
    delete from semantic_private.fitness_candidate_support
    where candidate_id = daypart_candidate_id
      and raw_source_record_id = raw_viewer_10;
    set constraints all immediate;
    raise exception 'daypart denominator omitted an eligible workout';
  exception
    when raise_exception then
      if sqlerrm = 'daypart denominator omitted an eligible workout' then raise; end if;
  end;
  set constraints all deferred;

  begin
    update semantic_private.fitness_candidate_support
    set activity_concept_id = walking_concept_id
    where candidate_id = viewer_candidate_id
      and raw_source_record_id = raw_viewer_1;
    set constraints all immediate;
    raise exception 'activity routine accepted mixed activity support';
  exception
    when raise_exception then
      if sqlerrm = 'activity routine accepted mixed activity support' then raise; end if;
  end;
  set constraints all deferred;

  begin
    update semantic_private.fitness_candidate_support
    set attested_policy_version = 'synthetic-wrong-policy'
    where candidate_id = viewer_candidate_id
      and raw_source_record_id = raw_viewer_1;
    set constraints all immediate;
    raise exception 'fitness support escaped its policy/builder/revision binding';
  exception
    when raise_exception then
      if sqlerrm = 'fitness support escaped its policy/builder/revision binding' then raise; end if;
  end;
  set constraints all deferred;

  begin
    update semantic_private.fitness_candidate_support
    set utc_offset_minutes = -480
    where candidate_id = viewer_candidate_id
      and raw_source_record_id = raw_viewer_1;
    set constraints all immediate;
    raise exception 'fitness support accepted inconsistent local-time attestation';
  exception
    when raise_exception then
      if sqlerrm = 'fitness support accepted inconsistent local-time attestation' then raise; end if;
  end;
  set constraints all deferred;

  begin
    update semantic_private.fitness_candidate_support
    set raw_source_record_id = raw_viewer_old,
        support_day = workout_start_day - 50,
        support_week_start = date_trunc(
          'week', (workout_start_day - 50)::timestamp
        )::date
    where candidate_id = viewer_candidate_id
      and raw_source_record_id = raw_viewer_1;
    set constraints all immediate;
    raise exception 'fitness support accepted a workout outside the 42-day window';
  exception
    when raise_exception then
      if sqlerrm = 'fitness support accepted a workout outside the 42-day window' then raise; end if;
  end;
  set constraints all deferred;

  begin
    insert into semantic_private.fitness_habit_candidates (
      id, user_id, feature_snapshot_id, ontology_version_id, concept_id,
      candidate_kind, controlled_label, support_record_count,
      distinct_day_count, distinct_week_count, last_supported_at,
      mapping_agreement, evidence_quality, policy_version, window_end_at,
      derivation_as_of, expires_at
    ) values (
      weak_daypart_candidate_id, subject_user_id, subject_snapshot_id,
      published_version_id, morning_concept_id, 'workout_daypart',
      'Morning workouts', 6, 6, 4,
      ((workout_start_day + 22)::timestamp + interval '7 hours') at time zone 'UTC',
      1.0, 0.60, fitness_policy, workout_window_end,
      now(), now() + interval '7 days'
    );
    insert into semantic_private.fitness_candidate_support (
      candidate_id, user_id, raw_source_record_id, support_role,
      attested_builder_model_id, attested_input_revision,
      attested_policy_version, activity_concept_id, coarse_daypart,
      utc_offset_minutes, supports_candidate, support_day, support_week_start
    ) values
      (weak_daypart_candidate_id, subject_user_id, raw_subject_1, 'workout_session',
       builder_model_id, 0, fitness_policy, walking_concept_id, 'morning',
       0, true, workout_start_day + 1, workout_start_day),
      (weak_daypart_candidate_id, subject_user_id, raw_subject_2, 'workout_session',
       builder_model_id, 0, fitness_policy, walking_concept_id, 'morning',
       0, true, workout_start_day + 8, workout_start_day + 7),
      (weak_daypart_candidate_id, subject_user_id, raw_subject_3, 'workout_session',
       builder_model_id, 0, fitness_policy, walking_concept_id, 'morning',
       0, true, workout_start_day + 15, workout_start_day + 14),
      (weak_daypart_candidate_id, subject_user_id, raw_subject_4, 'workout_session',
       builder_model_id, 0, fitness_policy, walking_concept_id, 'morning',
       0, true, workout_start_day + 22, workout_start_day + 21),
      (weak_daypart_candidate_id, subject_user_id, raw_subject_5, 'workout_session',
       builder_model_id, 0, fitness_policy, walking_concept_id, 'morning',
       0, true, workout_start_day + 3, workout_start_day),
      (weak_daypart_candidate_id, subject_user_id, raw_subject_6, 'workout_session',
       builder_model_id, 0, fitness_policy, walking_concept_id, 'morning',
       0, true, workout_start_day + 10, workout_start_day + 7),
      (weak_daypart_candidate_id, subject_user_id, raw_subject_7, 'workout_session',
       builder_model_id, 0, fitness_policy, walking_concept_id, 'afternoon',
       0, false, workout_start_day + 4, workout_start_day),
      (weak_daypart_candidate_id, subject_user_id, raw_subject_8, 'workout_session',
       builder_model_id, 0, fitness_policy, walking_concept_id, 'afternoon',
       0, false, workout_start_day + 11, workout_start_day + 7),
      (weak_daypart_candidate_id, subject_user_id, raw_subject_9, 'workout_session',
       builder_model_id, 0, fitness_policy, walking_concept_id, 'afternoon',
       0, false, workout_start_day + 18, workout_start_day + 14),
      (weak_daypart_candidate_id, subject_user_id, raw_subject_10, 'workout_session',
       builder_model_id, 0, fitness_policy, walking_concept_id, 'afternoon',
       0, false, workout_start_day + 23, workout_start_day + 21);
    set constraints all immediate;
    raise exception 'daypart candidate accepted only sixty percent concentration';
  exception
    when raise_exception then
      if sqlerrm = 'daypart candidate accepted only sixty percent concentration' then raise; end if;
  end;
  set constraints all deferred;

  -- Structured sleep is still ingested into the encrypted, typed-private
  -- evidence store. v0.3 deliberately does not promote sleep to an ontology
  -- candidate, even when a connector supplies fourteen regular sessions.
  for i in 0..13 loop
    insert into semantic_private.raw_source_records (
      id, user_id, ingestion_run_id, source_code, data_type, occurred_at,
      source_item_hmac, record_fingerprint, encryption_key_version,
      encrypted_payload, consent_purpose, retention_policy_version,
      retained_until
    ) values (
      ontology.stable_uuid('written:test:v0.3-raw-sleep-' || i::text),
      sleep_user_id, sleep_ingestion_id, 'healthkit', 'sleep_session',
      (
        (sleep_start_day + i)::timestamp
        + interval '22 hours'
        + (i % 2) * interval '10 minutes'
      ) at time zone 'UTC',
      repeat(md5('hmac-sleep-' || i::text), 2),
      repeat(md5('fitness-sleep-' || i::text), 2),
      'key_synthetic_v1', decode(repeat('ab', 16), 'hex'),
      'fitness_connection', 'synthetic-retain-v1', now() + interval '365 days'
    );
  end loop;

  insert into semantic_private.fitness_feature_snapshots (
    id, user_id, input_revision, builder_model_id, policy_version,
    window_end_at, coverage_state, accepted_record_count,
    rejected_record_count, activity_day_count, activity_hour_count,
    workout_count, sleep_session_count, feature_payload, state, finalized_at
  ) values (
    sleep_snapshot_id, sleep_user_id, 0, builder_model_id, fitness_policy,
    workout_window_end, 'sleep_typed', 14, 0, 0, 0, 0, 14,
    '{}'::jsonb, 'ready', now()
  );

  if (
    select count(*) from semantic_private.raw_source_records
    where user_id = sleep_user_id and source_code = 'healthkit'
      and data_type = 'sleep_session' and lifecycle_state = 'active'
  ) <> 14 then
    raise exception 'typed-private sleep ingestion did not retain all sessions';
  end if;

  begin
    insert into semantic_private.fitness_habit_candidates (
      id, user_id, feature_snapshot_id, ontology_version_id, concept_id,
      candidate_kind, controlled_label, support_record_count,
      distinct_day_count, distinct_week_count, last_supported_at,
      mapping_agreement, evidence_quality, policy_version, window_end_at,
      derivation_as_of, expires_at
    ) values (
      sleep_candidate_id, sleep_user_id,
      sleep_snapshot_id, published_version_id, sleep_concept_id,
      'sleep_schedule', 'Consistent sleep schedule', 14, 14, 2,
      ((sleep_start_day + 13)::timestamp + interval '22 hours') at time zone 'UTC',
      1.0, 0.95, fitness_policy, workout_window_end,
      now(), now() + interval '7 days'
    );
    raise exception 'typed-private sleep was promoted into the ontology';
  exception
    when raise_exception then
      if sqlerrm = 'typed-private sleep was promoted into the ontology' then raise; end if;
  end;

  insert into semantic_private.semantic_runs (
    id, user_id, ontology_version_id, resolver_model_id, scorer_model_id,
    input_revision, input_hash, status
  ) values
    (viewer_run_id, viewer_user_id, published_version_id,
     resolver_model_id, scorer_model_id, 0, 'synthetic-v0.3-viewer-run',
     'running'),
    (viewer_other_run_id, viewer_user_id, published_version_id,
     resolver_model_id, scorer_model_id, 0,
     'synthetic-v0.3-viewer-other-run', 'running'),
    (subject_run_id, subject_user_id, published_version_id,
     resolver_model_id, scorer_model_id, 0, 'synthetic-v0.3-subject-run',
     'running');

  begin
    insert into semantic_private.observation_mappings (
      semantic_run_id, observation_id, user_id, ontology_version_id,
      concept_id, mapping_method, mapping_state, confidence, candidate_rank,
      feature_snapshot, evidence_path
    ) values (
      viewer_run_id, calendar_semantic_observation_id, viewer_user_id,
      published_version_id, booked_event_hub_id, 'provider_metadata',
      'accepted', 0.99, 1, '{}'::jsonb, '{}'::jsonb
    );
    raise exception 'typed Calendar observation entered generic mapping';
  exception
    when raise_exception then
      if sqlerrm = 'typed Calendar observation entered generic mapping' then
        raise;
      end if;
  end;

  insert into semantic_private.user_assertions (
    id, user_id, predicate_key, concept_id, created_ontology_version_id,
    source_semantic_run_id, assertion_origin, machine_state
  ) values
    (viewer_assertion_id, viewer_user_id, 'routine', running_concept_id,
     published_version_id, viewer_run_id, 'inferred', 'candidate'),
    (subject_assertion_id, subject_user_id, 'routine', walking_concept_id,
     published_version_id, subject_run_id, 'inferred', 'candidate');
  insert into semantic_private.user_assertions (
    id, user_id, predicate_key, concept_id, created_ontology_version_id,
    assertion_origin, machine_state
  ) values (
    mismatched_assertion_id, viewer_user_id, 'affinity_to', italy_concept_id,
    published_version_id, 'explicit_addition', 'eligible'
  );

  begin
    insert into semantic_private.healthkit_derived_assertions (
      assertion_id, user_id, fitness_candidate_id
    ) values (
      mismatched_assertion_id, viewer_user_id, viewer_candidate_id
    );
    raise exception 'mismatched assertion was relabeled as HealthKit-derived';
  exception
    when raise_exception then
      if sqlerrm = 'mismatched assertion was relabeled as HealthKit-derived' then raise; end if;
  end;

  insert into semantic_private.observations (
    id, user_id, ingestion_run_id, source_code, data_type, observation_kind,
    action_type, occurred_at, source_item_hmac, record_fingerprint,
    payload_schema_version, normalized_payload, field_quality, action_weight,
    privacy_class, allow_external_resolution
  ) values
  (
    routine_observation_id, viewer_user_id, viewer_ingestion_id,
    'healthkit', 'fitness_habit', 'routine_projection', 'routine',
    ((workout_start_day + 21)::timestamp + interval '7 hours') at time zone 'UTC',
    repeat(md5('obs-hmac-routine'), 2),
    repeat(md5('obs-fingerprint-routine'), 2),
    fitness_policy,
    jsonb_build_object(
      'schema_version', fitness_policy, 'record_kind', 'fitness_habit',
      'classification_state', 'candidate', 'candidate_id',
      viewer_candidate_id::text, 'controlled_label', 'Running',
      'coverage_state', 'workout_typed',
      'purpose_scope', 'fitness_connection',
      'policy_version', fitness_policy
    ), 1.0, 0.85, 'private_fitness_sanitized', false
  ),
  (
    subject_routine_observation_id, subject_user_id, subject_ingestion_id,
    'healthkit', 'fitness_habit', 'routine_projection', 'routine',
    ((workout_start_day + 22)::timestamp + interval '7 hours') at time zone 'UTC',
    repeat(md5('obs-hmac-subject-routine'), 2),
    repeat(md5('obs-fingerprint-subject-routine'), 2),
    fitness_policy,
    jsonb_build_object(
      'schema_version', fitness_policy, 'record_kind', 'fitness_habit',
      'classification_state', 'candidate', 'candidate_id',
      subject_candidate_id::text, 'controlled_label', 'Walking',
      'coverage_state', 'workout_typed',
      'purpose_scope', 'fitness_connection',
      'policy_version', fitness_policy
    ), 1.0, 0.85, 'private_fitness_sanitized', false
  );

  begin
  insert into semantic_private.observations (
    id, user_id, ingestion_run_id, source_code, data_type, observation_kind,
    action_type, occurred_at, source_item_hmac, record_fingerprint,
    payload_schema_version, normalized_payload, field_quality, action_weight,
    privacy_class, allow_external_resolution
  ) values (
    ontology.stable_uuid('written:test:v0.3-mismatched-routine-observation'),
    viewer_user_id, viewer_ingestion_id, 'healthkit', 'fitness_habit',
    'routine_projection', 'routine',
    ((workout_start_day + 21)::timestamp + interval '7 hours') at time zone 'UTC',
    repeat(md5('obs-hmac-mismatched-routine'), 2),
    repeat(md5('obs-fingerprint-mismatched-routine'), 2),
    fitness_policy, jsonb_build_object(
      'schema_version', fitness_policy, 'record_kind', 'fitness_habit',
      'classification_state', 'candidate', 'candidate_id',
      viewer_candidate_id::text, 'controlled_label', 'Runs every single day',
      'coverage_state', 'workout_typed',
      'purpose_scope', 'fitness_connection',
      'policy_version', fitness_policy
    ), 1.0, 0.85, 'private_fitness_sanitized', false
  );
    raise exception 'mismatched HealthKit label entered the observation table';
  exception
    when raise_exception then
      if sqlerrm = 'mismatched HealthKit label entered the observation table' then
        raise;
      end if;
  end;
  insert into semantic_private.fitness_candidate_observations (
    observation_id, user_id, fitness_candidate_id
  ) values
    (routine_observation_id, viewer_user_id, viewer_candidate_id),
    (subject_routine_observation_id, subject_user_id, subject_candidate_id);

  begin
    insert into semantic_private.observation_mappings (
      semantic_run_id, observation_id, user_id, ontology_version_id,
      concept_id, mapping_method, mapping_state, confidence, candidate_rank,
      feature_snapshot, evidence_path
    ) values (
      viewer_run_id, raw_health_observation_id, viewer_user_id,
      published_version_id, running_concept_id, 'curated_alias', 'accepted',
      0.99, 1, '{}'::jsonb, '{}'::jsonb
    );
    raise exception 'raw HealthKit workout entered generic mapping';
  exception
    when foreign_key_violation then null;
    when raise_exception then
      if sqlerrm = 'raw HealthKit workout entered generic mapping' then raise; end if;
  end;

  begin
    insert into semantic_private.observation_mappings (
      semantic_run_id, observation_id, user_id, ontology_version_id,
      concept_id, mapping_method, mapping_state, confidence, candidate_rank,
      feature_snapshot, evidence_path
    ) values (
      viewer_run_id, raw_viewer_1, viewer_user_id, published_version_id,
      running_concept_id, 'curated_alias', 'accepted', 0.99, 1,
      '{}'::jsonb, '{}'::jsonb
    );
    raise exception 'raw vault record became an observation mapping';
  exception
    when foreign_key_violation then null;
    when raise_exception then
      if sqlerrm = 'raw vault record became an observation mapping' then raise; end if;
  end;

  insert into semantic_private.observation_mappings (
    id, semantic_run_id, observation_id, user_id, ontology_version_id,
    concept_id, mapping_method, mapping_state, confidence, candidate_rank,
    evidence_weight, cross_source_fusion_allowed, feature_snapshot,
    evidence_path
  ) values
  (
    routine_mapping_id, viewer_run_id, routine_observation_id, viewer_user_id,
    published_version_id, running_concept_id, 'provider_metadata', 'accepted',
    0.98, 1, 1.0, false,
    jsonb_build_object(
      'candidate_id', viewer_candidate_id::text,
      'policy_version', fitness_policy,
      'purpose_scope', 'fitness_connection'
    ),
    jsonb_build_object(
      'step', 'validated_fitness_candidate',
      'candidate_id', viewer_candidate_id::text,
      'policy_version', fitness_policy,
      'purpose_scope', 'fitness_connection'
    )
  ),
  (
    subject_routine_mapping_id, subject_run_id, subject_routine_observation_id,
    subject_user_id, published_version_id, walking_concept_id,
    'provider_metadata', 'accepted', 0.97, 1, 1.0, false,
    jsonb_build_object(
      'candidate_id', subject_candidate_id::text,
      'policy_version', fitness_policy,
      'purpose_scope', 'fitness_connection'
    ),
    jsonb_build_object(
      'step', 'validated_fitness_candidate',
      'candidate_id', subject_candidate_id::text,
      'policy_version', fitness_policy,
      'purpose_scope', 'fitness_connection'
    )
  );

  insert into semantic_private.observation_mappings (
    id, semantic_run_id, observation_id, user_id, ontology_version_id,
    concept_id, mapping_method, mapping_state, confidence, candidate_rank,
    evidence_weight, cross_source_fusion_allowed, feature_snapshot,
    evidence_path
  ) values (
    viewer_other_mapping_id, viewer_other_run_id, routine_observation_id,
    viewer_user_id, published_version_id, running_concept_id,
    'provider_metadata', 'accepted', 0.98, 1, 1.0, false,
    jsonb_build_object(
      'candidate_id', viewer_candidate_id::text,
      'policy_version', fitness_policy,
      'purpose_scope', 'fitness_connection'
    ),
    jsonb_build_object(
      'step', 'validated_fitness_candidate',
      'candidate_id', viewer_candidate_id::text,
      'policy_version', fitness_policy,
      'purpose_scope', 'fitness_connection'
    )
  );

  insert into semantic_private.healthkit_derived_assertions (
    assertion_id, user_id, fitness_candidate_id
  ) values
    (viewer_assertion_id, viewer_user_id, viewer_candidate_id),
    (subject_assertion_id, subject_user_id, subject_candidate_id);

  insert into semantic_private.assertion_score_versions (
    id, assertion_id, user_id, semantic_run_id, ontology_version_id,
    strength, confidence, breadth, stability, surfacing_score,
    display_payload
  ) values (
    viewer_score_id, viewer_assertion_id, viewer_user_id, viewer_run_id,
    published_version_id, 0.85, 0.90, 1, 0.85, 0.80,
    '{}'::jsonb
  );
  begin
    insert into semantic_private.assertion_evidence (
      assertion_score_version_id, user_id, observation_mapping_id,
      contribution, independence_group, evidence_path
    ) values (
      viewer_score_id, viewer_user_id, viewer_other_mapping_id, 0.85,
      'fitness', jsonb_build_object(
        'step', 'validated_fitness_candidate',
        'candidate_id', viewer_candidate_id::text,
        'policy_version', fitness_policy,
        'purpose_scope', 'fitness_connection'
      )
    );
    raise exception 'cross-run assertion evidence was accepted';
  exception
    when raise_exception then
      if sqlerrm = 'cross-run assertion evidence was accepted' then raise; end if;
  end;
  begin
    insert into semantic_private.assertion_evidence (
      assertion_score_version_id, user_id, observation_mapping_id,
      contribution, independence_group, evidence_path
    ) values (
      viewer_score_id, viewer_user_id, routine_mapping_id, 0.85,
      'not_fitness', jsonb_build_object(
        'step', 'validated_fitness_candidate',
        'candidate_id', viewer_candidate_id::text,
        'policy_version', fitness_policy,
        'purpose_scope', 'fitness_connection'
      )
    );
    raise exception 'wrong independence group was accepted';
  exception
    when raise_exception then
      if sqlerrm = 'wrong independence group was accepted' then raise; end if;
  end;
  insert into semantic_private.assertion_evidence (
    assertion_score_version_id, user_id, observation_mapping_id,
    contribution, independence_group, evidence_path
  ) values (
    viewer_score_id, viewer_user_id, routine_mapping_id, 0.85,
    'fitness', jsonb_build_object(
      'step', 'validated_fitness_candidate',
      'candidate_id', viewer_candidate_id::text,
      'policy_version', fitness_policy,
      'purpose_scope', 'fitness_connection'
    )
  );

  if (
    select count(*)
    from semantic_private.assertion_surface_permissions
    where assertion_id in (viewer_assertion_id, subject_assertion_id)
      and (
        (surface = 'matching' and can_select and not can_name and not can_explain)
        or (surface in ('bio', 'icebreaker') and can_select and can_name and can_explain)
        or (surface = 'memories' and can_select and can_name and can_explain)
      )
  ) <> 8 then
    raise exception 'HealthKit provenance did not initialize surface grants';
  end if;

  begin
    insert into semantic_private.worker_jobs (
      job_type, user_id, payload, idempotency_key
    ) values (
      'derive_fitness_habits', viewer_user_id,
      jsonb_build_object(
        'user_id', viewer_user_id::text, 'input_revision', 0,
        'policy_version', fitness_policy
      ), 'synthetic-v0.3-invalid-derive-viewer'
    );
    raise exception 'derive-fitness job accepted an incomplete payload';
  exception
    when raise_exception then
      if sqlerrm = 'derive-fitness job accepted an incomplete payload' then raise; end if;
  end;

  insert into semantic_private.worker_jobs (
    job_type, user_id, payload, idempotency_key
  ) values (
    'derive_fitness_habits', viewer_user_id,
    jsonb_build_object(
      'user_id', viewer_user_id::text, 'input_revision', 0,
      'fitness_snapshot_id', viewer_snapshot_id::text,
      'builder_model_id', builder_model_id::text,
      'policy_version', fitness_policy
    ), 'synthetic-v0.3-derive-viewer'
  );

  -- Purpose is attached to the dyad independently of render purpose.
  insert into semantic_private.dyad_runs (
    id, viewer_user_id, subject_user_id, viewer_revision, subject_revision,
    ontology_version_id, ranker_model_id, run_purpose, data_use_purpose,
    input_hash
  ) values (
    general_dyad_id, viewer_user_id, subject_user_id, 0, 0,
    published_version_id, ranker_model_id, 'icebreaker', 'general_social',
    'synthetic-v0.3-general-dyad'
  );
  begin
    insert into semantic_private.dyad_alignment_pairs (
      dyad_run_id, viewer_user_id, subject_user_id, viewer_assertion_id,
      subject_assertion_id, bridge_concept_id, ontology_version_id,
      graph_distance, relation_distance, embedding_distance, transport_mass,
      specificity, information_value, explanation_path
    ) values (
      general_dyad_id, viewer_user_id, subject_user_id, viewer_assertion_id,
      subject_assertion_id, sports_concept_id, published_version_id,
      0.1, 0.1, 0.1, 0.8, 0.9, 0.9,
      '{"path_type":"shared_fitness"}'::jsonb
    );
    raise exception 'HealthKit evidence entered a general-social dyad';
  exception
    when raise_exception then
      if sqlerrm = 'HealthKit evidence entered a general-social dyad' then raise; end if;
  end;

  insert into semantic_private.dyad_runs (
    id, viewer_user_id, subject_user_id, viewer_revision, subject_revision,
    ontology_version_id, ranker_model_id, run_purpose, data_use_purpose,
    input_hash
  ) values (
    fitness_dyad_id, viewer_user_id, subject_user_id, 0, 0,
    published_version_id, ranker_model_id, 'icebreaker', 'fitness_connection',
    'synthetic-v0.3-fitness-dyad'
  );
  insert into semantic_private.dyad_alignment_pairs (
    dyad_run_id, viewer_user_id, subject_user_id, viewer_assertion_id,
    subject_assertion_id, bridge_concept_id, ontology_version_id,
    graph_distance, relation_distance, embedding_distance, transport_mass,
    specificity, information_value, explanation_path
  ) values (
    fitness_dyad_id, viewer_user_id, subject_user_id, viewer_assertion_id,
    subject_assertion_id, sports_concept_id, published_version_id,
    0.1, 0.1, 0.1, 0.8, 0.9, 0.9,
    '{"path_type":"shared_fitness"}'::jsonb
  );

  begin
    update semantic_private.dyad_runs
    set data_use_purpose = 'general_social'
    where id = fitness_dyad_id;
    raise exception 'HealthKit dyad was downgraded to general-social';
  exception
    when raise_exception then
      if sqlerrm = 'HealthKit dyad was downgraded to general-social' then raise; end if;
  end;

  update semantic_private.dyad_runs
  set status = 'succeeded', semantic_proximity = 0.85, comparability = 0.9,
      finished_at = now()
  where id = fitness_dyad_id;

  begin
    insert into semantic_private.validated_surface_facts (
      user_id, assertion_id, ontology_version_id, surface, predicate_key,
      display_label, evidence_class, confirmation_state, may_name,
      may_explain, validator_model_id, fact_version, fact_payload, state,
      data_use_purpose
    ) values (
      viewer_user_id, viewer_assertion_id, published_version_id, 'bio',
      'routine', 'Synthetic laundered routine', 'ontology_inferred',
      'inferred', false, false, ranker_model_id, 'synthetic-launder-v1',
      '{}'::jsonb, 'candidate', 'general_social'
    );
    raise exception 'HealthKit surface fact was laundered as ontology-only';
  exception
    when raise_exception then
      if sqlerrm = 'HealthKit surface fact was laundered as ontology-only' then raise; end if;
  end;

  insert into semantic_private.validated_surface_facts (
    id, user_id, assertion_id, ontology_version_id, surface,
    predicate_key, display_label, evidence_class, confirmation_state,
    may_name, may_explain, validator_model_id, fact_version, fact_payload,
    state, data_use_purpose
  ) values
    (viewer_fact_id, viewer_user_id, viewer_assertion_id,
     published_version_id, 'icebreaker', 'routine', 'Runs regularly',
     'healthkit_derived', 'user_confirmed', true, true, ranker_model_id,
     'synthetic-viewer-v1',
     '{"template_key":"fitness_routine","wording_version":"v1","predicate_label":"routine","concept_label":"Running","source_badges":["HealthKit"],"license":"private-consent"}'::jsonb,
     'validated', 'fitness_connection'),
    (subject_fact_id, subject_user_id, subject_assertion_id,
     published_version_id, 'icebreaker', 'routine', 'Walks regularly',
     'healthkit_derived', 'user_confirmed', true, true, ranker_model_id,
     'synthetic-subject-v1',
     '{"template_key":"fitness_routine","wording_version":"v1","predicate_label":"routine","concept_label":"Walking","source_badges":["HealthKit"],"license":"private-consent"}'::jsonb,
     'validated', 'fitness_connection');

  insert into semantic_private.match_authorizations (
    id, match_id, participant_a_user_id, participant_b_user_id,
    source_version
  ) values (
    match_authorization_id,
    ontology.stable_uuid('written:test:v0.3-match'),
    viewer_user_id, subject_user_id, 'synthetic-v1'
  );

  insert into semantic_private.icebreaker_frames (
    id, match_authorization_id, dyad_run_id, viewer_user_id,
    subject_user_id, bridge_concept_id, ontology_version_id,
    renderer_model_id, bridge_mode, template_version, frame_payload
  ) values
    (exposed_frame_id, match_authorization_id, fitness_dyad_id,
     viewer_user_id, subject_user_id, sports_concept_id, published_version_id,
     renderer_model_id, 'shared_thread', 'synthetic-exposed-v1',
     '{"template_key":"shared_fitness","wording_version":"v1","bridge_label":"movement"}'::jsonb),
    (provisional_frame_id, match_authorization_id, fitness_dyad_id,
     viewer_user_id, subject_user_id, sports_concept_id, published_version_id,
     renderer_model_id, 'shared_thread', 'synthetic-provisional-v1',
     '{"template_key":"shared_fitness","wording_version":"v1","bridge_label":"movement"}'::jsonb);

  insert into semantic_private.icebreaker_frame_facts (
    icebreaker_frame_id, surface_fact_id, fact_user_id, fact_side
  ) values
    (exposed_frame_id, viewer_fact_id, viewer_user_id, 'viewer'),
    (exposed_frame_id, subject_fact_id, subject_user_id, 'subject'),
    (provisional_frame_id, viewer_fact_id, viewer_user_id, 'viewer'),
    (provisional_frame_id, subject_fact_id, subject_user_id, 'subject');

  update semantic_private.icebreaker_frames
  set state = 'ready', rendered_text =
        'You both have a regular movement routine. What keeps it enjoyable?',
      finalized_at = now()
  where id = exposed_frame_id;
  update semantic_private.icebreaker_frames
  set state = 'ready', rendered_text =
        'You both make time for movement. What helps the habit stick?',
      finalized_at = now()
  where id = provisional_frame_id;

  begin
    update semantic_private.icebreaker_frames
    set exposed_at = now()
    where id = exposed_frame_id;
    raise exception 'direct icebreaker exposure bypassed the server function';
  exception
    when raise_exception then
      if sqlerrm = 'direct icebreaker exposure bypassed the server function' then raise; end if;
  end;

  perform semantic_private.mark_icebreaker_exposed(exposed_frame_id);
  if not exists (
    select 1 from semantic_private.icebreaker_frames
    where id = exposed_frame_id and exposed_at is not null and state = 'ready'
  ) then
    raise exception 'validated icebreaker exposure did not persist';
  end if;

  begin
    update semantic_private.icebreaker_frames
    set rendered_text = 'Synthetic rewritten historical message'
    where id = exposed_frame_id;
    raise exception 'exposed icebreaker text remained mutable';
  exception
    when raise_exception then
      if sqlerrm = 'exposed icebreaker text remained mutable' then raise; end if;
  end;

  begin
    update semantic_private.icebreaker_frames
    set frame_payload = jsonb_set(frame_payload, '{wording_version}', '"v2"')
    where id = exposed_frame_id;
    raise exception 'exposed icebreaker payload remained mutable';
  exception
    when raise_exception then
      if sqlerrm = 'exposed icebreaker payload remained mutable' then raise; end if;
  end;

  begin
    delete from semantic_private.icebreaker_frame_facts
    where icebreaker_frame_id = exposed_frame_id and fact_side = 'viewer';
    raise exception 'exposed icebreaker fact provenance remained mutable';
  exception
    when raise_exception then
      if sqlerrm = 'exposed icebreaker fact provenance remained mutable' then raise; end if;
  end;

  begin
    update semantic_private.validated_surface_facts
    set may_name = false, may_explain = false
    where id = subject_fact_id;
    perform semantic_private.mark_icebreaker_exposed(provisional_frame_id);
    raise exception 'non-nameable linked fact was first-exposed';
  exception
    when raise_exception then
      if sqlerrm = 'non-nameable linked fact was first-exposed' then raise; end if;
  end;

  -- Candidate TTL is a use-time boundary, not merely an insert-time check.
  -- The already exposed message remains immutable history, while its ready but
  -- unexposed sibling must fail closed once either supporting candidate expires.
  update semantic_private.fitness_habit_candidates
  set expires_at = clock_timestamp() + interval '50 milliseconds'
  where id = subject_candidate_id;
  perform pg_sleep(0.10);
  if semantic_private.dyad_run_is_current(fitness_dyad_id) then
    raise exception 'expired HealthKit evidence left its dyad current';
  end if;
  begin
    perform semantic_private.mark_icebreaker_exposed(provisional_frame_id);
    raise exception 'expired HealthKit icebreaker was first-exposed';
  exception
    when raise_exception then
      if sqlerrm = 'expired HealthKit icebreaker was first-exposed' then raise; end if;
  end;
  update semantic_private.fitness_habit_candidates
  set review_state = 'retired'
  where id = subject_candidate_id;

  -- Exact-current invalidation applies only before first exposure. The exposed
  -- historical message remains immutable; the unexposed sibling becomes stale.
  update semantic_private.user_state_versions
  set revision = 1
  where user_id = viewer_user_id;

  if not exists (
    select 1
    from semantic_private.icebreaker_frames
    where id = exposed_frame_id and state = 'ready' and exposed_at is not null
  ) or not exists (
    select 1
    from semantic_private.icebreaker_frames
    where id = provisional_frame_id and state = 'stale' and exposed_at is null
  ) then
    raise exception 'exposed/unexposed icebreaker staleness contract failed';
  end if;

  begin
    perform semantic_private.mark_icebreaker_exposed(provisional_frame_id);
    raise exception 'stale icebreaker was exposed';
  exception
    when raise_exception then
      if sqlerrm = 'stale icebreaker was exposed' then raise; end if;
  end;

  -- Narrowing a grant locks provenance even after candidate retirement and
  -- must not permit the assertion to be laundered back into matching.
  update semantic_private.healthkit_use_grants
  set grant_state = 'revoked', revoked_at = now()
  where user_id = viewer_user_id;
  set constraints all immediate;
  if not exists (
    select 1 from semantic_private.fitness_habit_candidates
    where id = viewer_candidate_id and review_state = 'retired'
  ) or not exists (
    select 1 from semantic_private.raw_source_records
    where id = raw_viewer_1 and lifecycle_state = 'deleted'
      and encrypted_payload is null and raw_blob_ref is null
      and deleted_at is not null
  ) or exists (
    select 1 from semantic_private.assertion_surface_permissions
    where assertion_id = viewer_assertion_id and surface = 'matching'
      and can_select
  ) then
    raise exception 'HealthKit revocation did not retire derived eligibility';
  end if;
  if semantic_private.fitness_candidate_is_current(
       viewer_candidate_id, viewer_user_id
     ) then
    raise exception 'revoked fitness candidate remained current';
  end if;

  begin
    delete from semantic_private.healthkit_use_grants
    where user_id = viewer_user_id;
    raise exception 'audited HealthKit grant row was directly deleted';
  exception
    when raise_exception then
      if sqlerrm = 'audited HealthKit grant row was directly deleted' then raise; end if;
  end;

  begin
    update semantic_private.fitness_habit_candidates
    set review_state = 'candidate'
    where id = viewer_candidate_id;
    raise exception 'revoked HealthKit candidate was reactivated';
  exception
    when raise_exception then
      if sqlerrm = 'revoked HealthKit candidate was reactivated' then raise; end if;
  end;

  begin
    update semantic_private.assertion_surface_permissions
    set can_select = true, permission_source = 'user_choice'
    where assertion_id = viewer_assertion_id
      and user_id = viewer_user_id and surface = 'matching';
    raise exception 'retired HealthKit provenance was laundered into matching';
  exception
    when raise_exception then
      if sqlerrm = 'retired HealthKit provenance was laundered into matching' then raise; end if;
  end;
end
$contract_behavior$;

rollback;
