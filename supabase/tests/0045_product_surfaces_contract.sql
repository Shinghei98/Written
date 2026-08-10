-- Adapted from the v0.3.1 reference `sql/tests/004_product_surfaces_contract.sql`.
-- Gates application migration 0045.
--
-- The reference chain numbers its files 001-006 while this repository's
-- are 0042-0047, so contract numbering is off by two and the two
-- fixture lanes are off by one -- reference fixture `004` gates the
-- app's 0046, and reference fixture `005` gates 0047. The file name
-- states which migration it gates so nobody re-derives that each time.
--
-- Substituted from the reference: 122 `private.` -> `semantic_private.`
-- and 25 bare `'private'` schema arguments. Privacy-class VALUES
-- such as `'private_text'` are deliberately untouched: they are
-- check-constraint values, not schema names, and rewriting them is how
-- a mechanical rename corrupts a contract while still passing.

-- Run after 001_schema.sql through 004_product_surfaces.sql.
-- All identities, times, concepts, and payloads below are synthetic.
begin;

do $$
declare
  missing_objects text[];
  published_version_id uuid;
  draft_version_id uuid := ontology.stable_uuid('written:test:v0.2-version');
  viewer_user_id uuid := ontology.stable_uuid('written:test:v0.2-viewer');
  subject_user_id uuid := ontology.stable_uuid('written:test:v0.2-subject');
  creator_concept_id uuid := ontology.stable_uuid('written:test:v0.2-creator');
  origin_place_id uuid := ontology.stable_uuid('written:test:v0.2-origin');
  terminal_place_id uuid := ontology.stable_uuid('written:test:v0.2-terminal');
  event_concept_id uuid := ontology.stable_uuid('written:test:v0.2-event');
  italy_concept_id uuid;
  affinity_concept_id uuid;
  resolver_model_id uuid;
  scorer_model_id uuid;
  ranker_model_id uuid;
  calendar_model_id uuid;
  youtube_model_id uuid;
  memories_model_id uuid;
  hometown_run_id uuid := ontology.stable_uuid('written:test:v0.2-hometown-run');
  youtube_run_id uuid := ontology.stable_uuid('written:test:v0.2-youtube-run');
  viewer_assertion_id uuid := ontology.stable_uuid('written:test:v0.2-viewer-assertion');
  subject_assertion_id uuid := ontology.stable_uuid('written:test:v0.2-subject-assertion');
  calendar_assertion_id uuid := ontology.stable_uuid('written:test:v0.2-calendar-assertion');
  youtube_channel_row_id uuid := ontology.stable_uuid('written:test:v0.2-youtube-channel');
  channel_resolution_id uuid := ontology.stable_uuid('written:test:v0.2-channel-resolution');
  youtube_approval_id uuid := ontology.stable_uuid('written:test:v0.2-youtube-approval');
  youtube_ingestion_id uuid := ontology.stable_uuid('written:test:v0.2-youtube-ingestion');
  youtube_observation_id uuid := ontology.stable_uuid('written:test:v0.2-youtube-observation');
  youtube_mapping_id uuid := ontology.stable_uuid('written:test:v0.2-youtube-mapping');
  apple_ingestion_id uuid := ontology.stable_uuid('written:test:v0.2-apple-calendar-ingestion');
  google_ingestion_id uuid := ontology.stable_uuid('written:test:v0.2-google-calendar-ingestion');
  flight_observation_id uuid := ontology.stable_uuid('written:test:v0.2-flight-observation');
  mirror_observation_id uuid := ontology.stable_uuid('written:test:v0.2-mirror-observation');
  terminal_observation_id uuid := ontology.stable_uuid('written:test:v0.2-terminal-observation');
  booked_observation_id uuid := ontology.stable_uuid('written:test:v0.2-booked-observation');
  flight_classification_id uuid := ontology.stable_uuid('written:test:v0.2-flight-classification');
  mirror_classification_id uuid := ontology.stable_uuid('written:test:v0.2-mirror-classification');
  terminal_classification_id uuid := ontology.stable_uuid('written:test:v0.2-terminal-classification');
  booked_classification_id uuid := ontology.stable_uuid('written:test:v0.2-booked-classification');
  connection_segment_id uuid := ontology.stable_uuid('written:test:v0.2-connection-segment');
  terminal_segment_id uuid := ontology.stable_uuid('written:test:v0.2-terminal-segment');
  journey_id uuid := ontology.stable_uuid('written:test:v0.2-journey');
  scheduled_candidate_id uuid := ontology.stable_uuid('written:test:v0.2-scheduled-candidate');
  booked_candidate_id uuid := ontology.stable_uuid('written:test:v0.2-booked-candidate');
  memories_snapshot_id uuid := ontology.stable_uuid('written:test:v0.2-memories-snapshot');
  dyad_run_id uuid := ontology.stable_uuid('written:test:v0.2-dyad-run');
  flight_lineage text := repeat('a', 64);
  terminal_lineage text := repeat('b', 64);
  journey_lineage text := repeat('c', 64);
  booked_lineage text := repeat('d', 64);
begin
  -- Catalog, RLS, grant, constraint, trigger, and replay identities.
  select array_agg(expected.object_name order by expected.object_name)
  into missing_objects
  from unnest(array[
    'ontology.youtube_channels',
    'ontology.youtube_channel_resolutions',
    'ontology.youtube_policy_approvals',
    'semantic_private.youtube_run_policies',
    'semantic_private.youtube_observation_channels',
    'semantic_private.calendar_event_classifications',
    'semantic_private.travel_segments',
    'semantic_private.travel_segment_sources',
    'semantic_private.travel_journeys',
    'semantic_private.travel_journey_segments',
    'semantic_private.recurring_place_candidates',
    'semantic_private.scheduled_travel_candidates',
    'semantic_private.booked_activity_candidates',
    'semantic_private.assertion_surface_permissions',
    'semantic_private.memories_snapshots',
    'semantic_private.memories_snapshot_items',
    'semantic_private.dyad_runs',
    'semantic_private.dyad_alignment_pairs',
    'semantic_private.validated_surface_facts',
    'semantic_private.bio_variants',
    'semantic_private.bio_variant_facts',
    'semantic_private.match_authorizations',
    'semantic_private.icebreaker_frames',
    'semantic_private.icebreaker_frame_facts'
  ]) as expected(object_name)
  where to_regclass(expected.object_name) is null;
  if missing_objects is not null then
    raise exception 'v0.2 tables are missing: %', missing_objects;
  end if;

  select array_agg(expected.schema_name || '.' || expected.table_name
                   order by expected.schema_name, expected.table_name)
  into missing_objects
  from (values
    ('ontology', 'youtube_channels'),
    ('ontology', 'youtube_channel_resolutions'),
    ('ontology', 'youtube_policy_approvals'),
    ('semantic_private', 'youtube_run_policies'),
    ('semantic_private', 'youtube_observation_channels'),
    ('semantic_private', 'calendar_event_classifications'),
    ('semantic_private', 'travel_segments'),
    ('semantic_private', 'travel_segment_sources'),
    ('semantic_private', 'travel_journeys'),
    ('semantic_private', 'travel_journey_segments'),
    ('semantic_private', 'recurring_place_candidates'),
    ('semantic_private', 'scheduled_travel_candidates'),
    ('semantic_private', 'booked_activity_candidates'),
    ('semantic_private', 'assertion_surface_permissions'),
    ('semantic_private', 'memories_snapshots'),
    ('semantic_private', 'memories_snapshot_items'),
    ('semantic_private', 'dyad_runs'),
    ('semantic_private', 'dyad_alignment_pairs'),
    ('semantic_private', 'validated_surface_facts'),
    ('semantic_private', 'bio_variants'),
    ('semantic_private', 'bio_variant_facts'),
    ('semantic_private', 'match_authorizations'),
    ('semantic_private', 'icebreaker_frames'),
    ('semantic_private', 'icebreaker_frame_facts')
  ) as expected(schema_name, table_name)
  left join pg_namespace as namespace
    on namespace.nspname = expected.schema_name
  left join pg_class as relation
    on relation.relnamespace = namespace.oid
   and relation.relname = expected.table_name
   and relation.relrowsecurity
  where relation.oid is null;
  if missing_objects is not null then
    raise exception 'v0.2 tables missing RLS: %', missing_objects;
  end if;

  if exists (
    select 1 from pg_policies
    where schemaname in ('ontology', 'semantic_private')
      and tablename in (
        'youtube_channels', 'youtube_channel_resolutions',
        'youtube_policy_approvals', 'youtube_run_policies',
        'youtube_observation_channels', 'calendar_event_classifications',
        'travel_segments', 'travel_segment_sources', 'travel_journeys',
        'travel_journey_segments', 'recurring_place_candidates',
        'scheduled_travel_candidates', 'booked_activity_candidates',
        'assertion_surface_permissions', 'memories_snapshots',
        'memories_snapshot_items', 'dyad_runs', 'dyad_alignment_pairs',
        'validated_surface_facts', 'bio_variants', 'bio_variant_facts',
        'match_authorizations', 'icebreaker_frames',
        'icebreaker_frame_facts'
      )
  ) then
    raise exception 'internal v0.2 tables unexpectedly expose Data API policies';
  end if;

  if has_table_privilege(
       'authenticated', 'semantic_private.booked_activity_candidates', 'select'
     ) or has_table_privilege(
       'authenticated', 'semantic_private.youtube_run_policies', 'select'
     ) or has_table_privilege(
       'authenticated', 'semantic_private.dyad_runs', 'select'
     ) or has_table_privilege(
       'authenticated', 'ontology.youtube_policy_approvals', 'select'
     ) or not has_table_privilege(
       'service_role', 'semantic_private.booked_activity_candidates', 'insert'
     ) or not has_table_privilege(
       'service_role', 'semantic_private.travel_segment_sources', 'insert'
     ) or not has_table_privilege(
       'service_role', 'semantic_private.youtube_run_policies', 'update'
     ) or not has_table_privilege(
       'service_role', 'ontology.youtube_policy_approvals', 'update'
     ) then
    raise exception 'v0.2 grants are not default-deny/service-only';
  end if;

  select array_agg(expected.table_name || ':' || expected.constraint_name
                   order by expected.table_name, expected.constraint_name)
  into missing_objects
  from (values
    ('semantic_private.assertion_surface_permissions', 'assertion_surface_permissions_matching_shape_check'),
    ('ontology.youtube_policy_approvals', 'youtube_policy_approvals_surface_scope_check'),
    ('ontology.youtube_channel_resolutions', 'youtube_channel_resolutions_safe_evidence_check'),
    ('semantic_private.youtube_run_policies', 'youtube_run_policies_approval_shape_check'),
    ('semantic_private.observation_mappings', 'observation_mappings_recency_v02_check'),
    ('semantic_private.youtube_observation_channels', 'youtube_observation_channels_recency_check'),
    ('semantic_private.travel_segments', 'travel_segments_lineage_hmac_check'),
    ('semantic_private.travel_journeys', 'travel_journeys_lineage_hmac_check'),
    ('semantic_private.recurring_place_candidates', 'recurring_place_candidates_often_returns_check'),
    ('semantic_private.booked_activity_candidates', 'booked_activity_candidates_private_check'),
    ('semantic_private.booked_activity_candidates', 'booked_activity_candidates_recency_check'),
    ('semantic_private.scheduled_travel_candidates', 'scheduled_travel_candidates_recency_check'),
    ('semantic_private.calendar_event_classifications', 'calendar_classifications_safe_payload_check'),
    ('semantic_private.validated_surface_facts', 'validated_surface_facts_calendar_public_check'),
    ('semantic_private.worker_jobs', 'worker_jobs_job_type_v02_check')
  ) as expected(table_name, constraint_name)
  left join pg_constraint as constraint_row
    on constraint_row.conrelid = to_regclass(expected.table_name)
   and constraint_row.conname = expected.constraint_name
  where constraint_row.oid is null;
  if missing_objects is not null then
    raise exception 'v0.2 constraints are missing: %', missing_objects;
  end if;

  select array_agg(expected.table_name || ':' || expected.trigger_name
                   order by expected.table_name, expected.trigger_name)
  into missing_objects
  from (values
    ('semantic_private.semantic_runs', 'semantic_runs_initialize_youtube_policy'),
    ('semantic_private.observation_mappings', 'observation_mappings_pin_run_recency'),
    ('semantic_private.observation_mappings', 'observation_mappings_guard_youtube_fusion'),
    ('semantic_private.observation_mappings', 'observation_mappings_guard_calendar_classification'),
    ('semantic_private.youtube_observation_channels', 'youtube_observation_channels_pin_run_recency'),
    ('semantic_private.motif_support', 'motif_support_inherit_mapping_recency'),
    ('semantic_private.assertion_evidence', 'assertion_evidence_inherit_mapping_recency'),
    ('semantic_private.youtube_run_policies', 'youtube_run_policies_guard_approval'),
    ('semantic_private.youtube_observation_channels', 'youtube_observation_channels_guard_relation'),
    ('semantic_private.travel_segments', 'travel_segments_initialize_primary_source'),
    ('semantic_private.travel_segment_sources', 'travel_segment_sources_guard_classification'),
    ('semantic_private.travel_journey_segments', 'travel_journey_segments_guard_role'),
    ('semantic_private.scheduled_travel_candidates', 'scheduled_travel_candidates_guard_terminal'),
    ('semantic_private.booked_activity_candidates', 'booked_activity_candidates_guard_classification'),
    ('semantic_private.assertion_surface_permissions', 'assertion_permissions_guard_calendar'),
    ('semantic_private.assertion_surface_permissions', 'assertion_permissions_guard_youtube'),
    ('semantic_private.assertion_surface_permissions', 'assertion_permissions_invalidate_matching_outputs'),
    ('semantic_private.dyad_alignment_pairs', 'dyad_alignment_pairs_guard_current'),
    ('semantic_private.user_state_versions', 'user_state_versions_invalidate_product_outputs')
  ) as expected(table_name, trigger_name)
  left join pg_trigger as trigger_row
    on trigger_row.tgrelid = to_regclass(expected.table_name)
   and trigger_row.tgname = expected.trigger_name
   and not trigger_row.tgisinternal
  where trigger_row.oid is null;
  if missing_objects is not null then
    raise exception 'v0.2 triggers are missing: %', missing_objects;
  end if;

  if exists (
    select trigger_row.tgname
    from pg_trigger as trigger_row
    where trigger_row.tgname in (
      'semantic_runs_initialize_youtube_policy',
      'travel_segments_initialize_primary_source',
      'scheduled_travel_candidates_guard_terminal'
    ) and not trigger_row.tgisinternal
    group by trigger_row.tgname
    having count(*) <> 1
  ) then
    raise exception 'migration replay duplicated a v0.2 trigger';
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'semantic_private.worker_jobs'::regclass
      and conname = 'worker_jobs_job_type_v02_check'
      and pg_get_constraintdef(oid) like '%classify_calendar%'
      and pg_get_constraintdef(oid) like '%resolve_youtube_channel%'
      and pg_get_constraintdef(oid) like '%build_memories%'
      and pg_get_constraintdef(oid) like '%compute_dyad%'
      and pg_get_constraintdef(oid) like '%render_bio%'
      and pg_get_constraintdef(oid) like '%render_icebreaker%'
  ) then
    raise exception 'worker job whitelist is missing a v0.2 job type';
  end if;

  if (
    select count(*)
    from semantic_private.sources as source
    join (values
      ('apple_music', 0.90::double precision,
       '{"library_song":0.48,"library_album":0.55,"library_artist":0.45,"library_playlist":0.60,"playlist_item":0.70,"rating":0.88,"recently_added":0.55,"recently_played":0.78,"saved_track":0.60,"saved_album":0.55,"followed_artist":0.55,"recommendation":0.0}'::jsonb),
      ('music_library', 0.75::double precision,
       '{"library_song":0.48}'::jsonb),
      ('spotify', 0.90::double precision,
       '{"followed_artist":0.55,"recently_played":0.78,"saved_album":0.55,"saved_track":0.60,"saved":0.0,"playlist_item":0.0}'::jsonb),
      ('youtube', 0.80::double precision,
       '{"subscription":0.55,"video":0.65,"watched":0.72,"liked":0.90,"liked_video":0.90,"shared":0.92,"playlist":0.0,"playlist_item":0.0}'::jsonb),
      ('apple_calendar', 0.90::double precision,
       '{"scheduled":0.90,"booked":0.0,"entered_by_user":0.0,"cancelled":0.0}'::jsonb),
      ('google_calendar', 0.90::double precision,
       '{"scheduled":0.90,"booked":0.0,"entered_by_user":0.0,"cancelled":0.0}'::jsonb),
      ('apple_podcasts', 0.80::double precision,
       '{"followed":0.70,"played":0.75,"saved":0.82}'::jsonb),
      ('podcast', 0.80::double precision,
       '{"show":0.0,"episode":0.0,"followed":0.70,"played":0.75,"saved":0.82}'::jsonb)
    ) as policy(source_code, default_reliability, action_weights)
      on policy.source_code = source.source_code
    where source.default_reliability = policy.default_reliability
      and source.action_weights = policy.action_weights
  ) <> 8 then
    raise exception 'SQL source policy drifted from deterministic adapter';
  end if;

  if (
    select count(*) from information_schema.columns
    where table_schema = 'semantic_private'
      and table_name in (
        'observation_mentions', 'observation_mappings', 'motif_support',
        'assertion_evidence'
      )
      and column_name in (
        'recency_weight', 'recency_quality', 'recency_policy_version',
        'recency_rule_id', 'recency_status', 'recency_timestamp_quality',
        'recency_as_of'
      ) and is_nullable = 'NO'
  ) <> 28 or (
    select count(*) from information_schema.columns
    where table_schema = 'semantic_private'
      and table_name in (
        'concept_source_scores', 'concept_scores', 'motif_instances',
        'assertion_score_versions'
      )
      and column_name in ('recency_policy_version', 'recency_as_of')
      and is_nullable = 'NO'
  ) <> 8 then
    raise exception 'versioned recency persistence is incomplete';
  end if;
  if (
    select count(*) from information_schema.columns
    where table_schema = 'semantic_private'
      and table_name in (
        'youtube_observation_channels', 'scheduled_travel_candidates',
        'booked_activity_candidates'
      )
      and column_name in (
        'recency_weight', 'recency_quality', 'recency_policy_version',
        'recency_rule_id', 'recency_status', 'recency_timestamp_quality',
        'recency_as_of'
      ) and is_nullable = 'NO'
  ) <> 21 then
    raise exception 'channel/booking recency persistence is incomplete';
  end if;

  if (
    select count(*) from ontology.relation_types
    where (predicate_key, relation_class, assertion_safe) in (
      ('explicit_association_with', 'user_claim', false),
      ('likes', 'user_claim', false),
      ('visited', 'user_claim', false),
      ('travel_interest', 'user_claim', true),
      ('wants_to_visit', 'user_claim', false),
      ('returns_to', 'user_claim', false),
      ('attended_activity_at', 'user_claim', false),
      ('likes_activity', 'user_claim', false),
      ('booked_activity_at', 'observed_action', false),
      ('booked_event', 'observed_action', false),
      ('scheduled_dining', 'observed_action', false)
    )
  ) <> 11 then
    raise exception 'granularity/booking relation types have unsafe flags';
  end if;

  -- Synthetic identities, ontology revisions, and model references.
  insert into auth.users (id, aud, role, created_at, updated_at) values
    (viewer_user_id, 'authenticated', 'authenticated', now(), now()),
    (subject_user_id, 'authenticated', 'authenticated', now(), now());
  insert into semantic_private.user_state_versions (user_id, revision) values
    (viewer_user_id, 0), (subject_user_id, 0);

  select id into published_version_id
  from ontology.versions where status = 'published';
  select id into italy_concept_id
  from ontology.concepts where concept_key = 'place:italy';
  select id into affinity_concept_id
  from ontology.concepts where concept_key = 'affinity:culture:italy';
  select id into resolver_model_id from ontology.model_versions
  where model_key = 'ontology_first_resolver' and version = '0.1.0';
  select id into scorer_model_id from ontology.model_versions
  where model_key = 'missing_aware_late_fusion' and version = '0.1.0';
  select id into ranker_model_id from ontology.model_versions
  where model_key = 'typed_graph_dyad_ranker' and version = '0.2.0';
  select id into calendar_model_id from ontology.model_versions
  where model_key = 'calendar_privacy_travel_classifier' and version = '0.2.0';
  select id into youtube_model_id from ontology.model_versions
  where model_key = 'youtube_channel_role_resolver' and version = '0.2.0';
  select id into memories_model_id from ontology.model_versions
  where model_key = 'memories_multiresolution_builder' and version = '0.2.0';

  insert into ontology.versions (
    id, version, parent_version_id, status, description
  ) values (
    draft_version_id, 'test-v0.2-contract', published_version_id, 'draft',
    'Synthetic product-surface contract version'
  );
  insert into ontology.concepts (id, concept_key) values
    (creator_concept_id, 'test:creator:v0.2'),
    (origin_place_id, 'test:place:v0.2-origin'),
    (terminal_place_id, 'test:place:v0.2-terminal'),
    (event_concept_id, 'test:event:v0.2');
  insert into ontology.concept_revisions (
    ontology_version_id, concept_id, preferred_label, concept_kind,
    sensitivity, inference_policy, status
  ) values
    (draft_version_id, creator_concept_id, 'Synthetic Creator', 'creator',
     'ordinary', 'inferable', 'active'),
    (draft_version_id, origin_place_id, 'Synthetic Origin', 'place',
     'ordinary', 'review_required', 'active'),
    (draft_version_id, terminal_place_id, 'Synthetic Destination', 'place',
     'ordinary', 'review_required', 'active'),
    (draft_version_id, event_concept_id, 'Synthetic Event Category', 'event',
     'ordinary', 'review_required', 'active');
  insert into ontology.concept_revisions (
    ontology_version_id, concept_id, preferred_label, concept_kind,
    definition, sensitivity, inference_policy, status, metadata
  )
  select draft_version_id, revision.concept_id, revision.preferred_label,
         revision.concept_kind, revision.definition, revision.sensitivity,
         revision.inference_policy, revision.status, revision.metadata
  from ontology.concept_revisions as revision
  where revision.ontology_version_id = published_version_id
    and revision.concept_id = italy_concept_id;

  -- Explicit-only hometown guard and four-surface permission initialization.
  insert into semantic_private.semantic_runs (
    id, user_id, ontology_version_id, resolver_model_id, scorer_model_id,
    input_revision, input_hash, status
  ) values (
    hometown_run_id, viewer_user_id, published_version_id,
    resolver_model_id, scorer_model_id, 0, 'synthetic-hometown-input', 'running'
  );
  if not exists (
    select 1 from semantic_private.youtube_run_policies
    where semantic_run_id = hometown_run_id
      and not allow_channel_identity and not allow_role_resolution
      and not allow_uploader_tags and not allow_title_tags
      and not allow_cross_source_fusion and not allow_bio
      and not allow_icebreaker and not allow_explanation
  ) then
    raise exception 'semantic run did not receive a deny-all YouTube policy';
  end if;
  begin
    insert into semantic_private.user_assertions (
      id, user_id, predicate_key, concept_id, created_ontology_version_id,
      source_semantic_run_id, assertion_origin, machine_state
    ) values (
      ontology.stable_uuid('written:test:v0.2-forbidden-hometown'),
      viewer_user_id, 'hometown', italy_concept_id, published_version_id,
      hometown_run_id, 'inferred', 'candidate'
    );
    raise exception 'machine inference unexpectedly created hometown';
  exception
    when raise_exception then
      if sqlerrm = 'machine inference unexpectedly created hometown' then raise; end if;
      if sqlerrm not like 'machine inference cannot create hometown assertions%' then
        raise exception 'unexpected hometown guard failure: %', sqlerrm;
      end if;
  end;

  insert into semantic_private.user_assertions (
    id, user_id, predicate_key, concept_id, created_ontology_version_id,
    assertion_origin, machine_state
  ) values
    (viewer_assertion_id, viewer_user_id, 'hometown', italy_concept_id,
     published_version_id, 'explicit_self_report', 'eligible'),
    (subject_assertion_id, subject_user_id, 'affinity_to', affinity_concept_id,
     published_version_id, 'explicit_addition', 'eligible');
  insert into semantic_private.user_assertions (
    id, user_id, predicate_key, concept_id, created_ontology_version_id,
    source_semantic_run_id, assertion_origin, machine_state
  ) values (
    calendar_assertion_id, viewer_user_id, 'recurring_presence_at',
    italy_concept_id, published_version_id, hometown_run_id,
    'inferred', 'candidate'
  );
  if (
    select count(*) from semantic_private.assertion_surface_permissions
    where assertion_id in (
      viewer_assertion_id, subject_assertion_id, calendar_assertion_id
    )
  ) <> 12 then
    raise exception 'assertions did not initialize four surface permissions each';
  end if;
  begin
    update semantic_private.assertion_surface_permissions
    set can_select = true
    where assertion_id = calendar_assertion_id
      and user_id = viewer_user_id and surface = 'matching';
    raise exception 'unconfirmed Calendar assertion entered matching';
  exception
    when raise_exception then
      if sqlerrm = 'unconfirmed Calendar assertion entered matching' then raise; end if;
  end;
  insert into semantic_private.assertion_preferences (
    assertion_id, user_id, display_state
  ) values (calendar_assertion_id, viewer_user_id, 'confirmed');
  update semantic_private.assertion_surface_permissions
  set can_select = true, permission_source = 'user_choice'
  where assertion_id = calendar_assertion_id
    and user_id = viewer_user_id and surface = 'matching';
  update semantic_private.assertion_preferences
  set display_state = 'default'
  where assertion_id = calendar_assertion_id and user_id = viewer_user_id;
  if exists (
    select 1 from semantic_private.assertion_surface_permissions
    where assertion_id = calendar_assertion_id and user_id = viewer_user_id
      and surface in ('matching', 'bio', 'icebreaker') and can_select
  ) then
    raise exception 'confirmation downgrade retained Calendar surface permission';
  end if;

  -- Per-run YouTube policy, typed mapping semantics, and weak creator transfer.
  -- Publish the synthetic revision because production semantic runs are pinned
  -- to a published ontology version; the earlier contract rows retain their
  -- immutable reference to the now-retired seed revision.
  perform ontology.publish_version(draft_version_id);
  insert into semantic_private.semantic_runs (
    id, user_id, ontology_version_id, resolver_model_id, scorer_model_id,
    input_revision, input_hash, status, started_at
  ) values (
    youtube_run_id, viewer_user_id, draft_version_id,
    resolver_model_id, scorer_model_id, 0, 'synthetic-youtube-input', 'running',
    '2026-08-10T00:00:00Z'
  );
  insert into ontology.youtube_channels (
    id, youtube_channel_id, canonical_title
  ) values (
    youtube_channel_row_id, 'UCsynthetic_channel_0001', 'Synthetic Channel'
  );
  insert into ontology.youtube_channel_resolutions (
    id, youtube_channel_row_id, ontology_version_id, channel_role,
    represented_concept_id, identity_match_method, exact_identity_match,
    review_state, resolution_version, reviewed_at
  ) values (
    channel_resolution_id, youtube_channel_row_id, draft_version_id,
    'official_creator', creator_concept_id, 'provider_channel_id', true,
    'approved', 'synthetic-v1', now()
  );
  begin
    update ontology.youtube_channel_resolutions
    set evidence = '{"nested":{"raw_event":"synthetic-forbidden"}}'::jsonb
    where id = channel_resolution_id;
    raise exception 'nested raw channel evidence passed the payload firewall';
  exception
    when check_violation then null;
  end;
  insert into semantic_private.ingestion_runs (
    id, user_id, source_code, connector_version, input_hash, status
  ) values (
    youtube_ingestion_id, viewer_user_id, 'youtube', 'synthetic-v0.2',
    'synthetic-youtube-ingestion', 'running'
  );
  insert into semantic_private.observations (
    id, user_id, ingestion_run_id, source_code, data_type,
    observation_kind, action_type, source_item_hmac, record_fingerprint,
    content_lineage_hmac, payload_schema_version, normalized_payload,
    privacy_class, allow_external_resolution
  ) values (
    youtube_observation_id, viewer_user_id, youtube_ingestion_id, 'youtube',
    'liked_video', 'public_content', 'liked_video', 'synthetic-youtube-item',
    'synthetic-youtube-record', repeat('e', 64), 'synthetic-v0.2', '{}'::jsonb,
    'public_catalog', false
  );
  begin
    insert into semantic_private.youtube_observation_channels (
      semantic_run_id, observation_id, user_id, youtube_channel_row_id,
      channel_resolution_id, ontology_version_id, observation_relation,
      target_semantics, evidence_weight, mapping_agreement, evidence_quality
    ) values (
      youtube_run_id, youtube_observation_id, viewer_user_id,
      youtube_channel_row_id, channel_resolution_id, draft_version_id,
      'uploaded_by', 'channel_identity', 0.25, 1.0, 0.9
    );
    raise exception 'deny-all YouTube run accepted channel identity';
  exception
    when raise_exception then
      if sqlerrm = 'deny-all YouTube run accepted channel identity' then raise; end if;
  end;
  begin
    insert into semantic_private.observation_mappings (
      id, semantic_run_id, observation_id, user_id, ontology_version_id,
      concept_id, mapping_method, mapping_state, confidence, candidate_rank,
      feature_snapshot, evidence_path, cross_source_fusion_allowed,
      youtube_semantic_kind, recency_weight, recency_quality,
      recency_policy_version, recency_rule_id, recency_status,
      recency_timestamp_quality, recency_as_of
    ) values (
      youtube_mapping_id, youtube_run_id, youtube_observation_id,
      viewer_user_id, draft_version_id, italy_concept_id,
      'provider_metadata', 'accepted', 0.95, 1, '{}'::jsonb, '{}'::jsonb,
      true, 'provider_topic', 0.9, 1.0, 'written-recency-v1.0.0',
      'video.like.recent', 'recent', 'known', '2026-08-10T00:00:00Z'
    );
    raise exception 'deny-all YouTube run accepted cross-source fusion';
  exception
    when raise_exception then
      if sqlerrm = 'deny-all YouTube run accepted cross-source fusion' then raise; end if;
  end;
  insert into semantic_private.observation_mappings (
    id, semantic_run_id, observation_id, user_id, ontology_version_id,
    concept_id, mapping_method, mapping_state, confidence, candidate_rank,
    feature_snapshot, evidence_path, cross_source_fusion_allowed,
    youtube_semantic_kind, recency_weight, recency_quality,
    recency_policy_version, recency_rule_id, recency_status,
    recency_timestamp_quality, recency_as_of
  ) values (
    youtube_mapping_id, youtube_run_id, youtube_observation_id,
    viewer_user_id, draft_version_id, italy_concept_id,
    'provider_metadata', 'accepted', 0.95, 1, '{}'::jsonb, '{}'::jsonb,
    false, 'provider_topic', 0.9, 1.0, 'written-recency-v1.0.0',
    'video.like.recent', 'recent', 'known', '2026-08-10T00:00:00Z'
  );
  begin
    update semantic_private.youtube_run_policies
    set allow_channel_identity = true,
        youtube_resolver_model_id = youtube_model_id
    where semantic_run_id = youtube_run_id;
    raise exception 'YouTube gate enabled without approval';
  exception
    when check_violation then null;
  end;
  insert into ontology.youtube_policy_approvals (
    id, approval_reference, approval_version, approval_state,
    allow_channel_identity, allow_role_resolution, allow_uploader_tags,
    allow_title_tags, allow_cross_source_fusion, allow_bio,
    allow_icebreaker, allow_explanation, approved_at
  ) values (
    youtube_approval_id, 'synthetic:approval:v0.2', 'synthetic-v1', 'approved',
    true, true, true, true, true, true, true, true, now()
  );
  update semantic_private.youtube_run_policies
  set youtube_resolver_model_id = youtube_model_id,
      approval_id = youtube_approval_id,
      policy_version = 'synthetic_approved:v1',
      allow_channel_identity = true,
      allow_role_resolution = true,
      allow_uploader_tags = true,
      allow_title_tags = true,
      allow_cross_source_fusion = true,
      allow_bio = true,
      allow_icebreaker = true,
      allow_explanation = true
  where semantic_run_id = youtube_run_id;
  update semantic_private.observation_mappings
  set cross_source_fusion_allowed = true
  where id = youtube_mapping_id;
  begin
    insert into semantic_private.youtube_observation_channels (
      semantic_run_id, observation_id, user_id, youtube_channel_row_id,
      channel_resolution_id, ontology_version_id, observation_relation,
      target_semantics, evidence_weight, mapping_agreement, evidence_quality,
      cross_source_fusion_allowed
    ) values (
      youtube_run_id, youtube_observation_id, viewer_user_id,
      youtube_channel_row_id, channel_resolution_id, draft_version_id,
      'uploaded_by', 'represented_creator', 0.80, 1.0, 0.90, true
    );
    raise exception 'one liked video carried strong represented-creator evidence';
  exception
    when raise_exception then
      if sqlerrm = 'one liked video carried strong represented-creator evidence' then raise; end if;
  end;
  insert into semantic_private.youtube_observation_channels (
    semantic_run_id, observation_id, user_id, youtube_channel_row_id,
    channel_resolution_id, ontology_version_id, observation_relation,
    target_semantics, evidence_weight, mapping_agreement, evidence_quality,
    recency_weight, recency_quality, recency_policy_version,
    recency_rule_id, recency_status, recency_timestamp_quality,
    cross_source_fusion_allowed
  ) values (
    youtube_run_id, youtube_observation_id, viewer_user_id,
    youtube_channel_row_id, channel_resolution_id, draft_version_id,
    'uploaded_by', 'represented_creator', 0.20, 1.0, 0.90,
    0.90, 1.0, 'written-recency-v1.0.0', 'video.like.recent',
    'recent', 'known', true
  );
  if not exists (
    select 1 from semantic_private.youtube_observation_channels
    where semantic_run_id = youtube_run_id
      and observation_id = youtube_observation_id
      and recency_weight = 0.90
      and recency_rule_id = 'video.like.recent'
      and recency_as_of = '2026-08-10T00:00:00Z'::timestamptz
  ) then
    raise exception 'channel evidence did not persist a run-pinned recency audit';
  end if;
  begin
    update semantic_private.observation_mappings
    set recency_weight = 1.5 where id = youtube_mapping_id;
    raise exception 'unbounded recency weight was accepted';
  exception
    when check_violation then null;
  end;
  if not exists (
    select 1 from semantic_private.observation_mappings
    where id = youtube_mapping_id
      and cross_source_fusion_allowed
      and recency_weight = 0.9
      and recency_quality = 1.0
      and recency_policy_version = 'written-recency-v1.0.0'
      and recency_rule_id = 'video.like.recent'
      and recency_status = 'recent'
      and recency_timestamp_quality = 'known'
      and recency_as_of = '2026-08-10T00:00:00Z'::timestamptz
  ) then
    raise exception 'typed YouTube fusion/recency state was not persisted';
  end if;
  begin
    update semantic_private.observation_mappings
    set recency_as_of = '2026-08-10T00:00:01Z'
    where id = youtube_mapping_id;
    raise exception 'mapping recency clock drifted within one semantic run';
  exception
    when check_violation then null;
  end;
  begin
    update semantic_private.observation_mappings
    set recency_status = 'unknown_timestamp',
        recency_timestamp_quality = 'unknown',
        recency_quality = 1.0
    where id = youtube_mapping_id;
    raise exception 'unknown timestamp retained perfect quality';
  exception
    when check_violation then null;
  end;
  update ontology.youtube_policy_approvals
  set approval_state = 'revoked', revoked_at = now()
  where id = youtube_approval_id;
  if semantic_private.youtube_run_gate_allowed(youtube_run_id, 'bio') then
    raise exception 'revoked YouTube approval remained active';
  end if;
  update ontology.youtube_policy_approvals
  set approval_state = 'approved', revoked_at = null
  where id = youtube_approval_id;

  -- Calendar canonical segment HMACs, mirrors, optional origin, journeys,
  -- non-transit candidate enforcement, and normalized booked events.
  insert into semantic_private.ingestion_runs (
    id, user_id, source_code, connector_version, input_hash, status
  ) values
    (apple_ingestion_id, viewer_user_id, 'apple_calendar', 'synthetic-v0.2',
     'synthetic-apple-calendar-input', 'running'),
    (google_ingestion_id, viewer_user_id, 'google_calendar', 'synthetic-v0.2',
     'synthetic-google-calendar-input', 'running');
  insert into semantic_private.observations (
    id, user_id, ingestion_run_id, source_code, data_type,
    observation_kind, action_type, occurred_at, source_item_hmac,
    record_fingerprint, content_lineage_hmac, payload_schema_version,
    normalized_payload, privacy_class, allow_external_resolution
  ) values
    (flight_observation_id, viewer_user_id, apple_ingestion_id,
     'apple_calendar', 'event', 'calendar_event', 'scheduled',
     '2027-01-01T00:00:00Z', 'synthetic-flight-primary',
     'synthetic-flight-record-primary', flight_lineage, 'synthetic-v0.2',
     '{}'::jsonb, 'private_text', false),
    (mirror_observation_id, viewer_user_id, google_ingestion_id,
     'google_calendar', 'event', 'calendar_event', 'scheduled',
     '2027-01-01T00:00:00Z', 'synthetic-flight-mirror',
     'synthetic-flight-record-mirror', flight_lineage, 'synthetic-v0.2',
     '{}'::jsonb, 'private_text', false),
    (terminal_observation_id, viewer_user_id, apple_ingestion_id,
     'apple_calendar', 'event', 'calendar_event', 'scheduled',
     '2027-01-01T04:00:00Z', 'synthetic-flight-terminal',
     'synthetic-flight-record-terminal', terminal_lineage, 'synthetic-v0.2',
     '{}'::jsonb, 'private_text', false),
    (booked_observation_id, viewer_user_id, apple_ingestion_id,
     'apple_calendar', 'event', 'calendar_event', 'booked',
     '2027-02-01T00:00:00Z', 'synthetic-booked-event',
     'synthetic-booked-record', booked_lineage, 'synthetic-v0.2',
     '{}'::jsonb, 'private_text', false);
  begin
    insert into semantic_private.observation_mappings (
      semantic_run_id, observation_id, user_id, ontology_version_id,
      concept_id, mapping_method, mapping_state, confidence, candidate_rank,
      feature_snapshot, evidence_path
    ) values (
      hometown_run_id, flight_observation_id, viewer_user_id,
      published_version_id, italy_concept_id, 'curated_alias', 'accepted',
      0.95, 1, '{}'::jsonb, '{}'::jsonb
    );
    raise exception 'unclassified Calendar observation entered mapping';
  exception
    when raise_exception then
      if sqlerrm = 'unclassified Calendar observation entered mapping' then
        raise;
      end if;
      if sqlerrm <> 'calendar mappings require an eligible allowlisted classification' then
        raise exception 'unexpected Calendar mapping guard failure: %', sqlerrm;
      end if;
  end;
  insert into semantic_private.calendar_event_classifications (
    id, observation_id, user_id, classifier_model_id, event_class,
    disposition, mapping_agreement, evidence_quality, feature_snapshot
  ) values
    (flight_classification_id, flight_observation_id, viewer_user_id,
     calendar_model_id, 'travel_itinerary', 'eligible_private_semantics',
     0.98, 0.95, '{"classifier_version":"synthetic-v1"}'::jsonb),
    (mirror_classification_id, mirror_observation_id, viewer_user_id,
     calendar_model_id, 'travel_itinerary', 'eligible_private_semantics',
     0.98, 0.95, '{"classifier_version":"synthetic-v1"}'::jsonb),
    (terminal_classification_id, terminal_observation_id, viewer_user_id,
     calendar_model_id, 'travel_itinerary', 'eligible_private_semantics',
     0.98, 0.95, '{"classifier_version":"synthetic-v1"}'::jsonb),
    (booked_classification_id, booked_observation_id, viewer_user_id,
     calendar_model_id, 'public_ticketed_event', 'eligible_private_semantics',
     0.96, 0.94, '{"classifier_version":"synthetic-v1","artifact_type":"public_ticket"}'::jsonb);
  insert into semantic_private.observation_mappings (
    semantic_run_id, observation_id, user_id, ontology_version_id,
    concept_id, mapping_method, mapping_state, confidence, candidate_rank,
    feature_snapshot, evidence_path
  ) values (
    hometown_run_id, flight_observation_id, viewer_user_id,
    published_version_id, italy_concept_id, 'curated_alias', 'accepted',
    0.95, 1, '{}'::jsonb, '{}'::jsonb
  );
  begin
    update semantic_private.calendar_event_classifications
    set feature_snapshot = '{"flags":{"raw_calendar":"synthetic-forbidden"}}'::jsonb
    where id = flight_classification_id;
    raise exception 'nested raw Calendar payload passed the firewall';
  exception
    when check_violation then null;
  end;
  begin
    update semantic_private.calendar_event_classifications
    set feature_snapshot = jsonb_build_object(
      'flags', jsonb_build_object('safe', repeat('x', 9000))
    )
    where id = flight_classification_id;
    raise exception 'oversize Calendar payload passed the firewall';
  exception
    when check_violation then null;
  end;

  insert into semantic_private.travel_segments (
    id, user_id, calendar_classification_id, source_observation_id,
    ontology_version_id, segment_lineage_hmac, origin_place_concept_id,
    destination_place_concept_id, departure_at, arrival_at, segment_state
  ) values (
    connection_segment_id, viewer_user_id, flight_classification_id,
    flight_observation_id, draft_version_id, flight_lineage, null,
    italy_concept_id, '2027-01-01T00:00:00Z', '2027-01-01T02:00:00Z',
    'planned'
  );
  insert into semantic_private.travel_segment_sources (
    travel_segment_id, user_id, ontology_version_id,
    calendar_classification_id, source_observation_id, source_role
  ) values (
    connection_segment_id, viewer_user_id, draft_version_id,
    mirror_classification_id, mirror_observation_id, 'mirror'
  );
  if (
    select count(*) from semantic_private.travel_segment_sources
    where travel_segment_id = connection_segment_id
  ) <> 2 then
    raise exception 'connector mirrors did not collapse onto one segment';
  end if;
  begin
    insert into semantic_private.travel_segments (
      user_id, calendar_classification_id, source_observation_id,
      ontology_version_id, segment_lineage_hmac,
      destination_place_concept_id, segment_state
    ) values (
      viewer_user_id, terminal_classification_id, terminal_observation_id,
      draft_version_id, flight_lineage, terminal_place_id, 'planned'
    );
    raise exception 'duplicate canonical segment HMAC was accepted';
  exception
    when unique_violation then null;
  end;
  insert into semantic_private.travel_segments (
    id, user_id, calendar_classification_id, source_observation_id,
    ontology_version_id, segment_lineage_hmac, origin_place_concept_id,
    destination_place_concept_id, departure_at, arrival_at, segment_state
  ) values (
    terminal_segment_id, viewer_user_id, terminal_classification_id,
    terminal_observation_id, draft_version_id, terminal_lineage,
    italy_concept_id, terminal_place_id, '2027-01-01T04:00:00Z',
    '2027-01-01T06:00:00Z', 'planned'
  );
  insert into semantic_private.travel_journeys (
    id, user_id, ontology_version_id, journey_lineage_hmac,
    round_trip_group_hmac, journey_state, window_start, window_end,
    anchor_place_concept_id, terminal_place_concept_id
  ) values (
    journey_id, viewer_user_id, draft_version_id, journey_lineage,
    repeat('f', 64), 'planned', '2027-01-01T00:00:00Z',
    '2027-01-01T06:00:00Z', origin_place_id, terminal_place_id
  );
  insert into semantic_private.travel_journey_segments (
    journey_id, segment_id, user_id, ontology_version_id,
    segment_order, segment_role
  ) values
    (journey_id, connection_segment_id, viewer_user_id, draft_version_id,
     0, 'connection'),
    (journey_id, terminal_segment_id, viewer_user_id, draft_version_id,
     1, 'terminal');
  begin
    insert into semantic_private.scheduled_travel_candidates (
      user_id, travel_journey_id, ontology_version_id,
      destination_place_concept_id, action_semantics, strength,
      mapping_agreement, evidence_quality
    ) values (
      viewer_user_id, journey_id, draft_version_id, italy_concept_id,
      'booked', 0.9, 0.98, 0.95
    );
    raise exception 'transit place became a scheduled destination';
  exception
    when foreign_key_violation then null;
    when raise_exception then
      if sqlerrm = 'transit place became a scheduled destination' then raise; end if;
      if sqlerrm <> 'scheduled travel candidate requires a non-transit journey terminal' then
        raise exception 'unexpected transit candidate guard failure: %', sqlerrm;
      end if;
  end;
  insert into semantic_private.scheduled_travel_candidates (
    id, user_id, travel_journey_id, ontology_version_id,
    destination_place_concept_id, action_semantics, strength,
    mapping_agreement, evidence_quality, recency_weight, recency_quality,
    recency_policy_version, recency_rule_id, recency_status,
    recency_timestamp_quality, recency_as_of,
    display_payload
  ) values (
    scheduled_candidate_id, viewer_user_id, journey_id, draft_version_id,
    terminal_place_id, 'booked', 0.9, 0.98, 0.95,
    0.80, 1.0, 'written-recency-v1.0.0',
    'calendar.scheduled.anticipation', 'future_anticipation', 'known',
    '2026-08-10T00:00:00Z',
    '{"template_key":"scheduled_trip","wording_version":"synthetic-v1","place_label":"Synthetic Destination"}'::jsonb
  );

  insert into semantic_private.booked_activity_candidates (
    id, user_id, calendar_classification_id, source_observation_id,
    ontology_version_id, predicate_key, target_concept_id,
    booking_lineage_hmac, action_semantics, booking_state,
    strength, mapping_agreement, evidence_quality,
    recency_weight, recency_quality, recency_policy_version,
    recency_rule_id, recency_status, recency_timestamp_quality,
    recency_as_of, display_payload
  ) values (
    booked_candidate_id, viewer_user_id, booked_classification_id,
    booked_observation_id, draft_version_id, 'booked_event', event_concept_id,
    booked_lineage, 'booked', 'planned', 0.9, 0.96, 0.94,
    0.82, 1.0, 'written-recency-v1.0.0',
    'calendar.scheduled.anticipation', 'future_anticipation', 'known',
    '2026-08-10T00:00:00Z',
    '{"template_key":"booked_event","wording_version":"synthetic-v1","target_label":"Synthetic Event Category"}'::jsonb
  );
  insert into semantic_private.memories_snapshots (
    id, user_id, ontology_version_id, builder_model_id, input_revision,
    presentation_version, state
  ) values (
    memories_snapshot_id, viewer_user_id, draft_version_id,
    memories_model_id, 0, 'synthetic-v1', 'building'
  );
  insert into semantic_private.memories_snapshot_items (
    snapshot_id, user_id, booked_activity_candidate_id, item_key,
    item_kind, display_label, rank
  ) values (
    memories_snapshot_id, viewer_user_id, booked_candidate_id,
    'synthetic-booked-item', 'booked_activity_candidate',
    'Synthetic booked event', 0
  );
  begin
    insert into semantic_private.memories_snapshot_items (
      snapshot_id, user_id, scheduled_travel_candidate_id,
      booked_activity_candidate_id, item_key, item_kind, display_label, rank
    ) values (
      memories_snapshot_id, viewer_user_id, scheduled_candidate_id,
      booked_candidate_id, 'synthetic-invalid-item',
      'booked_activity_candidate', 'Invalid synthetic item', 1
    );
    raise exception 'Memories item accepted two candidate identities';
  exception
    when check_violation then null;
  end;

  -- Recurrence review floor and stronger public wording license.
  begin
    insert into semantic_private.recurring_place_candidates (
      user_id, ontology_version_id, place_concept_id, candidate_kind,
      proposed_predicate_key, distinct_journey_count, distinct_month_count,
      window_start, window_end, strength, mapping_agreement, evidence_quality
    ) values (
      viewer_user_id, draft_version_id, terminal_place_id,
      'recurring_destination', 'recurring_presence_at', 2, 2,
      '2026-01-01T00:00:00Z', '2026-03-31T00:00:00Z',
      0.7, 0.9, 0.9
    );
    raise exception '89-day recurrence candidate was accepted';
  exception
    when check_violation then null;
  end;
  insert into semantic_private.recurring_place_candidates (
    user_id, ontology_version_id, place_concept_id, candidate_kind,
    proposed_predicate_key, distinct_journey_count, distinct_month_count,
    window_start, window_end, strength, mapping_agreement, evidence_quality
  ) values (
    viewer_user_id, draft_version_id, terminal_place_id,
    'recurring_destination', 'recurring_presence_at', 2, 2,
    '2026-01-01T00:00:00Z', '2026-04-01T00:00:00Z',
    0.7, 0.9, 0.9
  );
  begin
    insert into semantic_private.recurring_place_candidates (
      user_id, ontology_version_id, place_concept_id, candidate_kind,
      proposed_predicate_key, distinct_journey_count, distinct_month_count,
      complete_round_trip_count, window_start, window_end, strength,
      mapping_agreement, evidence_quality, confirmation_state, wording_state,
      public_naming_allowed
    ) values (
      viewer_user_id, draft_version_id, terminal_place_id,
      'recurring_destination', 'recurring_presence_at', 3, 4, 2,
      '2026-01-01T00:00:00Z', '2026-06-29T00:00:00Z',
      0.85, 0.95, 0.95, 'user_confirmed', 'often_returns_confirmed', true
    );
    raise exception 'sub-180-day public recurrence wording was accepted';
  exception
    when check_violation then null;
  end;
  insert into semantic_private.recurring_place_candidates (
    user_id, ontology_version_id, place_concept_id, candidate_kind,
    proposed_predicate_key, distinct_journey_count, distinct_month_count,
    complete_round_trip_count, window_start, window_end, strength,
    mapping_agreement, evidence_quality, confirmation_state, wording_state,
    public_naming_allowed
  ) values (
    viewer_user_id, draft_version_id, terminal_place_id,
    'recurring_destination', 'recurring_presence_at', 3, 4, 2,
    '2026-01-01T00:00:00Z', '2026-06-30T00:00:00Z',
    0.85, 0.95, 0.95, 'user_confirmed', 'often_returns_confirmed', true
  );
  begin
    insert into semantic_private.recurring_place_candidates (
      user_id, ontology_version_id, place_concept_id, candidate_kind,
      proposed_predicate_key, distinct_journey_count, distinct_month_count,
      window_start, window_end, strength, mapping_agreement, evidence_quality
    ) values (
      viewer_user_id, draft_version_id, terminal_place_id,
      'recurring_destination', 'hometown', 3, 3,
      '2026-01-01T00:00:00Z', '2026-07-01T00:00:00Z',
      0.8, 0.9, 0.9
    );
    raise exception 'recurrence unexpectedly licensed hometown';
  exception
    when check_violation then null;
  end;

  -- Directional dyad alignment requires matching permission on both sides.
  insert into semantic_private.dyad_runs (
    id, viewer_user_id, subject_user_id, viewer_revision, subject_revision,
    ontology_version_id, ranker_model_id, run_purpose, input_hash, status
  ) values (
    dyad_run_id, viewer_user_id, subject_user_id, 0, 0,
    published_version_id, ranker_model_id, 'both', 'synthetic-dyad-input',
    'running'
  );
  begin
    insert into semantic_private.dyad_alignment_pairs (
      dyad_run_id, viewer_user_id, subject_user_id,
      viewer_assertion_id, subject_assertion_id, bridge_concept_id,
      ontology_version_id, graph_distance, relation_distance,
      embedding_distance, transport_mass, specificity, information_value
    ) values (
      dyad_run_id, viewer_user_id, subject_user_id,
      viewer_assertion_id, subject_assertion_id, italy_concept_id,
      published_version_id, 0.1, 0.2, 0.15, 0.5, 0.8, 0.75
    );
    raise exception 'dyad alignment ignored matching permission';
  exception
    when raise_exception then
      if sqlerrm = 'dyad alignment ignored matching permission' then raise; end if;
  end;
  update semantic_private.assertion_surface_permissions
  set can_select = true, permission_source = 'user_choice'
  where assertion_id in (viewer_assertion_id, subject_assertion_id)
    and surface = 'matching';
  insert into semantic_private.dyad_alignment_pairs (
    dyad_run_id, viewer_user_id, subject_user_id,
    viewer_assertion_id, subject_assertion_id, bridge_concept_id,
    ontology_version_id, graph_distance, relation_distance,
    embedding_distance, transport_mass, specificity, information_value
  ) values (
    dyad_run_id, viewer_user_id, subject_user_id,
    viewer_assertion_id, subject_assertion_id, italy_concept_id,
    published_version_id, 0.1, 0.2, 0.15, 0.5, 0.8, 0.75
  );
  update semantic_private.dyad_runs
  set status = 'succeeded', finished_at = now(),
      semantic_proximity = 0.7, comparability = 0.8
  where id = dyad_run_id;
  update semantic_private.assertion_surface_permissions
  set can_select = false, permission_source = 'user_choice'
  where assertion_id = subject_assertion_id and user_id = subject_user_id
    and surface = 'matching';
  if not exists (
    select 1 from semantic_private.dyad_runs
    where id = dyad_run_id and status = 'stale'
  ) then
    raise exception 'matching permission revocation did not stale dyad output';
  end if;
end;
$$;

rollback;
