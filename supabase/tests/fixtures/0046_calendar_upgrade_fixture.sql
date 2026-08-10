-- Adapted from the v0.3.1 reference `sql/tests/fixtures/004_calendar_upgrade_fixture.sql`.
-- Gates application migration 0046.
--
-- The reference chain numbers its files 001-006 while this repository's
-- are 0042-0047, so contract numbering is off by two and the two
-- fixture lanes are off by one -- reference fixture `004` gates the
-- app's 0046, and reference fixture `005` gates 0047. The file name
-- states which migration it gates so nobody re-derives that each time.
--
-- Substituted from the reference: 7 `private.` -> `semantic_private.`
-- and 0 bare `'private'` schema arguments. Privacy-class VALUES
-- such as `'private_text'` are deliberately untouched: they are
-- check-constraint values, not schema names, and rewriting them is how
-- a mechanical rename corrupts a contract while still passing.

-- Run after 004_product_surfaces.sql and before 005. This fixture deliberately
-- persists synthetic v0.2 Calendar output so the v0.3 upgrade and replay can
-- be tested against data, not only an empty schema.

do $calendar_upgrade_fixture$
declare
  fixture_user_id uuid := ontology.stable_uuid(
    'written:test:v0.3-calendar-upgrade-user'
  );
  fixture_ingestion_id uuid := ontology.stable_uuid(
    'written:test:v0.3-calendar-upgrade-ingestion'
  );
  fixture_observation_id uuid := ontology.stable_uuid(
    'written:test:v0.3-calendar-upgrade-observation'
  );
  fixture_classification_id uuid := ontology.stable_uuid(
    'written:test:v0.3-calendar-upgrade-classification'
  );
  fixture_candidate_id uuid := ontology.stable_uuid(
    'written:test:v0.3-calendar-upgrade-candidate'
  );
  fixture_snapshot_id uuid := ontology.stable_uuid(
    'written:test:v0.3-calendar-upgrade-snapshot'
  );
  fixture_draft_version_id uuid := ontology.stable_uuid(
    'written:test:v0.3-calendar-upgrade-draft'
  );
  fixture_event_concept_id uuid := ontology.stable_uuid(
    'written:test:v0.3-calendar-upgrade-event'
  );
  generic_event_hub_id constant uuid :=
    '8816b5e8-ce07-582b-abdf-86f7359d1f1e'::uuid;
  published_version_id uuid;
  calendar_model_id uuid;
  memories_model_id uuid;
  fixture_lineage constant text := repeat('a', 64);
begin
  select id into published_version_id
  from ontology.versions where status = 'published';
  select id into calendar_model_id
  from ontology.model_versions
  where model_role = 'calendar_classifier' and status = 'active'
  order by created_at desc, id limit 1;
  select id into memories_model_id
  from ontology.model_versions
  where model_role = 'memories_builder' and status = 'active'
  order by created_at desc, id limit 1;

  insert into auth.users (id, aud, role, created_at, updated_at) values (
    fixture_user_id, 'authenticated', 'authenticated', now(), now()
  );
  insert into semantic_private.user_state_versions (user_id, revision)
  values (fixture_user_id, 0)
  on conflict (user_id) do update set revision = excluded.revision;

  insert into ontology.versions (
    id, version, parent_version_id, status, description
  ) values (
    fixture_draft_version_id, 'synthetic-calendar-upgrade-draft',
    published_version_id, 'draft', 'Synthetic v0.2 upgrade fixture'
  );
  insert into ontology.concepts (id, concept_key) values (
    fixture_event_concept_id, 'test:event:calendar-upgrade'
  );
  insert into ontology.concept_revisions (
    ontology_version_id, concept_id, preferred_label, concept_kind,
    sensitivity, inference_policy, status
  ) values (
    fixture_draft_version_id, fixture_event_concept_id,
    'Synthetic Public Event', 'event', 'ordinary', 'review_required', 'active'
  );
  insert into ontology.concept_revisions (
    ontology_version_id, concept_id, preferred_label, concept_kind,
    definition, sensitivity, inference_policy, status, metadata
  )
  select fixture_draft_version_id, revision.concept_id,
         revision.preferred_label, revision.concept_kind,
         revision.definition, revision.sensitivity,
         revision.inference_policy, revision.status, revision.metadata
  from ontology.concept_revisions as revision
  where revision.ontology_version_id = published_version_id
    and revision.concept_id = generic_event_hub_id;

  insert into semantic_private.ingestion_runs (
    id, user_id, source_code, connector_version, input_hash, status
  ) values (
    fixture_ingestion_id, fixture_user_id, 'apple_calendar',
    'synthetic-v0.2', 'synthetic-calendar-upgrade-input', 'running'
  );
  insert into semantic_private.observations (
    id, user_id, ingestion_run_id, source_code, data_type,
    observation_kind, action_type, occurred_at, source_item_hmac,
    record_fingerprint, content_lineage_hmac, payload_schema_version,
    normalized_payload, privacy_class, allow_external_resolution
  ) values (
    fixture_observation_id, fixture_user_id, fixture_ingestion_id,
    'apple_calendar', 'event', 'calendar_event', 'booked',
    '2027-02-01T00:00:00Z', 'synthetic-calendar-item',
    'synthetic-calendar-record', fixture_lineage, 'synthetic-v0.2',
    '{}'::jsonb, 'private_text', false
  );
  insert into semantic_private.calendar_event_classifications (
    id, observation_id, user_id, classifier_model_id, event_class,
    disposition, mapping_agreement, evidence_quality, feature_snapshot
  ) values (
    fixture_classification_id, fixture_observation_id, fixture_user_id,
    calendar_model_id, 'public_ticketed_event',
    'eligible_private_semantics', 0.96, 0.94,
    '{"classifier_version":"synthetic-v0.2"}'::jsonb
  );
  insert into semantic_private.booked_activity_candidates (
    id, user_id, calendar_classification_id, source_observation_id,
    ontology_version_id, predicate_key, target_concept_id,
    booking_lineage_hmac, action_semantics, booking_state,
    strength, mapping_agreement, evidence_quality, display_payload
  ) values (
    fixture_candidate_id, fixture_user_id, fixture_classification_id,
    fixture_observation_id, fixture_draft_version_id, 'booked_event',
    fixture_event_concept_id, fixture_lineage, 'booked', 'planned',
    0.90, 0.96, 0.94,
    '{"template_key":"booked_event","target_label":"Synthetic Private Caption"}'::jsonb
  );
  insert into semantic_private.memories_snapshots (
    id, user_id, ontology_version_id, builder_model_id, input_revision,
    presentation_version, state
  ) values (
    fixture_snapshot_id, fixture_user_id, fixture_draft_version_id,
    memories_model_id, 0, 'synthetic-upgrade-v0.2', 'building'
  );
  insert into semantic_private.memories_snapshot_items (
    snapshot_id, user_id, booked_activity_candidate_id, item_key,
    item_kind, display_label, rank, display_payload
  ) values (
    fixture_snapshot_id, fixture_user_id, fixture_candidate_id,
    'synthetic-calendar-upgrade-item', 'booked_activity_candidate',
    'Synthetic Private Caption', 0,
    '{"target_label":"Synthetic Private Caption"}'::jsonb
  );
end
$calendar_upgrade_fixture$;
