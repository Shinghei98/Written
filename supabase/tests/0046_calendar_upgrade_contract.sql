-- Adapted from the v0.3.1 reference `sql/tests/005_calendar_upgrade_contract.sql`.
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

-- Run after applying 005 twice to a database seeded with
-- fixtures/004_calendar_upgrade_fixture.sql.

begin;

do $calendar_upgrade_contract$
declare
  fixture_user_id uuid := ontology.stable_uuid(
    'written:test:v0.3-calendar-upgrade-user'
  );
  fixture_candidate_id uuid := ontology.stable_uuid(
    'written:test:v0.3-calendar-upgrade-candidate'
  );
  fixture_classification_id uuid := ontology.stable_uuid(
    'written:test:v0.3-calendar-upgrade-classification'
  );
  fixture_draft_version_id uuid := ontology.stable_uuid(
    'written:test:v0.3-calendar-upgrade-draft'
  );
  generic_event_hub_id constant uuid :=
    '8816b5e8-ce07-582b-abdf-86f7359d1f1e'::uuid;
  canonical_label text;
begin
  select preferred_label into canonical_label
  from ontology.concept_revisions
  where ontology_version_id = fixture_draft_version_id
    and concept_id = generic_event_hub_id
    and status = 'active';

  if (select revision from semantic_private.user_state_versions
      where user_id = fixture_user_id) <> 1 then
    raise exception 'Calendar upgrade/replay did not bump the legacy user exactly once';
  end if;
  if not exists (
    select 1
    from semantic_private.observations as observation
    where observation.id = ontology.stable_uuid(
            'written:test:v0.3-calendar-upgrade-observation'
          )
      and observation.user_id = fixture_user_id
      and observation.source_code = 'apple_calendar'
      and observation.data_type = 'calendar_event'
      and observation.observation_kind = 'sanitized_classification'
      and observation.action_type = 'booked'
      and observation.source_item_hmac = repeat(md5(
        'written:v03:legacy-calendar-item:' || observation.id::text
      ), 2)
      and observation.record_fingerprint = repeat(md5(
        'written:v03:legacy-calendar-record:' || observation.id::text
      ), 2)
      and observation.session_hmac is null
      and observation.payload_schema_version = 'calendar-v03'
      and observation.normalized_payload = jsonb_build_object(
        'schema_version', 'calendar-v03',
        'record_kind', 'calendar_classification',
        'classification_state', 'review'
      )
      and observation.raw_blob_ref is null
      and observation.action_weight = 0.0
      and observation.privacy_class = 'private_calendar_sanitized'
      and not observation.allow_external_resolution
      and observation.lifecycle_state = 'active'
      and observation.exclusion_code is null
      and observation.excluded_at is null
  ) then
    raise exception 'legacy Calendar observation was not minimized to the exact review projection';
  end if;
  if exists (
    select 1 from semantic_private.memories_snapshot_items
    where user_id = fixture_user_id
  ) then
    raise exception 'legacy Calendar presentation items survived v0.3';
  end if;
  if not exists (
    select 1
    from semantic_private.booked_activity_candidates as candidate
    where candidate.id = fixture_candidate_id
      and candidate.user_id = fixture_user_id
      and candidate.target_concept_id = generic_event_hub_id
      and candidate.target_external_link_id is null
      and candidate.display_payload ->> 'target_label' = canonical_label
      and candidate.display_payload ->> 'predicate_label' = 'Booked event'
      and candidate.display_payload::text not like '%Synthetic Private Caption%'
  ) then
    raise exception 'legacy booked candidate was not downgraded and canonically rendered';
  end if;
  if semantic_private.calendar_classification_is_current_v03(
       fixture_classification_id, fixture_user_id,
       ontology.stable_uuid('written:test:v0.3-calendar-upgrade-observation'),
       fixture_draft_version_id
     ) then
    raise exception 'backfilled legacy classification was blessed as current typed evidence';
  end if;
  if (
    select count(*) from semantic_private.worker_jobs
    where user_id = fixture_user_id
      and job_type = 'classify_calendar'
  ) <> 1 or (
    select count(*) from semantic_private.worker_jobs
    where user_id = fixture_user_id
      and job_type = 'recompute_user'
  ) <> 1 then
    raise exception 'Calendar upgrade did not queue one exact rebuild per job type';
  end if;
end
$calendar_upgrade_contract$;

rollback;
