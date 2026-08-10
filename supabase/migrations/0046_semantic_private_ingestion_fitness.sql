-- Broad private ingestion, strict evidence, and typed HealthKit.
--
-- Adapted from the v0.3.1 package's `005_private_ingestion_and_fitness.sql`. The namespace rule and the
-- reason for it are in `0042_semantic_schema.sql`: the reference chain uses
-- `private` for its own objects and this app already owns that schema, so every
-- qualified reference here is `semantic_private`.
--
-- **Only schema references were translated.** Unlike 001 and 002, these files
-- use the word "private" in prose, in exception messages, and as a
-- `sensitivity` check-constraint *value*. Those are left exactly as written; a
-- blanket replace would have changed what the constraint accepts.
--
-- Ships no product behaviour. Nothing in Swift reads any of this.
--
-- Adapted against package v0.3.1, app commit b3e19ae, migration head 0043.

-- Written semantic system v0.3: broad private ingestion, strict evidence,
-- and purpose-limited HealthKit fitness semantics.
-- Apply after 004_product_surfaces.sql.
begin;

-- Python v0.2 emitted a Calendar privacy class that SQL v0.1 could not store.
-- V0.3 makes both sanitized private lanes explicit. Raw records do not use
-- this table; they live in raw_source_records below.
alter table semantic_private.observations
  drop constraint if exists observations_privacy_class_check,
  drop constraint if exists observations_privacy_class_v03_check,
  add constraint observations_privacy_class_v03_check check (privacy_class in (
    'public_catalog', 'private_text', 'sensitive', 'quantitative',
    'private_calendar_sanitized', 'private_fitness_sanitized'
  ));

-- A raw vault supports broad user-authorized ingestion without making every
-- record ontology evidence. Payload bytes are application-encrypted or held in
-- an encrypted object store; plaintext provider JSON is not a column type.
create table if not exists semantic_private.raw_source_records (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  ingestion_run_id uuid not null,
  source_code text not null references semantic_private.sources(source_code) on delete restrict,
  data_type text not null,
  occurred_at timestamptz,
  source_item_hmac text not null,
  record_fingerprint text not null,
  encryption_key_version text not null,
  encrypted_payload bytea,
  raw_blob_ref text,
  payload_content_type text not null default 'application/json',
  consent_purpose text not null,
  retention_policy_version text not null,
  retained_until timestamptz,
  lifecycle_state text not null default 'active',
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  unique (id, user_id),
  unique (user_id, source_code, record_fingerprint),
  foreign key (ingestion_run_id, user_id, source_code)
    references semantic_private.ingestion_runs(id, user_id, source_code)
    on delete no action deferrable initially deferred,
  constraint raw_source_records_payload_location_check check (
    (lifecycle_state = 'deleted'
      and num_nonnulls(encrypted_payload, raw_blob_ref) = 0)
    or (lifecycle_state <> 'deleted'
      and num_nonnulls(encrypted_payload, raw_blob_ref) = 1)
  ),
  constraint raw_source_records_ciphertext_size_check check (
    encrypted_payload is null or octet_length(encrypted_payload) between 16 and 10485760
  ),
  constraint raw_source_records_blob_ref_check check (
    raw_blob_ref is null or raw_blob_ref ~ '^vault/[0-9a-f]{64}$'
  ),
  constraint raw_source_records_opaque_identity_check check (
    source_item_hmac ~ '^[0-9a-f]{64}$'
    and record_fingerprint ~ '^[0-9a-f]{64}$'
  ),
  constraint raw_source_records_token_fields_check check (
    data_type ~ '^[a-z][a-z0-9_]{0,63}$'
    and encryption_key_version ~ '^[a-z0-9][a-z0-9_.-]{0,63}$'
    and retention_policy_version ~ '^[a-z0-9][a-z0-9_.-]{0,63}$'
    and payload_content_type
      ~ '^[a-z0-9][a-z0-9.+-]{0,63}/[a-z0-9][a-z0-9.+-]{0,63}$'
  ),
  constraint raw_source_records_purpose_check check (consent_purpose in (
    'source_distillation', 'calendar_distillation', 'fitness_connection'
  )),
  constraint raw_source_records_state_check check (
    lifecycle_state in ('active', 'expired', 'deleted')
  ),
  constraint raw_source_records_deletion_check check (
    (lifecycle_state = 'deleted' and deleted_at is not null)
    or (lifecycle_state <> 'deleted' and deleted_at is null)
  ),
  constraint raw_source_records_retention_check check (
    retained_until is null or retained_until > created_at
  )
);

create index if not exists raw_source_records_user_source_time_idx
  on semantic_private.raw_source_records (user_id, source_code, occurred_at desc)
  where lifecycle_state = 'active';

alter table semantic_private.raw_source_records
  drop constraint if exists raw_source_records_source_purpose_v03_check,
  add constraint raw_source_records_source_purpose_v03_check check (
    (source_code = 'healthkit' and consent_purpose = 'fitness_connection')
    or (
      source_code in ('apple_calendar', 'google_calendar')
      and consent_purpose = 'calendar_distillation'
    )
    or (
      source_code not in (
        'healthkit', 'apple_calendar', 'google_calendar'
      )
      and consent_purpose = 'source_distillation'
    )
  );

create or replace function semantic_private.guard_raw_source_record_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.user_id is distinct from old.user_id
     or new.ingestion_run_id is distinct from old.ingestion_run_id
     or new.source_code is distinct from old.source_code
     or new.data_type is distinct from old.data_type
     or new.occurred_at is distinct from old.occurred_at
     or new.source_item_hmac is distinct from old.source_item_hmac
     or new.record_fingerprint is distinct from old.record_fingerprint
     or new.payload_content_type is distinct from old.payload_content_type
     or new.consent_purpose is distinct from old.consent_purpose
     or new.retention_policy_version is distinct from old.retention_policy_version
     or new.created_at is distinct from old.created_at then
    raise exception 'raw record identity, source, purpose, and provenance are immutable';
  end if;
  if old.lifecycle_state = 'deleted' and (
       new.lifecycle_state <> 'deleted'
       or new.deleted_at is distinct from old.deleted_at
     ) then
    raise exception 'deleted raw records are terminal; reimport requires a new record';
  end if;
  if old.lifecycle_state = 'expired' and new.lifecycle_state = 'active' then
    raise exception 'expired raw records cannot be reactivated';
  end if;
  if old.retained_until is not null and (
       new.retained_until is null
       or new.retained_until > old.retained_until
     ) then
    raise exception 'raw-record retention may be shortened but not extended in place';
  end if;
  if old.lifecycle_state = 'active'
     and new.lifecycle_state <> 'active'
     and exists (
       select 1
       from semantic_private.fitness_candidate_support as support
       join semantic_private.fitness_habit_candidates as candidate
         on candidate.id = support.candidate_id
        and candidate.user_id = support.user_id
       where support.raw_source_record_id = old.id
         and candidate.review_state in ('candidate', 'user_confirmed')
     ) then
    raise exception 'retire linked fitness candidates before expiring raw support';
  end if;
  return new;
end;
$$;

drop trigger if exists raw_source_records_guard_update
  on semantic_private.raw_source_records;
create trigger raw_source_records_guard_update
before update on semantic_private.raw_source_records
for each row execute function semantic_private.guard_raw_source_record_update();

-- Sanitized observation payloads for Calendar and HealthKit are projections,
-- not a second raw store. These provisional checks protect new writes while
-- the exact closed projection and legacy minimization below are installed.
alter table semantic_private.observations
  drop constraint if exists observations_no_raw_private_payload_v03_check,
  add constraint observations_no_raw_private_payload_v03_check check (
    source_code not in ('apple_calendar', 'google_calendar', 'healthkit')
    or semantic_private.jsonb_payload_is_safe(normalized_payload, 8192, array[
      'schema_version', 'record_kind', 'classification_state', 'artifact_type',
      'purpose_scope', 'candidate_id', 'policy_version', 'reason_codes',
      'quality_factors', 'controlled_label', 'coverage_state'
    ]::text[])
  ) not valid;

alter table semantic_private.observations
  drop constraint if exists observations_private_identity_v03_check,
  add constraint observations_private_identity_v03_check check (
    source_code not in ('apple_calendar', 'google_calendar', 'healthkit')
    or (
      source_item_hmac ~ '^[0-9a-f]{64}$'
      and record_fingerprint ~ '^[0-9a-f]{64}$'
      and (
        content_lineage_hmac is null
        or content_lineage_hmac ~ '^[0-9a-f]{64}$'
      )
      and (session_hmac is null or session_hmac ~ '^[0-9a-f]{64}$')
      and payload_schema_version ~ '^[a-z0-9][-a-z0-9._:]{0,79}$'
      and raw_blob_ref is null
    )
  ) not valid;

-- Private Calendar/HealthKit observations never enter the generic mention or
-- training-label lanes. Typed candidate tables carry their reviewed semantic
-- projection directly; raw/private terms are not copied into mining inputs.
delete from semantic_private.mapping_feedback_labels as label
using semantic_private.observations as observation
where observation.id = label.observation_id
  and observation.user_id = label.user_id
  and observation.source_code in (
    'apple_calendar', 'google_calendar', 'healthkit'
  );
delete from semantic_private.observation_mentions as mention
using semantic_private.observations as observation
where observation.id = mention.observation_id
  and observation.user_id = mention.user_id
  and observation.source_code in (
    'apple_calendar', 'google_calendar', 'healthkit'
  );

create or replace function semantic_private.guard_private_source_generic_lane_v03()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if exists (
    select 1
    from semantic_private.observations as observation
    where observation.id = new.observation_id
      and observation.user_id = new.user_id
      and observation.source_code in (
        'apple_calendar', 'google_calendar', 'healthkit'
      )
  ) then
    raise exception 'private source observations cannot enter generic mention or feedback lanes';
  end if;
  return new;
end;
$$;

drop trigger if exists observation_mentions_guard_private_sources_v03
  on semantic_private.observation_mentions;
create trigger observation_mentions_guard_private_sources_v03
before insert or update on semantic_private.observation_mentions
for each row execute function semantic_private.guard_private_source_generic_lane_v03();

drop trigger if exists mapping_feedback_labels_guard_private_sources_v03
  on semantic_private.mapping_feedback_labels;
create trigger mapping_feedback_labels_guard_private_sources_v03
before insert or update on semantic_private.mapping_feedback_labels
for each row execute function semantic_private.guard_private_source_generic_lane_v03();

-- Raw HealthKit ingestion is active, but only the thresholded fitness_habit /
-- routine projection has nonzero semantic weight. Daily/hourly/workout/sleep
-- records themselves cannot be mapped by the generic mapper.
insert into semantic_private.sources (
  source_code, provider, evidence_channel, independence_group,
  online_resolution_policy, default_reliability, action_weights, active
) values (
  'healthkit', 'apple', 'fitness', 'fitness', 'disabled_private', 0.90,
  '{"activity_day":0.0,"activity_hour":0.0,"workout":0.0,"sleep":0.0,"routine":0.85}'::jsonb,
  true
)
on conflict (source_code) do update set
  provider = excluded.provider,
  evidence_channel = excluded.evidence_channel,
  independence_group = excluded.independence_group,
  online_resolution_policy = excluded.online_resolution_policy,
  default_reliability = excluded.default_reliability,
  action_weights = excluded.action_weights,
  active = true;

alter table ontology.model_versions
  drop constraint if exists model_versions_model_role_v02_check,
  drop constraint if exists model_versions_model_role_v03_check,
  add constraint model_versions_model_role_v03_check check (model_role in (
    'extractor', 'resolver', 'scorer', 'surfacing', 'term_miner',
    'calendar_classifier', 'youtube_resolver', 'memories_builder',
    'dyad_ranker', 'bio_renderer', 'icebreaker_renderer',
    'fitness_habit_builder'
  ));

insert into ontology.model_versions (
  id, model_key, version, model_role, code_hash, parameters, status
) values (
  ontology.stable_uuid('written:model:fitness-habit-builder:v1.0.0'),
  'healthkit_fitness_habit_builder', '1.0.0', 'fitness_habit_builder', null,
  '{"purpose":"fitness_connection","policy_version":"written-healthkit-fitness-v1.0.0","raw_term_mapping":false,"aggregate_only_abstains":true,"workout_window_days":42,"workout_min_sessions":4,"workout_min_weeks":3,"daypart_min_sessions":6,"daypart_min_weeks":3,"daypart_min_concentration":0.70,"sleep_semantic_promotion":false,"candidate_ttl_days":7}'::jsonb,
  'active'
)
on conflict (model_key, version) do update set
  parameters = excluded.parameters,
  status = excluded.status;

alter table semantic_private.worker_jobs
  drop constraint if exists worker_jobs_job_type_v02_check,
  drop constraint if exists worker_jobs_job_type_v03_check,
  add constraint worker_jobs_job_type_v03_check check (job_type in (
    'map_observation', 'recompute_user', 'mine_terms',
    'refresh_external_entity', 'classify_calendar',
    'resolve_youtube_channel', 'build_memories', 'compute_dyad',
    'render_bio', 'render_icebreaker', 'derive_fitness_habits'
  ));

-- One explicit purpose grant, with independent product-surface choices.
create table if not exists semantic_private.healthkit_use_grants (
  user_id uuid primary key references auth.users(id) on delete cascade,
  data_use_purpose text not null default 'fitness_connection',
  grant_state text not null default 'active',
  allow_fitness_matching boolean not null default false,
  allow_bio_naming boolean not null default false,
  allow_icebreaker_naming boolean not null default false,
  allow_controlled_explanation boolean not null default false,
  consent_version text not null,
  granted_at timestamptz not null default now(),
  revoked_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint healthkit_use_grants_purpose_check check (
    data_use_purpose = 'fitness_connection'
  ),
  constraint healthkit_use_grants_state_check check (
    grant_state in ('active', 'revoked')
  ),
  constraint healthkit_use_grants_revocation_check check (
    (grant_state = 'active' and revoked_at is null)
    or (grant_state = 'revoked' and revoked_at is not null)
  ),
  constraint healthkit_use_grants_lattice_check check (
    not allow_controlled_explanation
    or allow_bio_naming or allow_icebreaker_naming
  )
);

drop trigger if exists healthkit_use_grants_set_updated_at
  on semantic_private.healthkit_use_grants;
create trigger healthkit_use_grants_set_updated_at
before update on semantic_private.healthkit_use_grants
for each row execute function semantic_private.set_updated_at();

-- Keep the audited consent/revocation row for the life of the account. A
-- cascading auth-user deletion is allowed because the parent row is already
-- absent from the deleting transaction; direct service deletion is not.
create or replace function semantic_private.guard_healthkit_grant_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if exists (select 1 from auth.users where id = old.user_id) then
    raise exception 'HealthKit grants must be revoked, not deleted';
  end if;
  return old;
end;
$$;

drop trigger if exists healthkit_use_grants_guard_delete
  on semantic_private.healthkit_use_grants;
create trigger healthkit_use_grants_guard_delete
before delete on semantic_private.healthkit_use_grants
for each row execute function semantic_private.guard_healthkit_grant_delete();

create table if not exists semantic_private.fitness_feature_snapshots (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  input_revision bigint not null check (input_revision >= 0),
  builder_model_id uuid not null
    references ontology.model_versions(id) on delete restrict,
  policy_version text not null,
  window_end_at timestamptz not null,
  coverage_state text not null,
  accepted_record_count integer not null check (accepted_record_count >= 0),
  rejected_record_count integer not null check (rejected_record_count >= 0),
  activity_day_count integer not null check (activity_day_count >= 0),
  activity_hour_count integer not null check (activity_hour_count >= 0),
  workout_count integer not null check (workout_count >= 0),
  sleep_session_count integer not null check (sleep_session_count >= 0),
  feature_payload jsonb not null default '{}'::jsonb,
  state text not null default 'building',
  created_at timestamptz not null default now(),
  finalized_at timestamptz,
  unique (id, user_id),
  unique (user_id, input_revision, builder_model_id, policy_version),
  constraint fitness_feature_snapshots_coverage_check check (coverage_state in (
    'empty', 'aggregate_only', 'workout_typed', 'sleep_typed', 'mixed'
  )),
  constraint fitness_feature_snapshots_state_check check (
    state in ('building', 'ready', 'stale', 'failed')
  ),
  constraint fitness_feature_snapshots_finish_check check (
    (state = 'building' and finalized_at is null)
    or (state <> 'building' and finalized_at is not null)
  ),
  constraint fitness_feature_snapshots_safe_payload_check check (
    feature_payload = '{}'::jsonb
  )
);

create or replace function semantic_private.guard_fitness_snapshot_builder()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  current_revision bigint;
  registered_policy text;
begin
  if not exists (
    select 1 from semantic_private.healthkit_use_grants as grant_row
    where grant_row.user_id = new.user_id
      and grant_row.grant_state = 'active'
      and grant_row.data_use_purpose = 'fitness_connection'
  ) then
    raise exception 'fitness snapshot requires an active fitness-purpose grant';
  end if;
  select model.parameters ->> 'policy_version'
  into registered_policy
  from ontology.model_versions as model
  where model.id = new.builder_model_id
    and model.model_role = 'fitness_habit_builder'
    and model.status = 'active';
  if registered_policy is null then
    raise exception 'fitness snapshot requires an active fitness-habit builder';
  end if;
  if new.policy_version is distinct from registered_policy then
    raise exception 'fitness snapshot policy must match its registered builder';
  end if;
  select state.revision into current_revision
  from semantic_private.user_state_versions as state
  where state.user_id = new.user_id;
  if current_revision is null
     or new.input_revision is distinct from current_revision then
    raise exception 'fitness snapshot must bind the current user revision';
  end if;
  if new.window_end_at > now() then
    raise exception 'fitness snapshot window cannot end in the future';
  end if;
  return new;
end;
$$;

drop trigger if exists fitness_feature_snapshots_guard_builder
  on semantic_private.fitness_feature_snapshots;
create trigger fitness_feature_snapshots_guard_builder
before insert or update of user_id, input_revision, builder_model_id,
  policy_version, window_end_at, coverage_state,
  accepted_record_count, rejected_record_count,
  activity_day_count, activity_hour_count, workout_count,
  sleep_session_count, feature_payload
on semantic_private.fitness_feature_snapshots
for each row execute function semantic_private.guard_fitness_snapshot_builder();

-- Worker payloads are durable-ID control messages, not another private-data
-- store. Mirror the Python registry's eleven flat, closed schemas at the first
-- persistent boundary. This deliberately does not reuse jsonb_payload_is_safe:
-- observation_id is a licensed queue identifier even though it is forbidden in
-- presentation JSON, and every allowed worker value has a stronger scalar type.
create or replace function semantic_private.worker_json_has_exact_keys_v03(
  payload jsonb,
  required_fields text[],
  optional_fields text[] default array[]::text[]
)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  allowed_fields text[] := required_fields || optional_fields;
begin
  if payload is null
     or jsonb_typeof(payload) <> 'object'
     or octet_length(payload::text) > 4096
     or not (payload ?& required_fields) then
    return false;
  end if;
  return not exists (
    select 1
    from jsonb_object_keys(payload) as payload_key
    where payload_key <> all (allowed_fields)
  );
end;
$$;

create or replace function semantic_private.worker_json_field_is_valid_v03(
  payload jsonb,
  field_name text,
  field_kind text
)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  field_value jsonb := payload -> field_name;
  scalar_text text;
begin
  if field_value is null then return false; end if;
  scalar_text := field_value #>> '{}';

  if field_kind = 'uuid' then
    return jsonb_typeof(field_value) = 'string'
      and scalar_text ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  elsif field_kind = 'revision' then
    return jsonb_typeof(field_value) = 'number'
      and scalar_text ~ '^(0|[1-9][0-9]*)$'
      and (
        char_length(scalar_text) < 19
        or (
          char_length(scalar_text) = 19
          and scalar_text <= '9223372036854775807'
        )
      );
  elsif field_kind = 'count' then
    return jsonb_typeof(field_value) = 'number'
      and scalar_text ~ '^(0|[1-9][0-9]*)$'
      and (
        char_length(scalar_text) < 10
        or (
          char_length(scalar_text) = 10
          and scalar_text <= '2147483647'
        )
      );
  elsif field_kind = 'privacy_threshold' then
    return jsonb_typeof(field_value) = 'number'
      and scalar_text ~ '^[1-9][0-9]*$'
      and (
        char_length(scalar_text) < 10
        or (
          char_length(scalar_text) = 10
          and scalar_text <= '2147483647'
        )
      )
      and (
        char_length(scalar_text) > 1
        or scalar_text >= '5'
      );
  elsif field_kind = 'version' then
    return jsonb_typeof(field_value) = 'string'
      and scalar_text ~ '^[A-Za-z0-9][A-Za-z0-9._:+-]{0,79}$';
  elsif field_kind = 'youtube_channel_id' then
    return jsonb_typeof(field_value) = 'string'
      and scalar_text ~ '^UC[A-Za-z0-9_-]{22}$';
  elsif field_kind = 'dyad_purpose' then
    return jsonb_typeof(field_value) = 'string'
      and scalar_text in ('bio', 'icebreaker', 'both');
  elsif field_kind = 'data_use_purpose' then
    return jsonb_typeof(field_value) = 'string'
      and scalar_text in ('general_social', 'fitness_connection');
  elsif field_kind = 'fitness_policy' then
    return jsonb_typeof(field_value) = 'string'
      and scalar_text = 'written-healthkit-fitness-v1.0.0';
  end if;
  return false;
end;
$$;

create or replace function semantic_private.worker_job_payload_is_valid_v03(
  target_job_type text,
  queue_user_id uuid,
  payload jsonb
)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
begin
  case target_job_type
    when 'map_observation' then
      return semantic_private.worker_json_has_exact_keys_v03(payload, array[
          'observation_id', 'user_id', 'input_revision', 'semantic_run_id',
          'ontology_version_id', 'resolver_model_id'
        ])
        and semantic_private.worker_json_field_is_valid_v03(payload, 'observation_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'user_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'input_revision', 'revision')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'semantic_run_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'ontology_version_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'resolver_model_id', 'uuid')
        and queue_user_id is not null
        and payload ->> 'user_id' = queue_user_id::text;
    when 'classify_calendar' then
      return semantic_private.worker_json_has_exact_keys_v03(payload, array[
          'observation_id', 'user_id', 'input_revision',
          'ontology_version_id', 'classifier_model_id'
        ])
        and semantic_private.worker_json_field_is_valid_v03(payload, 'observation_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'user_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'input_revision', 'revision')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'ontology_version_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'classifier_model_id', 'uuid')
        and queue_user_id is not null
        and payload ->> 'user_id' = queue_user_id::text;
    when 'resolve_youtube_channel' then
      return semantic_private.worker_json_has_exact_keys_v03(payload, array[
          'youtube_channel_row_id', 'youtube_channel_id',
          'ontology_version_id', 'resolver_model_id', 'resolution_version'
        ])
        and semantic_private.worker_json_field_is_valid_v03(payload, 'youtube_channel_row_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'youtube_channel_id', 'youtube_channel_id')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'ontology_version_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'resolver_model_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'resolution_version', 'version')
        and queue_user_id is null;
    when 'recompute_user' then
      return semantic_private.worker_json_has_exact_keys_v03(payload, array[
          'user_id', 'input_revision', 'ontology_version_id',
          'resolver_model_id', 'scorer_model_id'
        ], array['embedding_model_id'])
        and semantic_private.worker_json_field_is_valid_v03(payload, 'user_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'input_revision', 'revision')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'ontology_version_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'resolver_model_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'scorer_model_id', 'uuid')
        and (
          not (payload ? 'embedding_model_id')
          or semantic_private.worker_json_field_is_valid_v03(payload, 'embedding_model_id', 'uuid')
        )
        and queue_user_id is not null
        and payload ->> 'user_id' = queue_user_id::text;
    when 'build_memories' then
      return semantic_private.worker_json_has_exact_keys_v03(payload, array[
          'user_id', 'input_revision', 'ontology_version_id',
          'builder_model_id', 'presentation_version'
        ])
        and semantic_private.worker_json_field_is_valid_v03(payload, 'user_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'input_revision', 'revision')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'ontology_version_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'builder_model_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'presentation_version', 'version')
        and queue_user_id is not null
        and payload ->> 'user_id' = queue_user_id::text;
    when 'compute_dyad' then
      return semantic_private.worker_json_has_exact_keys_v03(payload, array[
          'viewer_user_id', 'subject_user_id', 'viewer_revision',
          'subject_revision', 'ontology_version_id', 'ranker_model_id',
          'run_purpose'
        ], array['data_use_purpose'])
        and semantic_private.worker_json_field_is_valid_v03(payload, 'viewer_user_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'subject_user_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'viewer_revision', 'revision')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'subject_revision', 'revision')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'ontology_version_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'ranker_model_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'run_purpose', 'dyad_purpose')
        and (
          not (payload ? 'data_use_purpose')
          or semantic_private.worker_json_field_is_valid_v03(payload, 'data_use_purpose', 'data_use_purpose')
        )
        and payload ->> 'viewer_user_id' <> payload ->> 'subject_user_id'
        and queue_user_id is not null
        and payload ->> 'viewer_user_id' = queue_user_id::text;
    when 'render_bio' then
      return semantic_private.worker_json_has_exact_keys_v03(payload, array[
          'dyad_run_id', 'viewer_user_id', 'subject_user_id',
          'viewer_revision', 'subject_revision', 'renderer_model_id',
          'presentation_version'
        ])
        and semantic_private.worker_json_field_is_valid_v03(payload, 'dyad_run_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'viewer_user_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'subject_user_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'viewer_revision', 'revision')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'subject_revision', 'revision')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'renderer_model_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'presentation_version', 'version')
        and payload ->> 'viewer_user_id' <> payload ->> 'subject_user_id'
        and queue_user_id is not null
        and payload ->> 'viewer_user_id' = queue_user_id::text;
    when 'render_icebreaker' then
      return semantic_private.worker_json_has_exact_keys_v03(payload, array[
          'match_authorization_id', 'dyad_run_id', 'viewer_user_id',
          'subject_user_id', 'viewer_revision', 'subject_revision',
          'renderer_model_id', 'template_version'
        ])
        and semantic_private.worker_json_field_is_valid_v03(payload, 'match_authorization_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'dyad_run_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'viewer_user_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'subject_user_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'viewer_revision', 'revision')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'subject_revision', 'revision')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'renderer_model_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'template_version', 'version')
        and payload ->> 'viewer_user_id' <> payload ->> 'subject_user_id'
        and queue_user_id is not null
        and payload ->> 'viewer_user_id' = queue_user_id::text;
    when 'mine_terms' then
      return semantic_private.worker_json_has_exact_keys_v03(payload, array[
          'aggregate_snapshot_id', 'base_ontology_version_id',
          'miner_model_id', 'minimum_distinct_users', 'mining_policy_version'
        ])
        and semantic_private.worker_json_field_is_valid_v03(payload, 'aggregate_snapshot_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'base_ontology_version_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'miner_model_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'minimum_distinct_users', 'privacy_threshold')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'mining_policy_version', 'version')
        and queue_user_id is null;
    when 'refresh_external_entity' then
      return semantic_private.worker_json_has_exact_keys_v03(payload, array[
          'external_entity_id', 'refresher_version'
        ])
        and semantic_private.worker_json_field_is_valid_v03(payload, 'external_entity_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'refresher_version', 'version')
        and queue_user_id is null;
    when 'derive_fitness_habits' then
      return semantic_private.worker_json_has_exact_keys_v03(payload, array[
          'user_id', 'input_revision', 'fitness_snapshot_id',
          'builder_model_id', 'policy_version'
        ])
        and semantic_private.worker_json_field_is_valid_v03(payload, 'user_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'input_revision', 'revision')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'fitness_snapshot_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'builder_model_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'policy_version', 'fitness_policy')
        and queue_user_id is not null
        and payload ->> 'user_id' = queue_user_id::text;
    else
      return false;
  end case;
end;
$$;

-- Queue results are only acknowledgements and durable output references. Rich
-- derivation data belongs in its typed destination table, never in this outbox.
create or replace function semantic_private.worker_job_result_is_safe_v03(
  result_payload jsonb
)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  item record;
  item_count integer := 0;
  allowed_id_keys constant text[] := array[
    'mapped', 'output_id', 'observation_mapping_id',
    'calendar_classification_id', 'youtube_channel_resolution_id',
    'semantic_run_id', 'memories_snapshot_id', 'dyad_run_id',
    'bio_variant_id', 'icebreaker_frame_id', 'external_entity_id',
    'fitness_snapshot_id'
  ];
  allowed_count_keys constant text[] := array[
    'mapping_count', 'classification_count', 'candidate_count',
    'assertion_count', 'item_count', 'term_candidate_count',
    'created_count', 'updated_count', 'skipped_count', 'quarantined_count'
  ];
begin
  if result_payload is null
     or jsonb_typeof(result_payload) <> 'object'
     or octet_length(result_payload::text) > 2048 then
    return false;
  end if;
  for item in select key, value from jsonb_each(result_payload) loop
    item_count := item_count + 1;
    if item_count > 16 then return false; end if;
    if item.key = any (allowed_id_keys) then
      if not semantic_private.worker_json_field_is_valid_v03(
        result_payload, item.key, 'uuid'
      ) then return false; end if;
    elsif item.key = any (allowed_count_keys) then
      if not semantic_private.worker_json_field_is_valid_v03(
        result_payload, item.key, 'count'
      ) then return false; end if;
    elsif item.key in ('abstained', 'changed') then
      if jsonb_typeof(item.value) <> 'boolean' then return false; end if;
    elsif item.key in ('status', 'outcome') then
      if jsonb_typeof(item.value) <> 'string'
         or item.value #>> '{}' not in (
           'succeeded', 'created', 'updated', 'unchanged', 'abstained',
           'quarantined', 'superseded', 'not_found', 'no_op'
         ) then return false; end if;
    else
      return false;
    end if;
  end loop;
  return true;
end;
$$;

create or replace function semantic_private.worker_job_row_is_safe_v03(
  target_job_type text,
  queue_user_id uuid,
  payload jsonb,
  idempotency_key text,
  locked_by text,
  last_error text,
  result_payload jsonb
)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select semantic_private.worker_job_payload_is_valid_v03(
           target_job_type, queue_user_id, payload
         )
    and idempotency_key is not null
    and char_length(idempotency_key) between 1 and 240
    and idempotency_key ~ '^[A-Za-z0-9][A-Za-z0-9._:+-]{0,239}$'
    and (
      locked_by is null
      or (
        char_length(locked_by) between 1 and 240
        and locked_by ~ '^[A-Za-z0-9][A-Za-z0-9._:+-]{0,239}$'
      )
    )
    and (
      last_error is null
      or last_error = 'lease_expired_after_max_attempts'
      or last_error = 'handler_error'
      or last_error = 'no_handler:' || target_job_type
      or last_error ~ '^invalid_payload:(unknown_job_type|payload_not_object|invalid_payload_key|forbidden_private_field|unknown_payload_field|missing_payload_field|invalid_uuid|invalid_revision|invalid_version|unsupported_fitness_policy_version|invalid_youtube_channel_id|invalid_run_purpose|invalid_data_use_purpose|invalid_privacy_threshold|same_user_dyad|queue_user_mismatch)$'
    )
    and semantic_private.worker_job_result_is_safe_v03(result_payload)
$$;

-- The only upgrade treatment for a legacy row that violates the new boundary
-- is a content-free dead tombstone. Do not preserve the old payload, result,
-- diagnostic, lock owner, or possibly user-authored idempotency token.
create or replace function semantic_private.sanitize_invalid_worker_jobs_v03()
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  sanitized_count bigint;
begin
  update semantic_private.worker_jobs as job
  set status = 'dead',
      payload = '{}'::jsonb,
      result = '{}'::jsonb,
      idempotency_key = 'legacy-invalid:' || job.id::text,
      locked_at = null,
      locked_by = null,
      last_error = 'invalid_payload:sql_contract'
  where not semantic_private.worker_job_row_is_safe_v03(
          job.job_type, job.user_id, job.payload, job.idempotency_key,
          job.locked_by, job.last_error, job.result
        )
    and not (
      job.status = 'dead'
      and job.payload = '{}'::jsonb
      and job.result = '{}'::jsonb
      and job.idempotency_key = 'legacy-invalid:' || job.id::text
      and job.locked_at is null
      and job.locked_by is null
      and job.last_error = 'invalid_payload:sql_contract'
    );
  get diagnostics sanitized_count = row_count;
  return sanitized_count;
end;
$$;

create or replace function semantic_private.guard_worker_job_contract_v03()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Permit only the sanitizer's destructive transition for a pre-existing bad
  -- row. A client cannot insert a schema-free tombstone or alter a valid row
  -- into one.
  if tg_op = 'UPDATE'
     and not semantic_private.worker_job_row_is_safe_v03(
       old.job_type, old.user_id, old.payload, old.idempotency_key,
       old.locked_by, old.last_error, old.result
     )
     and new.status = 'dead'
     and new.payload = '{}'::jsonb
     and new.result = '{}'::jsonb
     and new.idempotency_key = 'legacy-invalid:' || new.id::text
     and new.locked_at is null
     and new.locked_by is null
     and new.last_error = 'invalid_payload:sql_contract' then
    return new;
  end if;

  if not semantic_private.worker_job_row_is_safe_v03(
    new.job_type, new.user_id, new.payload, new.idempotency_key,
    new.locked_by, new.last_error, new.result
  ) then
    raise exception 'worker job violates its closed control-message contract';
  end if;
  return new;
end;
$$;

-- A replay may still have the previous trigger definitions installed. Remove
-- them before the one-time upgrade scrub, then recreate both below.
drop trigger if exists worker_jobs_guard_contract_v03 on semantic_private.worker_jobs;
drop trigger if exists worker_jobs_guard_derive_fitness_payload on semantic_private.worker_jobs;
select semantic_private.sanitize_invalid_worker_jobs_v03();

create trigger worker_jobs_guard_contract_v03
before insert or update of
  job_type, user_id, payload, idempotency_key, locked_at, locked_by,
  last_error, result
on semantic_private.worker_jobs
for each row execute function semantic_private.guard_worker_job_contract_v03();

create or replace function semantic_private.guard_derive_fitness_job_payload()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  payload_user_id uuid;
  payload_revision bigint;
  payload_snapshot_id uuid;
  payload_builder_id uuid;
  payload_policy_version text;
begin
  if new.job_type <> 'derive_fitness_habits' then return new; end if;
  if not semantic_private.jsonb_payload_is_safe(new.payload, 4096, array[
       'user_id', 'input_revision', 'fitness_snapshot_id',
       'builder_model_id', 'policy_version'
     ]::text[])
     or not (new.payload ?& array[
       'user_id', 'input_revision', 'fitness_snapshot_id',
       'builder_model_id', 'policy_version'
     ]::text[]) then
    raise exception 'derive-fitness job payload must match its closed ID-only contract';
  end if;
  begin
    payload_user_id := (new.payload ->> 'user_id')::uuid;
    payload_revision := (new.payload ->> 'input_revision')::bigint;
    payload_snapshot_id := (new.payload ->> 'fitness_snapshot_id')::uuid;
    payload_builder_id := (new.payload ->> 'builder_model_id')::uuid;
    payload_policy_version := new.payload ->> 'policy_version';
  exception when others then
    raise exception 'derive-fitness job payload has malformed identifiers';
  end;
  if new.user_id is null or payload_user_id is distinct from new.user_id
     or payload_revision < 0
     or not exists (
       select 1
       from semantic_private.fitness_feature_snapshots as snapshot
       where snapshot.id = payload_snapshot_id
         and snapshot.user_id = payload_user_id
         and snapshot.input_revision = payload_revision
         and snapshot.builder_model_id = payload_builder_id
         and snapshot.policy_version = payload_policy_version
         and snapshot.state = 'ready'
         and snapshot.window_end_at >= now() - interval '1 day'
         and exists (
           select 1 from semantic_private.user_state_versions as current_state
           where current_state.user_id = payload_user_id
             and current_state.revision = payload_revision
         )
     ) then
    raise exception 'derive-fitness job does not match a ready feature snapshot';
  end if;
  return new;
end;
$$;

drop trigger if exists worker_jobs_guard_derive_fitness_payload
  on semantic_private.worker_jobs;
create trigger worker_jobs_guard_derive_fitness_payload
before insert or update of job_type, user_id, payload
on semantic_private.worker_jobs
for each row execute function semantic_private.guard_derive_fitness_job_payload();

create table if not exists semantic_private.fitness_habit_candidates (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null,
  feature_snapshot_id uuid not null,
  ontology_version_id uuid not null,
  concept_id uuid not null,
  candidate_kind text not null,
  predicate_key text not null default 'routine'
    references ontology.relation_types(predicate_key) on delete restrict,
  controlled_label text not null,
  support_record_count integer not null,
  distinct_day_count integer not null,
  distinct_week_count integer not null,
  last_supported_at timestamptz not null,
  mapping_agreement double precision not null,
  evidence_quality double precision not null,
  data_use_purpose text not null default 'fitness_connection',
  policy_version text not null,
  window_end_at timestamptz not null,
  derivation_as_of timestamptz not null default now(),
  expires_at timestamptz not null,
  review_state text not null default 'candidate',
  created_at timestamptz not null default now(),
  unique (id, user_id),
  unique (
    user_id, feature_snapshot_id, concept_id, candidate_kind, policy_version
  ),
  foreign key (feature_snapshot_id, user_id)
    references semantic_private.fitness_feature_snapshots(id, user_id) on delete cascade,
  foreign key (ontology_version_id, concept_id)
    references ontology.concept_revisions(ontology_version_id, concept_id)
    on delete restrict,
  constraint fitness_habit_candidates_kind_check check (candidate_kind in (
    'activity_routine', 'workout_daypart', 'sleep_schedule'
  )),
  constraint fitness_habit_candidates_predicate_check check (
    predicate_key = 'routine'
  ),
  constraint fitness_habit_candidates_label_check check (
    char_length(controlled_label) between 1 and 160
  ),
  constraint fitness_habit_candidates_support_check check (
    support_record_count >= 4
    and distinct_day_count >= 3
    and distinct_week_count >= 1
    and (candidate_kind = 'sleep_schedule' or distinct_week_count >= 3)
    and (
      candidate_kind <> 'workout_daypart' or support_record_count >= 6
    )
    and (
      candidate_kind <> 'sleep_schedule'
      or (support_record_count >= 14 and distinct_day_count >= 14)
    )
  ),
  constraint fitness_habit_candidates_quality_check check (
    mapping_agreement between 0 and 1 and evidence_quality between 0 and 1
  ),
  constraint fitness_habit_candidates_purpose_check check (
    data_use_purpose = 'fitness_connection'
  ),
  constraint fitness_habit_candidates_freshness_check check (
    window_end_at <= derivation_as_of
    and derivation_as_of <= window_end_at + interval '1 day'
    and expires_at > derivation_as_of
    and expires_at <= derivation_as_of + interval '7 days'
  ),
  constraint fitness_habit_candidates_review_check check (
    review_state in ('candidate', 'user_confirmed', 'suppressed', 'retired')
  )
);

-- Sleep sessions remain available as typed private coverage, but v0.3 does
-- not promote them to an ontology label. Existing experimental candidates are
-- retired on replay rather than silently remaining selectable.
update semantic_private.fitness_habit_candidates
set review_state = 'retired'
where candidate_kind = 'sleep_schedule'
  and review_state <> 'retired';
alter table semantic_private.fitness_habit_candidates
  drop constraint if exists fitness_habit_candidates_sleep_disabled_v03_check,
  add constraint fitness_habit_candidates_sleep_disabled_v03_check check (
    candidate_kind <> 'sleep_schedule' or review_state = 'retired'
  );

create or replace function semantic_private.guard_fitness_habit_candidate()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  snapshot semantic_private.fitness_feature_snapshots%rowtype;
  concept_key text;
  canonical_label text;
  current_revision bigint;
  activity_keys constant text[] := array[
    'activity:running', 'activity:walking', 'activity:cycling',
    'activity:swimming', 'activity:hiking', 'activity:strength_training',
    'activity:yoga', 'activity:pilates', 'activity:dance', 'activity:hiit',
    'activity:rowing', 'activity:elliptical', 'activity:climbing',
    'activity:tennis', 'activity:pickleball', 'activity:basketball',
    'activity:soccer', 'activity:skiing', 'activity:snowboarding'
  ]::text[];
  routine_keys constant text[] := array[
    'routine:morning_workouts', 'routine:afternoon_workouts',
    'routine:evening_workouts', 'routine:overnight_workouts',
    'routine:consistent_sleep_schedule'
  ]::text[];
begin
  if tg_op = 'UPDATE'
     and new.review_state in ('suppressed', 'retired')
     and (to_jsonb(new) - 'review_state') = (to_jsonb(old) - 'review_state') then
    return new;
  end if;
  if new.candidate_kind = 'sleep_schedule' then
    raise exception 'sleep sessions are typed-private coverage only in v0.3';
  end if;
  if not exists (
    select 1 from semantic_private.healthkit_use_grants as grant_row
    where grant_row.user_id = new.user_id
      and grant_row.grant_state = 'active'
      and grant_row.data_use_purpose = 'fitness_connection'
  ) then
    raise exception 'fitness candidate requires an active fitness-purpose grant';
  end if;
  select * into snapshot
  from semantic_private.fitness_feature_snapshots as feature
  where feature.id = new.feature_snapshot_id
    and feature.user_id = new.user_id;
  if not found or snapshot.state <> 'ready' then
    raise exception 'fitness candidate requires a ready feature snapshot';
  end if;

  select concept.concept_key, revision.preferred_label
  into concept_key, canonical_label
  from ontology.concepts as concept
  join ontology.concept_revisions as revision
    on revision.concept_id = concept.id
   and revision.ontology_version_id = new.ontology_version_id
  where concept.id = new.concept_id
    and revision.status = 'active'
    and revision.inference_policy = 'review_required';
  if concept_key is null then
    raise exception 'fitness candidate requires an active reviewable concept';
  end if;
  if new.controlled_label is distinct from canonical_label then
    raise exception 'fitness candidate label must equal its canonical ontology label';
  end if;
  select state.revision into current_revision
  from semantic_private.user_state_versions as state
  where state.user_id = new.user_id;
  if current_revision is null
     or snapshot.input_revision is distinct from current_revision then
    raise exception 'fitness candidate snapshot is not at the current revision';
  end if;
  if not exists (
    select 1 from ontology.model_versions as builder
    where builder.id = snapshot.builder_model_id
      and builder.model_role = 'fitness_habit_builder'
      and builder.status = 'active'
      and builder.parameters ->> 'policy_version' = snapshot.policy_version
  ) then
    raise exception 'fitness candidate snapshot builder is no longer active';
  end if;
  if new.policy_version is distinct from snapshot.policy_version
     or new.window_end_at is distinct from snapshot.window_end_at then
    raise exception 'fitness candidate policy/window must match its snapshot';
  end if;
  if new.derivation_as_of < snapshot.window_end_at
     or new.derivation_as_of > snapshot.window_end_at + interval '1 day'
     or new.expires_at <= clock_timestamp() then
    raise exception 'fitness candidate is stale at derivation time';
  end if;

  if new.candidate_kind in ('activity_routine', 'workout_daypart') then
    if snapshot.coverage_state not in ('workout_typed', 'mixed')
       or snapshot.workout_count < (case
         when new.candidate_kind = 'workout_daypart' then 6 else 4 end) then
      raise exception 'workout coverage does not support fitness candidate';
    end if;
  elsif new.candidate_kind = 'sleep_schedule' then
    if snapshot.coverage_state not in ('sleep_typed', 'mixed')
       or snapshot.sleep_session_count < 14 then
      raise exception 'sleep coverage does not support fitness candidate';
    end if;
  end if;

  if new.candidate_kind = 'activity_routine'
     and not (concept_key = any(activity_keys)) then
    raise exception 'activity routine concept is not allowlisted';
  end if;
  if new.candidate_kind in ('workout_daypart', 'sleep_schedule')
     and not (concept_key = any(routine_keys)) then
    raise exception 'routine concept is not allowlisted';
  end if;
  if new.candidate_kind = 'sleep_schedule'
     and concept_key <> 'routine:consistent_sleep_schedule' then
    raise exception 'sleep candidate concept is not licensed';
  end if;
  if new.candidate_kind = 'workout_daypart'
     and concept_key = 'routine:consistent_sleep_schedule' then
    raise exception 'workout daypart concept is not licensed';
  end if;
  return new;
end;
$$;

drop trigger if exists fitness_habit_candidates_guard_semantics
  on semantic_private.fitness_habit_candidates;
create trigger fitness_habit_candidates_guard_semantics
before insert or update of user_id, feature_snapshot_id, ontology_version_id,
  concept_id, candidate_kind, predicate_key, controlled_label,
  support_record_count, distinct_day_count, distinct_week_count,
  last_supported_at, mapping_agreement, evidence_quality,
  data_use_purpose, policy_version, window_end_at,
  derivation_as_of, expires_at, review_state
on semantic_private.fitness_habit_candidates
for each row execute function semantic_private.guard_fitness_habit_candidate();

create table if not exists semantic_private.fitness_candidate_support (
  candidate_id uuid not null,
  user_id uuid not null,
  raw_source_record_id uuid not null,
  support_role text not null,
  attested_builder_model_id uuid not null,
  attested_input_revision bigint not null check (attested_input_revision >= 0),
  attested_policy_version text not null,
  activity_concept_id uuid,
  coarse_daypart text,
  sleep_start_minute smallint,
  utc_offset_minutes smallint not null,
  supports_candidate boolean not null default true,
  support_day date not null,
  support_week_start date not null,
  created_at timestamptz not null default now(),
  primary key (candidate_id, raw_source_record_id),
  foreign key (candidate_id, user_id)
    references semantic_private.fitness_habit_candidates(id, user_id) on delete cascade,
  foreign key (raw_source_record_id, user_id)
    references semantic_private.raw_source_records(id, user_id) on delete restrict,
  constraint fitness_candidate_support_role_check check (
    support_role in ('workout_session', 'sleep_session')
  ),
  constraint fitness_candidate_support_attestation_check check (
    utc_offset_minutes between -720 and 840
    and mod(utc_offset_minutes, 15) = 0
    and (
      (
        support_role = 'workout_session'
        and activity_concept_id is not null
        and coarse_daypart in ('morning', 'afternoon', 'evening', 'overnight')
        and sleep_start_minute is null
      )
      or (
        support_role = 'sleep_session'
        and activity_concept_id is null
        and coarse_daypart is null
        and sleep_start_minute between 0 and 1439
        and supports_candidate
      )
    )
  ),
  constraint fitness_candidate_support_week_check check (
    extract(isodow from support_week_start) = 1
    and support_day between support_week_start and support_week_start + 6
  )
);

create unique index if not exists fitness_candidate_support_sleep_night_uidx
  on semantic_private.fitness_candidate_support (candidate_id, support_day)
  where support_role = 'sleep_session';

create or replace function semantic_private.fitness_candidate_support_is_valid(
  target_candidate_id uuid
)
returns boolean
language plpgsql
volatile
set search_path = ''
as $$
declare
  candidate semantic_private.fitness_habit_candidates%rowtype;
  snapshot semantic_private.fitness_feature_snapshots%rowtype;
  current_revision bigint;
  concept_key text;
  expected_role text;
  expected_daypart text;
  eligible_count integer;
  linked_count integer;
  linked_days integer;
  linked_weeks integer;
  linked_last timestamptz;
  has_invalid_link boolean;
  has_duplicate_session_lineage boolean;
  sleep_center double precision;
  sleep_mad double precision;
begin
  select * into candidate
  from semantic_private.fitness_habit_candidates as item
  where item.id = target_candidate_id;
  if not found then return true; end if;
  if candidate.review_state in ('suppressed', 'retired') then return true; end if;

  select * into snapshot
  from semantic_private.fitness_feature_snapshots as feature
  where feature.id = candidate.feature_snapshot_id
    and feature.user_id = candidate.user_id;
  select state.revision into current_revision
  from semantic_private.user_state_versions as state
  where state.user_id = candidate.user_id;
  if not found
     or snapshot.state <> 'ready'
     or snapshot.input_revision is distinct from current_revision
     or snapshot.policy_version is distinct from candidate.policy_version
     or snapshot.window_end_at is distinct from candidate.window_end_at
     or not exists (
       select 1 from ontology.model_versions as builder
       where builder.id = snapshot.builder_model_id
         and builder.model_role = 'fitness_habit_builder'
         and builder.status = 'active'
         and builder.parameters ->> 'policy_version' = snapshot.policy_version
     )
     or candidate.expires_at <= clock_timestamp() then
    return false;
  end if;

  select concept.concept_key into concept_key
  from ontology.concepts as concept
  where concept.id = candidate.concept_id;

  expected_role := case
    when candidate.candidate_kind = 'sleep_schedule' then 'sleep_session'
    else 'workout_session'
  end;
  expected_daypart := case concept_key
    when 'routine:morning_workouts' then 'morning'
    when 'routine:afternoon_workouts' then 'afternoon'
    when 'routine:evening_workouts' then 'evening'
    when 'routine:overnight_workouts' then 'overnight'
    else null
  end;
  select count(distinct raw.source_item_hmac),
         count(distinct raw.source_item_hmac)
           filter (where support.supports_candidate),
         count(distinct support.support_day)
           filter (where support.supports_candidate),
         count(distinct support.support_week_start)
           filter (where support.supports_candidate),
         max(raw.occurred_at) filter (where support.supports_candidate)
  into eligible_count, linked_count, linked_days, linked_weeks, linked_last
  from semantic_private.fitness_candidate_support as support
  join semantic_private.raw_source_records as raw
    on raw.id = support.raw_source_record_id
   and raw.user_id = support.user_id
  where support.candidate_id = candidate.id
    and support.user_id = candidate.user_id
    and support.support_role = expected_role
    and raw.source_code = 'healthkit'
    and raw.lifecycle_state = 'active'
    and (
      (expected_role = 'workout_session' and raw.data_type = 'workout')
      or (expected_role = 'sleep_session' and raw.data_type in ('sleep', 'sleep_session'))
    );
  select exists (
    select 1
    from semantic_private.fitness_candidate_support as support
    join semantic_private.raw_source_records as raw
      on raw.id = support.raw_source_record_id
     and raw.user_id = support.user_id
    join semantic_private.raw_source_records as sibling
      on sibling.user_id = raw.user_id
     and sibling.source_code = raw.source_code
     and sibling.source_item_hmac = raw.source_item_hmac
     and sibling.id <> raw.id
     and sibling.lifecycle_state = 'active'
    where support.candidate_id = candidate.id
      and support.user_id = candidate.user_id
      and support.support_role = expected_role
      and raw.lifecycle_state = 'active'
  ) into has_duplicate_session_lineage;
  select exists (
    select 1
    from semantic_private.fitness_candidate_support as support
    join semantic_private.raw_source_records as raw
      on raw.id = support.raw_source_record_id
     and raw.user_id = support.user_id
    where support.candidate_id = candidate.id
      and support.user_id = candidate.user_id
      and (
        raw.source_code <> 'healthkit'
        or raw.consent_purpose <> 'fitness_connection'
        or raw.lifecycle_state <> 'active'
        or raw.occurred_at is null
        or support.attested_builder_model_id is distinct from snapshot.builder_model_id
        or support.attested_input_revision is distinct from snapshot.input_revision
        or support.attested_policy_version is distinct from snapshot.policy_version
        -- The source offset is a minimized typed attestation. It pins the
        -- local calendar fields that timestamptz alone cannot retain.
        or support.support_day
          <> (
            (raw.occurred_at at time zone 'UTC')
            + support.utc_offset_minutes * interval '1 minute'
          )::date
        or support.support_week_start
          <> date_trunc(
               'week',
               (raw.occurred_at at time zone 'UTC')
               + support.utc_offset_minutes * interval '1 minute'
             )::date
        or (
          support.support_role = 'workout_session'
          and (
            raw.data_type <> 'workout'
            or raw.occurred_at < candidate.window_end_at - interval '42 days'
            or raw.occurred_at > candidate.window_end_at
            or support.coarse_daypart is distinct from case
              when extract(hour from (
                (raw.occurred_at at time zone 'UTC')
                + support.utc_offset_minutes * interval '1 minute'
              )) between 5 and 11 then 'morning'
              when extract(hour from (
                (raw.occurred_at at time zone 'UTC')
                + support.utc_offset_minutes * interval '1 minute'
              )) between 12 and 17 then 'afternoon'
              when extract(hour from (
                (raw.occurred_at at time zone 'UTC')
                + support.utc_offset_minutes * interval '1 minute'
              )) between 18 and 23 then 'evening'
              else 'overnight'
            end
            or not exists (
              select 1
              from ontology.concepts as activity
              join ontology.concept_revisions as activity_revision
                on activity_revision.concept_id = activity.id
               and activity_revision.ontology_version_id = candidate.ontology_version_id
              where activity.id = support.activity_concept_id
                and activity.concept_key = any(array[
                  'activity:running', 'activity:walking', 'activity:cycling',
                  'activity:swimming', 'activity:hiking',
                  'activity:strength_training', 'activity:yoga',
                  'activity:pilates', 'activity:dance', 'activity:hiit',
                  'activity:rowing', 'activity:elliptical',
                  'activity:climbing', 'activity:tennis',
                  'activity:pickleball', 'activity:basketball',
                  'activity:soccer', 'activity:skiing',
                  'activity:snowboarding'
                ]::text[])
                and activity_revision.status = 'active'
                and activity_revision.inference_policy = 'review_required'
            )
          )
        )
        or (
          support.support_role = 'sleep_session'
          and (
            raw.data_type not in ('sleep', 'sleep_session')
            or raw.occurred_at < candidate.window_end_at - interval '28 days'
            or raw.occurred_at > candidate.window_end_at
            or support.sleep_start_minute is distinct from (
              extract(hour from (
                (raw.occurred_at at time zone 'UTC')
                + support.utc_offset_minutes * interval '1 minute'
              ))::integer * 60
              + floor(extract(minute from (
                (raw.occurred_at at time zone 'UTC')
                + support.utc_offset_minutes * interval '1 minute'
              )))::integer
            )
          )
        )
        or (
          candidate.candidate_kind = 'activity_routine'
          and (
            not support.supports_candidate
            or support.activity_concept_id is distinct from candidate.concept_id
          )
        )
        or (
          candidate.candidate_kind = 'workout_daypart'
          and (
            expected_daypart is null
            or support.supports_candidate
              is distinct from (support.coarse_daypart = expected_daypart)
          )
        )
        or (
          candidate.candidate_kind = 'sleep_schedule'
          and not support.supports_candidate
        )
      )
  ) into has_invalid_link;
  if has_invalid_link or has_duplicate_session_lineage
     or linked_count <> candidate.support_record_count
     or linked_days <> candidate.distinct_day_count
     or linked_weeks <> candidate.distinct_week_count
     or linked_last is distinct from candidate.last_supported_at then
    return false;
  end if;
  if candidate.candidate_kind = 'activity_routine' then
    return eligible_count = linked_count
      and linked_count >= 4 and linked_weeks >= 3;
  end if;
  if candidate.candidate_kind = 'workout_daypart' then
    return eligible_count = snapshot.workout_count
      and eligible_count = (
        select count(distinct eligible_raw.source_item_hmac)
        from semantic_private.raw_source_records as eligible_raw
        where eligible_raw.user_id = candidate.user_id
          and eligible_raw.source_code = 'healthkit'
          and eligible_raw.data_type = 'workout'
          and eligible_raw.consent_purpose = 'fitness_connection'
          and eligible_raw.lifecycle_state = 'active'
          and eligible_raw.occurred_at
            between candidate.window_end_at - interval '42 days'
                and candidate.window_end_at
      )
      and linked_count >= 6 and linked_weeks >= 3
      and linked_count::bigint * 100 >= eligible_count::bigint * 70;
  end if;
  if candidate.candidate_kind = 'sleep_schedule' then
    if linked_count < 14 or linked_days < 14 then return false; end if;
    select percentile_cont(0.5) within group (
             order by case
               when support.sleep_start_minute < 360
                 then support.sleep_start_minute + 1440
               else support.sleep_start_minute
             end
           )
    into sleep_center
    from semantic_private.fitness_candidate_support as support
    where support.candidate_id = candidate.id
      and support.user_id = candidate.user_id
      and support.support_role = 'sleep_session'
      and support.supports_candidate;
    select percentile_cont(0.5) within group (
             order by least(
               abs(
                 support.sleep_start_minute
                 - mod(sleep_center::numeric, 1440)::double precision
               ),
               1440 - abs(
                 support.sleep_start_minute
                 - mod(sleep_center::numeric, 1440)::double precision
               )
             )
           )
    into sleep_mad
    from semantic_private.fitness_candidate_support as support
    where support.candidate_id = candidate.id
      and support.user_id = candidate.user_id
      and support.support_role = 'sleep_session'
      and support.supports_candidate;
    return sleep_mad is not null and sleep_mad <= 90;
  end if;
  return false;
end;
$$;

create or replace function semantic_private.fitness_candidate_is_current(
  target_candidate_id uuid,
  target_user_id uuid
)
returns boolean
language sql
volatile
set search_path = ''
as $$
  select exists (
    select 1
    from semantic_private.fitness_habit_candidates as candidate
    join semantic_private.fitness_feature_snapshots as snapshot
      on snapshot.id = candidate.feature_snapshot_id
     and snapshot.user_id = candidate.user_id
    join semantic_private.user_state_versions as current_state
      on current_state.user_id = candidate.user_id
     and current_state.revision = snapshot.input_revision
    join semantic_private.healthkit_use_grants as grant_row
      on grant_row.user_id = candidate.user_id
     and grant_row.grant_state = 'active'
     and grant_row.data_use_purpose = 'fitness_connection'
    join ontology.model_versions as builder
      on builder.id = snapshot.builder_model_id
     and builder.model_role = 'fitness_habit_builder'
     and builder.status = 'active'
     and builder.parameters ->> 'policy_version' = snapshot.policy_version
    where candidate.id = target_candidate_id
      and candidate.user_id = target_user_id
      and candidate.review_state in ('candidate', 'user_confirmed')
      and candidate.data_use_purpose = 'fitness_connection'
      and candidate.policy_version = snapshot.policy_version
      and candidate.window_end_at = snapshot.window_end_at
      and candidate.expires_at > clock_timestamp()
      and snapshot.state = 'ready'
      and semantic_private.fitness_candidate_support_is_valid(candidate.id)
  );
$$;

create or replace function semantic_private.validate_fitness_candidate_support()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  target_candidate_id uuid;
  previous_candidate_id uuid;
begin
  if tg_table_name = 'fitness_habit_candidates' then
    target_candidate_id := case when tg_op = 'DELETE' then old.id else new.id end;
    previous_candidate_id := case when tg_op = 'UPDATE' then old.id else null end;
  else
    target_candidate_id := case
      when tg_op = 'DELETE' then old.candidate_id else new.candidate_id end;
    previous_candidate_id := case
      when tg_op = 'UPDATE' then old.candidate_id else null end;
  end if;
  if not semantic_private.fitness_candidate_support_is_valid(target_candidate_id) then
    raise exception 'fitness candidate support recurrence or provenance is invalid';
  end if;
  if previous_candidate_id is distinct from target_candidate_id
     and not semantic_private.fitness_candidate_support_is_valid(previous_candidate_id) then
    raise exception 'previous fitness candidate support became invalid';
  end if;
  return null;
end;
$$;

drop trigger if exists fitness_habit_candidates_validate_support
  on semantic_private.fitness_habit_candidates;
create constraint trigger fitness_habit_candidates_validate_support
after insert or update
on semantic_private.fitness_habit_candidates
deferrable initially deferred
for each row execute function semantic_private.validate_fitness_candidate_support();

drop trigger if exists fitness_candidate_support_validate_candidate
  on semantic_private.fitness_candidate_support;
create constraint trigger fitness_candidate_support_validate_candidate
after insert or update or delete on semantic_private.fitness_candidate_support
deferrable initially deferred
for each row execute function semantic_private.validate_fitness_candidate_support();

-- The generic mapping table can see only a sanitized observation that is
-- explicitly linked to a validated fitness candidate. Raw HealthKit samples
-- have no row here and are therefore structurally unmappable.
create table if not exists semantic_private.fitness_candidate_observations (
  observation_id uuid not null,
  user_id uuid not null,
  fitness_candidate_id uuid not null,
  data_use_purpose text not null default 'fitness_connection',
  created_at timestamptz not null default now(),
  primary key (observation_id, fitness_candidate_id),
  foreign key (observation_id, user_id)
    references semantic_private.observations(id, user_id) on delete cascade,
  foreign key (fitness_candidate_id, user_id)
    references semantic_private.fitness_habit_candidates(id, user_id) on delete restrict,
  constraint fitness_candidate_observations_purpose_check check (
    data_use_purpose = 'fitness_connection'
  )
);

create or replace function semantic_private.guard_fitness_candidate_observation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (
    select 1
    from semantic_private.observations as observation
    join semantic_private.fitness_habit_candidates as candidate
      on candidate.id = new.fitness_candidate_id
     and candidate.user_id = new.user_id
    join semantic_private.fitness_feature_snapshots as snapshot
      on snapshot.id = candidate.feature_snapshot_id
     and snapshot.user_id = candidate.user_id
    where observation.id = new.observation_id
      and observation.user_id = new.user_id
      and observation.source_code = 'healthkit'
      and observation.data_type = 'fitness_habit'
      and observation.action_type = 'routine'
      and observation.privacy_class = 'private_fitness_sanitized'
      and observation.allow_external_resolution = false
      and observation.action_weight = 0.85
      and observation.lifecycle_state = 'active'
      and observation.normalized_payload ->> 'candidate_id' = candidate.id::text
      and observation.normalized_payload ->> 'controlled_label' = candidate.controlled_label
      and observation.normalized_payload ->> 'purpose_scope' = 'fitness_connection'
      and observation.normalized_payload ->> 'policy_version' = candidate.policy_version
      and observation.normalized_payload ->> 'schema_version' = candidate.policy_version
      and observation.normalized_payload ->> 'record_kind' = 'fitness_habit'
      and observation.normalized_payload ->> 'classification_state' = 'candidate'
      and observation.normalized_payload ->> 'coverage_state' = snapshot.coverage_state
      and (
        select count(*) from jsonb_object_keys(observation.normalized_payload)
      ) = 8
      and candidate.data_use_purpose = 'fitness_connection'
      and semantic_private.fitness_candidate_is_current(candidate.id, candidate.user_id)
  ) then
    raise exception 'fitness observation must be a sanitized candidate projection';
  end if;
  return new;
end;
$$;

drop trigger if exists fitness_candidate_observations_guard_projection
  on semantic_private.fitness_candidate_observations;
create trigger fitness_candidate_observations_guard_projection
before insert or update on semantic_private.fitness_candidate_observations
for each row execute function semantic_private.guard_fitness_candidate_observation();

-- The ordinary observation table contains only closed, sanitized projections
-- for these private sources. Broad source records belong in raw_source_records.
-- A v0.2 Calendar observation could contain plaintext in any token/payload
-- column, so migration deliberately minimizes it before validating the exact
-- constraint. Invalid legacy opaque identities are replaced with one-way,
-- observation-scoped digests; they are historical coordination identities,
-- not newly blessed provider HMACs. Ambiguous classifications fail closed to
-- review. DDL temporarily removes the append-only trigger only inside this
-- migration transaction and leaves no reusable runtime bypass.
drop trigger if exists observations_guard_private_projection_v03
  on semantic_private.observations;
drop trigger if exists observations_guard_immutable
  on semantic_private.observations;

with calendar_projection as (
  select
    observation.id,
    case
      when observation.normalized_payload ->> 'classification_state' = 'candidate'
       and observation.payload_schema_version = 'calendar-v03'
       and observation.normalized_payload ->> 'schema_version' = 'calendar-v03'
       and observation.data_type = 'calendar_event'
       and observation.observation_kind = 'sanitized_classification'
       and observation.source_item_hmac ~ '^[0-9a-f]{64}$'
       and observation.record_fingerprint ~ '^[0-9a-f]{64}$'
       and observation.content_lineage_hmac ~ '^[0-9a-f]{64}$'
       and observation.session_hmac is null
       and observation.raw_blob_ref is null
       and observation.privacy_class = 'private_calendar_sanitized'
       and not observation.allow_external_resolution
       and observation.action_weight = 0.0
       and observation.normalized_payload ->> 'artifact_type' in (
         'travel_itinerary', 'commercial_reservation', 'public_ticket'
       )
       and observation.normalized_payload = jsonb_build_object(
         'schema_version', 'calendar-v03',
         'record_kind', 'calendar_classification',
         'classification_state', 'candidate',
         'artifact_type', observation.normalized_payload ->> 'artifact_type'
       )
       and observation.content_lineage_hmac is not null then 'candidate'
      when observation.normalized_payload ->> 'classification_state' = 'excluded'
        then 'excluded'
      else 'review'
    end as controlled_state,
    case
      when observation.normalized_payload ->> 'classification_state' = 'candidate'
       and observation.payload_schema_version = 'calendar-v03'
       and observation.normalized_payload ->> 'schema_version' = 'calendar-v03'
       and observation.data_type = 'calendar_event'
       and observation.observation_kind = 'sanitized_classification'
       and observation.source_item_hmac ~ '^[0-9a-f]{64}$'
       and observation.record_fingerprint ~ '^[0-9a-f]{64}$'
       and observation.content_lineage_hmac ~ '^[0-9a-f]{64}$'
       and observation.session_hmac is null
       and observation.raw_blob_ref is null
       and observation.privacy_class = 'private_calendar_sanitized'
       and not observation.allow_external_resolution
       and observation.action_weight = 0.0
       and observation.normalized_payload ->> 'artifact_type' in (
         'travel_itinerary', 'commercial_reservation', 'public_ticket'
       )
       and observation.normalized_payload = jsonb_build_object(
         'schema_version', 'calendar-v03',
         'record_kind', 'calendar_classification',
         'classification_state', 'candidate',
         'artifact_type', observation.normalized_payload ->> 'artifact_type'
       )
       and observation.content_lineage_hmac is not null
        then observation.normalized_payload ->> 'artifact_type'
      else null
    end as controlled_artifact
  from semantic_private.observations as observation
  where observation.source_code in ('apple_calendar', 'google_calendar')
)
update semantic_private.observations as observation
set data_type = 'calendar_event',
    observation_kind = 'sanitized_classification',
    action_type = case
      when observation.action_type in ('scheduled', 'booked')
        then observation.action_type
      else 'scheduled'
    end,
    source_item_hmac = case
      when observation.source_item_hmac ~ '^[0-9a-f]{64}$'
        then observation.source_item_hmac
      else repeat(md5(
        'written:v03:legacy-calendar-item:' || observation.id::text
      ), 2)
    end,
    record_fingerprint = case
      when observation.record_fingerprint ~ '^[0-9a-f]{64}$'
        then observation.record_fingerprint
      else repeat(md5(
        'written:v03:legacy-calendar-record:' || observation.id::text
      ), 2)
    end,
    content_lineage_hmac = case
      when observation.content_lineage_hmac is null then null
      when observation.content_lineage_hmac ~ '^[0-9a-f]{64}$'
        then observation.content_lineage_hmac
      else repeat(md5(
        'written:v03:legacy-calendar-lineage:' || observation.id::text
      ), 2)
    end,
    session_hmac = null,
    payload_schema_version = 'calendar-v03',
    normalized_payload = case
      when projection.controlled_state = 'candidate' then jsonb_build_object(
        'schema_version', 'calendar-v03',
        'record_kind', 'calendar_classification',
        'classification_state', 'candidate',
        'artifact_type', projection.controlled_artifact
      )
      else jsonb_build_object(
        'schema_version', 'calendar-v03',
        'record_kind', 'calendar_classification',
        'classification_state', projection.controlled_state
      )
    end,
    raw_blob_ref = null,
    action_weight = 0.0,
    privacy_class = 'private_calendar_sanitized',
    allow_external_resolution = false,
    exclusion_code = case
      when observation.lifecycle_state = 'active' then null
      else 'legacy_sanitized'
    end,
    excluded_at = case
      when observation.lifecycle_state = 'active' then null
      else coalesce(observation.excluded_at, now())
    end
from calendar_projection as projection
where observation.id = projection.id;

create trigger observations_guard_immutable
before update on semantic_private.observations
for each row execute function semantic_private.guard_observation_immutable();

create or replace function semantic_private.private_observation_projection_is_valid_v03(
  checked_source_code text,
  checked_data_type text,
  checked_observation_kind text,
  checked_action_type text,
  checked_occurred_at timestamptz,
  checked_source_item_hmac text,
  checked_record_fingerprint text,
  checked_content_lineage_hmac text,
  checked_session_hmac text,
  checked_payload_schema_version text,
  checked_normalized_payload jsonb,
  checked_raw_blob_ref text,
  checked_field_quality double precision,
  checked_action_weight double precision,
  checked_privacy_class text,
  checked_allow_external_resolution boolean,
  checked_lifecycle_state text,
  checked_exclusion_code text,
  checked_excluded_at timestamptz
)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  classification_state text;
  artifact_type text;
  candidate_id text;
  controlled_label text;
  coverage_state text;
begin
  if checked_source_code not in (
    'apple_calendar', 'google_calendar', 'healthkit'
  ) then
    return true;
  end if;
  if checked_source_item_hmac is null
     or checked_source_item_hmac !~ '^[0-9a-f]{64}$'
     or checked_record_fingerprint is null
     or checked_record_fingerprint !~ '^[0-9a-f]{64}$'
     or (
       checked_content_lineage_hmac is not null
       and checked_content_lineage_hmac !~ '^[0-9a-f]{64}$'
     )
     or checked_session_hmac is not null
     or checked_raw_blob_ref is not null
     or checked_field_quality is null
     or checked_field_quality < 0.0
     or checked_field_quality > 1.0
     or checked_allow_external_resolution is distinct from false
     or checked_normalized_payload is null
     or jsonb_typeof(checked_normalized_payload) <> 'object'
     or octet_length(checked_normalized_payload::text) > 1024 then
    return false;
  end if;
  if not (
    (
      checked_lifecycle_state = 'active'
      and checked_exclusion_code is null
      and checked_excluded_at is null
    ) or (
      checked_lifecycle_state in ('excluded', 'deleted')
      and checked_exclusion_code in (
        'policy_excluded', 'user_deleted', 'retention_expired',
        'superseded', 'legacy_sanitized'
      )
      and checked_excluded_at is not null
    )
  ) then
    return false;
  end if;

  if checked_source_code in ('apple_calendar', 'google_calendar') then
    classification_state := checked_normalized_payload ->> 'classification_state';
    artifact_type := checked_normalized_payload ->> 'artifact_type';
    if checked_data_type <> 'calendar_event'
       or checked_observation_kind <> 'sanitized_classification'
       or checked_action_type not in ('scheduled', 'booked')
       or checked_payload_schema_version <> 'calendar-v03'
       or checked_privacy_class <> 'private_calendar_sanitized'
       or checked_action_weight <> 0.0
       or checked_normalized_payload ->> 'schema_version' <> 'calendar-v03'
       or checked_normalized_payload ->> 'record_kind'
         <> 'calendar_classification'
       or classification_state not in ('candidate', 'excluded', 'review') then
      return false;
    end if;
    if classification_state = 'candidate' then
      return coalesce(
        checked_occurred_at is not null
        and checked_content_lineage_hmac is not null
        and artifact_type in (
          'travel_itinerary', 'commercial_reservation', 'public_ticket'
        )
        and checked_normalized_payload = jsonb_build_object(
          'schema_version', 'calendar-v03',
          'record_kind', 'calendar_classification',
          'classification_state', 'candidate',
          'artifact_type', artifact_type
        ), false
      );
    end if;
    return coalesce(
      checked_normalized_payload = jsonb_build_object(
        'schema_version', 'calendar-v03',
        'record_kind', 'calendar_classification',
        'classification_state', classification_state
      ), false
    );
  end if;

  candidate_id := checked_normalized_payload ->> 'candidate_id';
  controlled_label := checked_normalized_payload ->> 'controlled_label';
  coverage_state := checked_normalized_payload ->> 'coverage_state';
  return coalesce(checked_data_type = 'fitness_habit'
    and checked_observation_kind = 'routine_projection'
    and checked_action_type = 'routine'
    and checked_occurred_at is not null
    and checked_content_lineage_hmac is null
    and checked_payload_schema_version
      = 'written-healthkit-fitness-v1.0.0'
    and checked_privacy_class = 'private_fitness_sanitized'
    and checked_action_weight = 0.85
    and jsonb_typeof(checked_normalized_payload -> 'candidate_id') = 'string'
    and candidate_id ~
      '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and jsonb_typeof(checked_normalized_payload -> 'controlled_label') = 'string'
    and char_length(controlled_label) between 1 and 120
    and controlled_label !~ '[[:cntrl:]]'
    and coverage_state in ('workout_typed', 'mixed')
    and checked_normalized_payload = jsonb_build_object(
      'schema_version', 'written-healthkit-fitness-v1.0.0',
      'record_kind', 'fitness_habit',
      'classification_state', 'candidate',
      'candidate_id', candidate_id,
      'controlled_label', controlled_label,
      'coverage_state', coverage_state,
      'purpose_scope', 'fitness_connection',
      'policy_version', 'written-healthkit-fitness-v1.0.0'
    ), false);
end;
$$;

alter table semantic_private.observations
  drop constraint if exists observations_no_raw_private_payload_v03_check,
  drop constraint if exists observations_private_identity_v03_check,
  add constraint observations_private_identity_v03_check check (
    source_code not in ('apple_calendar', 'google_calendar', 'healthkit')
    or (
      source_item_hmac ~ '^[0-9a-f]{64}$'
      and record_fingerprint ~ '^[0-9a-f]{64}$'
      and (
        content_lineage_hmac is null
        or content_lineage_hmac ~ '^[0-9a-f]{64}$'
      )
      and session_hmac is null
      and raw_blob_ref is null
    )
  ),
  add constraint observations_no_raw_private_payload_v03_check check (
    semantic_private.private_observation_projection_is_valid_v03(
      source_code, data_type, observation_kind, action_type, occurred_at,
      source_item_hmac, record_fingerprint, content_lineage_hmac,
      session_hmac, payload_schema_version, normalized_payload, raw_blob_ref,
      field_quality, action_weight, privacy_class,
      allow_external_resolution, lifecycle_state, exclusion_code, excluded_at
    )
  );

create or replace function semantic_private.guard_private_observation_projection_v03()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not semantic_private.private_observation_projection_is_valid_v03(
       new.source_code, new.data_type, new.observation_kind, new.action_type,
       new.occurred_at, new.source_item_hmac, new.record_fingerprint,
       new.content_lineage_hmac, new.session_hmac,
       new.payload_schema_version, new.normalized_payload, new.raw_blob_ref,
       new.field_quality, new.action_weight, new.privacy_class,
       new.allow_external_resolution, new.lifecycle_state,
       new.exclusion_code, new.excluded_at
     ) then
    raise exception 'private observations require an exact closed projection';
  end if;
  if new.source_code = 'healthkit'
     and tg_op = 'INSERT'
     and (
       new.lifecycle_state <> 'active'
       or not exists (
         select 1
         from semantic_private.fitness_habit_candidates as candidate
         join semantic_private.fitness_feature_snapshots as snapshot
           on snapshot.id = candidate.feature_snapshot_id
          and snapshot.user_id = candidate.user_id
         where candidate.id = (new.normalized_payload ->> 'candidate_id')::uuid
           and candidate.user_id = new.user_id
           and candidate.controlled_label =
             new.normalized_payload ->> 'controlled_label'
           and candidate.policy_version =
             new.normalized_payload ->> 'policy_version'
           and snapshot.coverage_state =
             new.normalized_payload ->> 'coverage_state'
           and semantic_private.fitness_candidate_is_current(
             candidate.id, candidate.user_id
           )
       )
     ) then
    raise exception 'HealthKit observations require a current exact candidate projection';
  end if;
  return new;
end;
$$;

create trigger observations_guard_private_projection_v03
before insert or update on semantic_private.observations
for each row execute function semantic_private.guard_private_observation_projection_v03();

create or replace function semantic_private.guard_healthkit_observation_mapping()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  observation_source text;
begin
  select observation.source_code into observation_source
  from semantic_private.observations as observation
  where observation.id = new.observation_id
    and observation.user_id = new.user_id;
  if observation_source <> 'healthkit' then return new; end if;
  if new.mapping_state <> 'accepted'
     or new.mapping_method <> 'provider_metadata'
     or new.candidate_rank <> 1
     or new.evidence_weight <> 1.0
     or new.cross_source_fusion_allowed
     or new.youtube_semantic_kind is not null then
    raise exception 'HealthKit mappings require the closed candidate projection';
  end if;
  if not exists (
    select 1
    from semantic_private.fitness_candidate_observations as link
    join semantic_private.fitness_habit_candidates as candidate
      on candidate.id = link.fitness_candidate_id
     and candidate.user_id = link.user_id
    join semantic_private.semantic_runs as run
      on run.id = new.semantic_run_id
     and run.user_id = new.user_id
     and run.ontology_version_id = new.ontology_version_id
    join semantic_private.user_state_versions as current_state
      on current_state.user_id = run.user_id
     and current_state.revision = run.input_revision
    where link.observation_id = new.observation_id
      and link.user_id = new.user_id
      and link.data_use_purpose = 'fitness_connection'
      and candidate.ontology_version_id = new.ontology_version_id
      and candidate.concept_id = new.concept_id
      and new.confidence = candidate.mapping_agreement
      and run.status = 'running'
      and semantic_private.fitness_candidate_is_current(candidate.id, candidate.user_id)
      and new.feature_snapshot = jsonb_build_object(
        'candidate_id', candidate.id::text,
        'policy_version', candidate.policy_version,
        'purpose_scope', 'fitness_connection'
      )
      and new.evidence_path = jsonb_build_object(
        'step', 'validated_fitness_candidate',
        'candidate_id', candidate.id::text,
        'policy_version', candidate.policy_version,
        'purpose_scope', 'fitness_connection'
      )
  ) then
    raise exception 'HealthKit mapping must exactly match a current validated candidate';
  end if;
  return new;
end;
$$;

drop trigger if exists observation_mappings_guard_healthkit_candidate
  on semantic_private.observation_mappings;
create trigger observation_mappings_guard_healthkit_candidate
before insert or update
on semantic_private.observation_mappings
for each row execute function semantic_private.guard_healthkit_observation_mapping();

create table if not exists semantic_private.healthkit_derived_assertions (
  assertion_id uuid not null,
  user_id uuid not null,
  fitness_candidate_id uuid not null,
  data_use_purpose text not null default 'fitness_connection',
  created_at timestamptz not null default now(),
  primary key (assertion_id, fitness_candidate_id),
  foreign key (assertion_id, user_id)
    references semantic_private.user_assertions(id, user_id) on delete cascade,
  foreign key (fitness_candidate_id, user_id)
    references semantic_private.fitness_habit_candidates(id, user_id) on delete restrict,
  constraint healthkit_derived_assertions_purpose_check check (
    data_use_purpose = 'fitness_connection'
  )
);

create or replace function semantic_private.guard_healthkit_derived_assertion()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (
    select 1
    from semantic_private.user_assertions as assertion
    join semantic_private.fitness_habit_candidates as candidate
      on candidate.id = new.fitness_candidate_id
     and candidate.user_id = new.user_id
    where assertion.id = new.assertion_id
      and assertion.user_id = new.user_id
      and assertion.concept_id = candidate.concept_id
      and assertion.predicate_key = candidate.predicate_key
      and assertion.created_ontology_version_id = candidate.ontology_version_id
      and assertion.assertion_origin = 'inferred'
      and assertion.machine_state in ('candidate', 'eligible')
      and candidate.data_use_purpose = 'fitness_connection'
      and new.data_use_purpose = 'fitness_connection'
      and semantic_private.fitness_candidate_is_current(candidate.id, candidate.user_id)
      and exists (
        select 1
        from semantic_private.fitness_candidate_observations as projection
        join semantic_private.observation_mappings as mapping
          on mapping.observation_id = projection.observation_id
         and mapping.user_id = projection.user_id
         and mapping.semantic_run_id = assertion.source_semantic_run_id
         and mapping.ontology_version_id = candidate.ontology_version_id
         and mapping.concept_id = candidate.concept_id
         and mapping.mapping_state = 'accepted'
        where projection.fitness_candidate_id = candidate.id
          and projection.user_id = candidate.user_id
      )
  ) then
    raise exception 'HealthKit assertion must exactly match its fitness candidate';
  end if;
  if exists (
    select 1
    from semantic_private.validated_surface_facts as fact
    where fact.assertion_id = new.assertion_id
      and fact.user_id = new.user_id
      and fact.evidence_class <> 'healthkit_derived'
  ) then
    raise exception 'link HealthKit provenance before creating surface facts';
  end if;
  if exists (
    select 1
    from semantic_private.dyad_alignment_pairs as pair
    join semantic_private.dyad_runs as run on run.id = pair.dyad_run_id
    where (
      (pair.viewer_assertion_id = new.assertion_id
        and pair.viewer_user_id = new.user_id)
      or (pair.subject_assertion_id = new.assertion_id
        and pair.subject_user_id = new.user_id)
    )
      and run.data_use_purpose <> 'fitness_connection'
  ) then
    raise exception 'HealthKit provenance cannot be attached after general-social use';
  end if;
  return new;
end;
$$;

drop trigger if exists healthkit_derived_assertions_guard_alignment
  on semantic_private.healthkit_derived_assertions;
create trigger healthkit_derived_assertions_guard_alignment
before insert or update on semantic_private.healthkit_derived_assertions
for each row execute function semantic_private.guard_healthkit_derived_assertion();

-- Evidence cannot cross semantic runs or ontology versions. HealthKit adds an
-- exact immutable provenance/candidate binding and a closed JSON path.
-- v0.2 used one trigger body for motif support and assertion evidence but
-- referenced NEW.semantic_run_id even on assertion_evidence, which has no
-- such column. Branch before touching table-specific row fields.
create or replace function semantic_private.inherit_mapping_recency()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  mapping_row semantic_private.observation_mappings%rowtype;
begin
  if tg_table_name = 'motif_support' then
    select mapping.* into mapping_row
    from semantic_private.observation_mappings as mapping
    where mapping.id = new.observation_mapping_id
      and mapping.user_id = new.user_id
      and mapping.semantic_run_id = new.semantic_run_id;
  elsif tg_table_name = 'assertion_evidence' then
    select mapping.* into mapping_row
    from semantic_private.observation_mappings as mapping
    where mapping.id = new.observation_mapping_id
      and mapping.user_id = new.user_id;
  else
    raise exception 'mapping-recency trigger attached to an unsupported table';
  end if;
  if not found then
    raise exception using
      errcode = '23503',
      message = 'linked recency row must reference an existing mapping';
  end if;
  new.recency_weight := mapping_row.recency_weight;
  new.recency_quality := mapping_row.recency_quality;
  new.recency_policy_version := mapping_row.recency_policy_version;
  new.recency_rule_id := mapping_row.recency_rule_id;
  new.recency_status := mapping_row.recency_status;
  new.recency_timestamp_quality := mapping_row.recency_timestamp_quality;
  new.recency_as_of := mapping_row.recency_as_of;
  return new;
end;
$$;

create or replace function semantic_private.guard_assertion_evidence_alignment_v03()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  mapped_source text;
  expected_group text;
  target_assertion_id uuid;
  candidate semantic_private.fitness_habit_candidates%rowtype;
begin
  select observation.source_code, source.independence_group, score.assertion_id
  into mapped_source, expected_group, target_assertion_id
  from semantic_private.assertion_score_versions as score
  join semantic_private.observation_mappings as mapping
    on mapping.id = new.observation_mapping_id
   and mapping.user_id = new.user_id
   and mapping.semantic_run_id = score.semantic_run_id
   and mapping.ontology_version_id = score.ontology_version_id
   and mapping.mapping_state = 'accepted'
  join semantic_private.observations as observation
    on observation.id = mapping.observation_id
   and observation.user_id = mapping.user_id
  join semantic_private.sources as source on source.source_code = observation.source_code
  where score.id = new.assertion_score_version_id
    and score.user_id = new.user_id;
  if not found then
    raise exception 'assertion evidence must use an accepted mapping from the score run/version';
  end if;
  if new.independence_group is distinct from expected_group then
    raise exception 'assertion evidence independence group must match its source';
  end if;
  if mapped_source <> 'healthkit' then return new; end if;

  select fitness.* into candidate
  from semantic_private.assertion_score_versions as score
  join semantic_private.observation_mappings as mapping
    on mapping.id = new.observation_mapping_id
   and mapping.user_id = new.user_id
  join semantic_private.fitness_candidate_observations as projection
    on projection.observation_id = mapping.observation_id
   and projection.user_id = mapping.user_id
  join semantic_private.fitness_habit_candidates as fitness
    on fitness.id = projection.fitness_candidate_id
   and fitness.user_id = projection.user_id
   and fitness.ontology_version_id = mapping.ontology_version_id
   and fitness.concept_id = mapping.concept_id
  join semantic_private.healthkit_derived_assertions as provenance
    on provenance.assertion_id = score.assertion_id
   and provenance.user_id = score.user_id
   and provenance.fitness_candidate_id = fitness.id
   and provenance.data_use_purpose = 'fitness_connection'
  where score.id = new.assertion_score_version_id
    and score.user_id = new.user_id
    and semantic_private.fitness_candidate_is_current(fitness.id, fitness.user_id);
  if not found then
    raise exception 'HealthKit assertion evidence requires current exact candidate provenance';
  end if;
  if new.evidence_path <> jsonb_build_object(
       'step', 'validated_fitness_candidate',
       'candidate_id', candidate.id::text,
       'policy_version', candidate.policy_version,
       'purpose_scope', 'fitness_connection'
     ) then
    raise exception 'HealthKit assertion evidence path is not the closed projection';
  end if;
  return new;
end;
$$;

-- Assertion evidence is a derived cache, so migration may safely discard
-- legacy rows that could not pass the v0.3 run/version/source boundary. Raw
-- observations and their owner-scoped vault records are left untouched.
delete from semantic_private.assertion_evidence as evidence
using semantic_private.assertion_score_versions as score,
      semantic_private.observation_mappings as mapping,
      semantic_private.observations as observation,
      semantic_private.sources as source
where score.id = evidence.assertion_score_version_id
  and score.user_id = evidence.user_id
  and mapping.id = evidence.observation_mapping_id
  and mapping.user_id = evidence.user_id
  and observation.id = mapping.observation_id
  and observation.user_id = mapping.user_id
  and source.source_code = observation.source_code
  and (
    mapping.semantic_run_id is distinct from score.semantic_run_id
    or mapping.ontology_version_id is distinct from score.ontology_version_id
    or mapping.mapping_state <> 'accepted'
    or evidence.independence_group is distinct from source.independence_group
    or (
      observation.source_code = 'healthkit'
      and not exists (
        select 1
        from semantic_private.fitness_candidate_observations as projection
        join semantic_private.fitness_habit_candidates as candidate
          on candidate.id = projection.fitness_candidate_id
         and candidate.user_id = projection.user_id
        join semantic_private.healthkit_derived_assertions as provenance
          on provenance.fitness_candidate_id = candidate.id
         and provenance.user_id = candidate.user_id
         and provenance.assertion_id = score.assertion_id
         and provenance.data_use_purpose = 'fitness_connection'
        where projection.observation_id = mapping.observation_id
          and projection.user_id = mapping.user_id
          and candidate.ontology_version_id = mapping.ontology_version_id
          and candidate.concept_id = mapping.concept_id
          and semantic_private.fitness_candidate_is_current(
            candidate.id, candidate.user_id
          )
          and evidence.evidence_path = jsonb_build_object(
            'step', 'validated_fitness_candidate',
            'candidate_id', candidate.id::text,
            'policy_version', candidate.policy_version,
            'purpose_scope', 'fitness_connection'
          )
      )
    )
  );

drop trigger if exists assertion_evidence_guard_run_alignment_v03
  on semantic_private.assertion_evidence;
create trigger assertion_evidence_guard_run_alignment_v03
before insert or update on semantic_private.assertion_evidence
for each row execute function semantic_private.guard_assertion_evidence_alignment_v03();

create or replace function semantic_private.healthkit_grant_allows(
  target_user_id uuid,
  target_surface text,
  requested_use text
)
returns boolean
language sql
volatile
set search_path = ''
as $$
  select coalesce((
    select case
      when target_surface = 'memories' then true
      when target_surface = 'matching' and requested_use = 'select'
        then grant_row.allow_fitness_matching
      when target_surface = 'bio' and requested_use in ('select', 'name')
        then grant_row.allow_bio_naming
      when target_surface = 'icebreaker' and requested_use in ('select', 'name')
        then grant_row.allow_icebreaker_naming
      when target_surface = 'bio' and requested_use = 'explain'
        then grant_row.allow_controlled_explanation
          and grant_row.allow_bio_naming
      when target_surface = 'icebreaker' and requested_use = 'explain'
        then grant_row.allow_controlled_explanation
          and grant_row.allow_icebreaker_naming
      else false
    end
    from semantic_private.healthkit_use_grants as grant_row
    where grant_row.user_id = target_user_id
      and grant_row.grant_state = 'active'
      and grant_row.data_use_purpose = 'fitness_connection'
  ), false);
$$;

create or replace function semantic_private.guard_raw_healthkit_grant()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.source_code = 'healthkit'
     and new.lifecycle_state = 'active'
     and not semantic_private.healthkit_grant_allows(
       new.user_id, 'memories', 'select'
     ) then
    raise exception 'active HealthKit retention requires an active fitness grant';
  end if;
  return new;
end;
$$;

drop trigger if exists raw_source_records_guard_healthkit_grant
  on semantic_private.raw_source_records;
create trigger raw_source_records_guard_healthkit_grant
before insert or update of user_id, source_code, lifecycle_state
on semantic_private.raw_source_records
for each row execute function semantic_private.guard_raw_healthkit_grant();

create or replace function semantic_private.assertion_has_healthkit_evidence(
  target_assertion_id uuid,
  target_user_id uuid
)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1
    from semantic_private.healthkit_derived_assertions as link
    join semantic_private.fitness_habit_candidates as candidate
      on candidate.id = link.fitness_candidate_id
     and candidate.user_id = link.user_id
    where link.assertion_id = target_assertion_id
      and link.user_id = target_user_id
      and candidate.data_use_purpose = 'fitness_connection'
  );
$$;

create or replace function semantic_private.healthkit_assertion_is_current(
  target_assertion_id uuid,
  target_user_id uuid
)
returns boolean
language sql
volatile
set search_path = ''
as $$
  select exists (
    select 1
    from semantic_private.healthkit_derived_assertions as link
    where link.assertion_id = target_assertion_id
      and link.user_id = target_user_id
      and semantic_private.fitness_candidate_is_current(
        link.fitness_candidate_id, link.user_id
      )
  );
$$;

-- Exact user revisions are necessary but not sufficient for a fitness dyad:
-- candidate eligibility also expires with time. Replacing the v0.2 helper
-- makes every existing bio/icebreaker readiness check, and the first-exposure
-- RPC below, re-evaluate HealthKit provenance at statement time.
create or replace function semantic_private.dyad_run_is_current(target_run_id uuid)
returns boolean
language sql
volatile
set search_path = ''
as $$
  select coalesce((
    select run.viewer_revision = coalesce(viewer_state.revision, 0)
       and run.subject_revision = coalesce(subject_state.revision, 0)
       and run.status in ('running', 'succeeded')
       and not exists (
         select 1
         from semantic_private.dyad_alignment_pairs as pair
         where pair.dyad_run_id = run.id
           and (
             (
               semantic_private.assertion_has_healthkit_evidence(
                 pair.viewer_assertion_id, pair.viewer_user_id
               )
               and not semantic_private.healthkit_assertion_is_current(
                 pair.viewer_assertion_id, pair.viewer_user_id
               )
             )
             or (
               semantic_private.assertion_has_healthkit_evidence(
                 pair.subject_assertion_id, pair.subject_user_id
               )
               and not semantic_private.healthkit_assertion_is_current(
                 pair.subject_assertion_id, pair.subject_user_id
               )
             )
           )
       )
    from semantic_private.dyad_runs as run
    left join semantic_private.user_state_versions as viewer_state
      on viewer_state.user_id = run.viewer_user_id
    left join semantic_private.user_state_versions as subject_state
      on subject_state.user_id = run.subject_user_id
    where run.id = target_run_id
  ), false);
$$;

create or replace function semantic_private.guard_healthkit_surface_permission()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not semantic_private.assertion_has_healthkit_evidence(new.assertion_id, new.user_id) then
    return new;
  end if;
  if (new.can_select or new.can_name or new.can_explain)
     and not semantic_private.healthkit_assertion_is_current(
       new.assertion_id, new.user_id
     ) then
    raise exception 'stale HealthKit assertion cannot receive surface permission';
  end if;
  if new.can_select and not semantic_private.healthkit_grant_allows(
       new.user_id, new.surface, 'select'
     ) then
    raise exception 'HealthKit assertion exceeds its fitness-purpose grant';
  end if;
  if new.can_name and not semantic_private.healthkit_grant_allows(
       new.user_id, new.surface, 'name'
     ) then
    raise exception 'HealthKit assertion naming is not granted';
  end if;
  if new.can_explain and not semantic_private.healthkit_grant_allows(
       new.user_id, new.surface, 'explain'
     ) then
    raise exception 'HealthKit assertion explanation is not granted';
  end if;
  return new;
end;
$$;

drop trigger if exists assertion_surface_permissions_guard_healthkit
  on semantic_private.assertion_surface_permissions;
create trigger assertion_surface_permissions_guard_healthkit
before insert or update of can_select, can_name, can_explain, surface
on semantic_private.assertion_surface_permissions
for each row execute function semantic_private.guard_healthkit_surface_permission();

-- Purpose is independent of render purpose. A bio run can be general-social
-- or fitness-connection; its data inputs must match this field.
alter table semantic_private.dyad_runs
  add column if not exists data_use_purpose text not null default 'general_social';
alter table semantic_private.dyad_runs
  drop constraint if exists dyad_runs_data_use_purpose_v03_check,
  add constraint dyad_runs_data_use_purpose_v03_check check (
    data_use_purpose in ('general_social', 'fitness_connection')
  );

create or replace function semantic_private.guard_dyad_data_use_purpose()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.data_use_purpose = 'fitness_connection' and (
    not semantic_private.healthkit_grant_allows(new.viewer_user_id, 'matching', 'select')
    or not semantic_private.healthkit_grant_allows(new.subject_user_id, 'matching', 'select')
  ) then
    raise exception 'fitness dyad requires active bilateral fitness grants';
  end if;
  if new.data_use_purpose = 'general_social' and exists (
    select 1
    from semantic_private.dyad_alignment_pairs as pair
    where pair.dyad_run_id = new.id
      and (
        semantic_private.assertion_has_healthkit_evidence(
          pair.viewer_assertion_id, pair.viewer_user_id
        )
        or semantic_private.assertion_has_healthkit_evidence(
          pair.subject_assertion_id, pair.subject_user_id
        )
      )
  ) then
    raise exception 'a dyad with HealthKit evidence cannot become general-social';
  end if;
  return new;
end;
$$;

drop trigger if exists dyad_runs_guard_data_use_purpose on semantic_private.dyad_runs;
create trigger dyad_runs_guard_data_use_purpose
before insert or update of data_use_purpose, viewer_user_id, subject_user_id
on semantic_private.dyad_runs
for each row execute function semantic_private.guard_dyad_data_use_purpose();

create or replace function semantic_private.guard_dyad_alignment_healthkit_purpose()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  purpose text;
  uses_healthkit boolean;
begin
  select data_use_purpose into purpose
  from semantic_private.dyad_runs where id = new.dyad_run_id;
  uses_healthkit :=
    semantic_private.assertion_has_healthkit_evidence(
      new.viewer_assertion_id, new.viewer_user_id
    ) or semantic_private.assertion_has_healthkit_evidence(
      new.subject_assertion_id, new.subject_user_id
    );
  if uses_healthkit and purpose is distinct from 'fitness_connection' then
    raise exception 'HealthKit evidence cannot enter a general-social dyad';
  end if;
  if uses_healthkit and (
    (semantic_private.assertion_has_healthkit_evidence(
       new.viewer_assertion_id, new.viewer_user_id
     ) and not semantic_private.healthkit_assertion_is_current(
       new.viewer_assertion_id, new.viewer_user_id
     ))
    or (semantic_private.assertion_has_healthkit_evidence(
       new.subject_assertion_id, new.subject_user_id
     ) and not semantic_private.healthkit_assertion_is_current(
       new.subject_assertion_id, new.subject_user_id
     ))
  ) then
    raise exception 'fitness dyad requires current HealthKit candidates';
  end if;
  return new;
end;
$$;

drop trigger if exists dyad_alignment_pairs_guard_healthkit_purpose
  on semantic_private.dyad_alignment_pairs;
create trigger dyad_alignment_pairs_guard_healthkit_purpose
before insert or update on semantic_private.dyad_alignment_pairs
for each row execute function semantic_private.guard_dyad_alignment_healthkit_purpose();

alter table semantic_private.validated_surface_facts
  add column if not exists data_use_purpose text not null default 'general_social';
alter table semantic_private.validated_surface_facts
  drop constraint if exists validated_surface_facts_evidence_class_check,
  drop constraint if exists validated_surface_facts_evidence_class_v03_check,
  add constraint validated_surface_facts_evidence_class_v03_check check (
    evidence_class in (
      'explicit', 'ontology_inferred', 'calendar_derived',
      'youtube_derived', 'healthkit_derived'
    )
  ),
  drop constraint if exists validated_surface_facts_data_use_purpose_v03_check,
  add constraint validated_surface_facts_data_use_purpose_v03_check check (
    data_use_purpose in ('general_social', 'fitness_connection')
    and (
      evidence_class <> 'healthkit_derived'
      or data_use_purpose = 'fitness_connection'
    )
  ),
  drop constraint if exists validated_surface_facts_healthkit_public_v03_check,
  add constraint validated_surface_facts_healthkit_public_v03_check check (
    evidence_class <> 'healthkit_derived'
    or (
      may_name = false
      or confirmation_state in ('user_confirmed', 'explicit_self_report')
    )
  );

create or replace function semantic_private.guard_healthkit_surface_fact()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if semantic_private.assertion_has_healthkit_evidence(new.assertion_id, new.user_id)
     and new.evidence_class <> 'healthkit_derived' then
    raise exception 'HealthKit provenance requires the healthkit_derived evidence class';
  end if;
  if new.evidence_class = 'healthkit_derived'
     and not semantic_private.assertion_has_healthkit_evidence(
       new.assertion_id, new.user_id
     ) then
    raise exception 'healthkit_derived requires immutable HealthKit provenance';
  end if;
  if new.evidence_class <> 'healthkit_derived' then return new; end if;
  if semantic_private.assertion_has_healthkit_evidence(new.assertion_id, new.user_id)
     and new.state = 'retired'
     and new.may_name = false
     and new.may_explain = false then
    return new;
  end if;
  if not semantic_private.healthkit_assertion_is_current(
       new.assertion_id, new.user_id
     ) then
    raise exception 'HealthKit surface fact requires a current fitness candidate';
  end if;
  if not semantic_private.assertion_has_healthkit_evidence(new.assertion_id, new.user_id)
     or not semantic_private.healthkit_grant_allows(new.user_id, new.surface, 'select')
     or (new.may_name and not semantic_private.healthkit_grant_allows(
       new.user_id, new.surface, 'name'
     ))
     or (new.may_explain and not semantic_private.healthkit_grant_allows(
       new.user_id, new.surface, 'explain'
     )) then
    raise exception 'HealthKit surface fact exceeds its fitness-purpose grant';
  end if;
  return new;
end;
$$;

drop trigger if exists validated_surface_facts_guard_healthkit
  on semantic_private.validated_surface_facts;
create trigger validated_surface_facts_guard_healthkit
before insert or update on semantic_private.validated_surface_facts
for each row execute function semantic_private.guard_healthkit_surface_fact();

-- Link insertion is also an authorization event. Default permissions created
-- before the provenance link are tightened immediately, preventing ordering
-- from bypassing the HealthKit guard.
create or replace function semantic_private.initialize_healthkit_assertion_permissions()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  update semantic_private.assertion_surface_permissions as permission
  set can_select = semantic_private.healthkit_grant_allows(
        new.user_id, permission.surface, 'select'
      ),
      can_name = permission.surface <> 'matching'
        and semantic_private.healthkit_grant_allows(
          new.user_id, permission.surface, 'name'
        ),
      can_explain = permission.surface <> 'matching'
        and semantic_private.healthkit_grant_allows(
          new.user_id, permission.surface, 'explain'
        ),
      permission_source = 'policy_guard'
  where permission.assertion_id = new.assertion_id
    and permission.user_id = new.user_id;
  return new;
end;
$$;

drop trigger if exists healthkit_derived_assertions_initialize_permissions
  on semantic_private.healthkit_derived_assertions;
create trigger healthkit_derived_assertions_initialize_permissions
after insert on semantic_private.healthkit_derived_assertions
for each row execute function semantic_private.initialize_healthkit_assertion_permissions();

-- Any narrowing grant change makes affected product output ineligible.
-- Provenance remains policy-locked for audit and can be deleted with the user.
create or replace function semantic_private.invalidate_healthkit_use_on_revocation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not (
    (old.grant_state = 'active' and new.grant_state = 'revoked')
    or (old.allow_fitness_matching and not new.allow_fitness_matching)
    or (old.allow_bio_naming and not new.allow_bio_naming)
    or (old.allow_icebreaker_naming and not new.allow_icebreaker_naming)
    or (
      old.allow_controlled_explanation
      and not new.allow_controlled_explanation
    )
  ) then return new; end if;
  if new.grant_state = 'revoked' then
    update semantic_private.fitness_habit_candidates
    set review_state = 'retired'
    where user_id = new.user_id
      and review_state in ('candidate', 'user_confirmed');
    update semantic_private.fitness_feature_snapshots
    set state = 'stale', finalized_at = coalesce(finalized_at, now())
    where user_id = new.user_id and state in ('building', 'ready');
    update semantic_private.raw_source_records
    set lifecycle_state = 'deleted', deleted_at = now(),
        encrypted_payload = null, raw_blob_ref = null
    where user_id = new.user_id
      and source_code = 'healthkit'
      and lifecycle_state <> 'deleted';
  end if;
  -- Tighten materialized facts while their old permission rows still authorize
  -- the transition. Migration 004's fact guard deliberately checks those rows.
  update semantic_private.validated_surface_facts as fact
  set state = case
        when semantic_private.healthkit_grant_allows(
          new.user_id, fact.surface, 'select'
        ) then fact.state else 'retired' end,
      may_name = fact.may_name and semantic_private.healthkit_grant_allows(
        new.user_id, fact.surface, 'name'
      ),
      may_explain = fact.may_explain and semantic_private.healthkit_grant_allows(
        new.user_id, fact.surface, 'explain'
      )
  where fact.user_id = new.user_id
    and semantic_private.assertion_has_healthkit_evidence(
      fact.assertion_id, fact.user_id
    );
  update semantic_private.assertion_surface_permissions as permission
  set can_select = semantic_private.healthkit_grant_allows(
        new.user_id, permission.surface, 'select'
      ),
      can_name = permission.surface <> 'matching'
        and semantic_private.healthkit_grant_allows(
          new.user_id, permission.surface, 'name'
        ),
      can_explain = permission.surface <> 'matching'
        and semantic_private.healthkit_grant_allows(
          new.user_id, permission.surface, 'explain'
        ),
      permission_source = 'policy_guard'
  where permission.user_id = new.user_id
    and exists (
      select 1 from semantic_private.healthkit_derived_assertions as link
      where link.assertion_id = permission.assertion_id
        and link.user_id = permission.user_id
    );
  update semantic_private.dyad_runs
  set status = 'stale', finished_at = coalesce(finished_at, now())
  where data_use_purpose = 'fitness_connection'
    and (viewer_user_id = new.user_id or subject_user_id = new.user_id)
    and status in ('running', 'succeeded');
  update semantic_private.bio_variants as bio
  set state = 'stale', finalized_at = coalesce(finalized_at, now())
  where state in ('draft', 'ready')
    and exists (
      select 1 from semantic_private.dyad_runs as run
      where run.id = bio.dyad_run_id and run.status = 'stale'
    );
  update semantic_private.icebreaker_frames as frame
  set state = 'stale', finalized_at = coalesce(finalized_at, now())
  where state in ('draft', 'ready')
    and frame.exposed_at is null
    and exists (
      select 1 from semantic_private.dyad_runs as run
      where run.id = frame.dyad_run_id and run.status = 'stale'
    );
  return new;
end;
$$;

drop trigger if exists healthkit_use_grants_invalidate_on_revocation
  on semantic_private.healthkit_use_grants;
create trigger healthkit_use_grants_invalidate_on_revocation
after update of grant_state, allow_fitness_matching, allow_bio_naming,
  allow_icebreaker_naming, allow_controlled_explanation
on semantic_private.healthkit_use_grants
for each row execute function semantic_private.invalidate_healthkit_use_on_revocation();

-- Match-time frames are provisional. They must be current immediately before
-- first exposure. After exposure, they remain immutable historical text rather
-- than being silently rewritten when an unrelated revision changes.
create or replace function semantic_private.guard_match_authorization_identity()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.match_id is distinct from old.match_id
     or new.participant_a_user_id is distinct from old.participant_a_user_id
     or new.participant_b_user_id is distinct from old.participant_b_user_id
     or new.authorized_at is distinct from old.authorized_at
     or new.source_version is distinct from old.source_version
     or new.created_at is distinct from old.created_at then
    raise exception 'match authorization identity and participants are immutable';
  end if;
  return new;
end;
$$;

drop trigger if exists match_authorizations_guard_identity
  on semantic_private.match_authorizations;
create trigger match_authorizations_guard_identity
before update on semantic_private.match_authorizations
for each row execute function semantic_private.guard_match_authorization_identity();

alter table semantic_private.icebreaker_frames
  add column if not exists exposed_at timestamptz;
alter table semantic_private.icebreaker_frames
  drop constraint if exists icebreaker_frames_exposure_v03_check,
  add constraint icebreaker_frames_exposure_v03_check check (
    exposed_at is null or (state = 'ready' and rendered_text is not null)
  );

create or replace function semantic_private.guard_exposed_icebreaker_immutability()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.exposed_at is null and new.exposed_at is not null
     and coalesce(
       current_setting('written.mark_icebreaker_exposed', true), ''
     ) <> '1' then
    raise exception 'icebreaker exposure must use the validated server function';
  end if;
  if old.exposed_at is not null and (
    new.match_authorization_id is distinct from old.match_authorization_id
    or new.dyad_run_id is distinct from old.dyad_run_id
    or new.viewer_user_id is distinct from old.viewer_user_id
    or new.subject_user_id is distinct from old.subject_user_id
    or new.bridge_concept_id is distinct from old.bridge_concept_id
    or new.ontology_version_id is distinct from old.ontology_version_id
    or new.renderer_model_id is distinct from old.renderer_model_id
    or new.bridge_mode is distinct from old.bridge_mode
    or new.template_version is distinct from old.template_version
    or new.frame_payload is distinct from old.frame_payload
    or new.rendered_text is distinct from old.rendered_text
    or new.state is distinct from old.state
    or new.created_at is distinct from old.created_at
    or new.finalized_at is distinct from old.finalized_at
    or new.exposed_at is distinct from old.exposed_at
  ) then
    raise exception 'an exposed icebreaker is an immutable historical message';
  end if;
  return new;
end;
$$;

drop trigger if exists icebreaker_frames_guard_exposed_immutability
  on semantic_private.icebreaker_frames;
create trigger icebreaker_frames_guard_exposed_immutability
before update on semantic_private.icebreaker_frames
for each row execute function semantic_private.guard_exposed_icebreaker_immutability();

create or replace function semantic_private.guard_exposed_icebreaker_fact_links()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  target_frame_id uuid;
begin
  target_frame_id := case
    when tg_op = 'DELETE' then old.icebreaker_frame_id
    else new.icebreaker_frame_id
  end;
  if exists (
    select 1 from semantic_private.icebreaker_frames as frame
    where frame.id = target_frame_id and frame.exposed_at is not null
  ) then
    raise exception 'facts linked to an exposed icebreaker are immutable';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

drop trigger if exists icebreaker_frame_facts_guard_exposed
  on semantic_private.icebreaker_frame_facts;
create trigger icebreaker_frame_facts_guard_exposed
before insert or update or delete on semantic_private.icebreaker_frame_facts
for each row execute function semantic_private.guard_exposed_icebreaker_fact_links();

create or replace function semantic_private.mark_icebreaker_exposed(target_frame_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform set_config('written.mark_icebreaker_exposed', '1', true);
  update semantic_private.icebreaker_frames as frame
  set state = 'ready', exposed_at = now()
  where frame.id = target_frame_id
    and frame.state = 'ready'
    and frame.rendered_text is not null
    and frame.exposed_at is null
    and semantic_private.dyad_run_is_current(frame.dyad_run_id)
    and exists (
      select 1 from semantic_private.match_authorizations as match_auth
      where match_auth.id = frame.match_authorization_id
        and match_auth.authorization_state = 'active'
    )
    and 2 = (
      select count(*)
      from semantic_private.icebreaker_frame_facts as link
      where link.icebreaker_frame_id = frame.id
    )
    and not exists (
      select 1
      from semantic_private.icebreaker_frame_facts as link
      left join semantic_private.validated_surface_facts as fact
        on fact.id = link.surface_fact_id
       and fact.user_id = link.fact_user_id
      left join semantic_private.assertion_surface_permissions as permission
        on permission.assertion_id = fact.assertion_id
       and permission.user_id = fact.user_id
       and permission.surface = 'icebreaker'
      where link.icebreaker_frame_id = frame.id
        and (
          fact.id is null
          or fact.surface <> 'icebreaker'
          or fact.state <> 'validated'
          or not fact.may_name
          or permission.assertion_id is null
          or not permission.can_select
          or not permission.can_name
          or (
            semantic_private.assertion_has_healthkit_evidence(
              fact.assertion_id, fact.user_id
            )
            and not semantic_private.healthkit_assertion_is_current(
              fact.assertion_id, fact.user_id
            )
          )
        )
    );
  if not found then
    raise exception 'icebreaker is not current and authorized for first exposure';
  end if;
  perform set_config('written.mark_icebreaker_exposed', '0', true);
end;
$$;

-- Replace v0.2's whole-user invalidation only for icebreakers: unexposed frames
-- stale; exposed frames are historical snapshots. Memories, dyads, and bios
-- remain exact-revision V1 objects.
create or replace function semantic_private.invalidate_product_outputs_on_revision()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.revision is not distinct from old.revision then return new; end if;
  update semantic_private.fitness_habit_candidates as candidate
  set review_state = 'retired'
  where candidate.user_id = new.user_id
    and candidate.review_state in ('candidate', 'user_confirmed')
    and exists (
      select 1 from semantic_private.fitness_feature_snapshots as snapshot
      where snapshot.id = candidate.feature_snapshot_id
        and snapshot.user_id = candidate.user_id
        and snapshot.input_revision <> new.revision
    );
  update semantic_private.fitness_feature_snapshots
  set state = 'stale', finalized_at = coalesce(finalized_at, now())
  where user_id = new.user_id
    and input_revision <> new.revision
    and state in ('building', 'ready');
  update semantic_private.memories_snapshots
  set state = 'stale', finished_at = coalesce(finished_at, now())
  where user_id = new.user_id
    and input_revision <> new.revision
    and state in ('building', 'ready');
  update semantic_private.dyad_runs
  set status = 'stale', finished_at = coalesce(finished_at, now())
  where (viewer_user_id = new.user_id or subject_user_id = new.user_id)
    and status in ('running', 'succeeded')
    and (
      (viewer_user_id = new.user_id and viewer_revision <> new.revision) or
      (subject_user_id = new.user_id and subject_revision <> new.revision)
    );
  update semantic_private.bio_variants as bio
  set state = 'stale', finalized_at = coalesce(finalized_at, now())
  where state in ('draft', 'ready')
    and exists (
      select 1 from semantic_private.dyad_runs as run
      where run.id = bio.dyad_run_id and run.status = 'stale'
    );
  update semantic_private.icebreaker_frames as frame
  set state = 'stale', finalized_at = coalesce(finalized_at, now())
  where state in ('draft', 'ready')
    and frame.exposed_at is null
    and exists (
      select 1 from semantic_private.dyad_runs as run
      where run.id = frame.dyad_run_id and run.status = 'stale'
    );
  return new;
end;
$$;

-- -------------------------------------------------------------------------
-- Strict Calendar promotion. Capture remains broad; generic ontology mapping
-- is closed. Typed travel/booking rows bind only to active compatible nodes.
-- -------------------------------------------------------------------------

alter table semantic_private.calendar_event_classifications
  add column if not exists ontology_version_id uuid,
  add column if not exists input_revision bigint;
drop table if exists pg_temp.calendar_v03_legacy_users;
create temporary table calendar_v03_legacy_users on commit drop as
select distinct legacy.user_id
from (
  select classification.user_id
  from semantic_private.calendar_event_classifications as classification
  where classification.ontology_version_id is null
     or classification.input_revision is null
  union
  select mapping.user_id
  from semantic_private.observation_mappings as mapping
  join semantic_private.observations as observation
    on observation.id = mapping.observation_id
   and observation.user_id = mapping.user_id
  where mapping.mapping_state <> 'superseded'
    and observation.source_code in ('apple_calendar', 'google_calendar')
) as legacy;
update semantic_private.calendar_event_classifications as classification
set ontology_version_id = version.id
from ontology.versions as version
where version.status = 'published'
  and classification.ontology_version_id is null;
update semantic_private.calendar_event_classifications as classification
set input_revision = state.revision
from semantic_private.user_state_versions as state
where state.user_id = classification.user_id
  and classification.input_revision is null;
alter table semantic_private.calendar_event_classifications
  alter column ontology_version_id set not null,
  alter column input_revision set not null,
  drop constraint if exists calendar_classifications_version_v03_fkey,
  add constraint calendar_classifications_version_v03_fkey
    foreign key (ontology_version_id)
    references ontology.versions(id) on delete restrict,
  drop constraint if exists calendar_classifications_revision_v03_check,
  add constraint calendar_classifications_revision_v03_check
    check (input_revision >= 0);

create or replace function semantic_private.guard_calendar_classification_current_v03()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  pinned_classifier_version text;
  controlled_artifact_type text;
begin
  select classifier.version into pinned_classifier_version
  from ontology.model_versions as classifier
  where classifier.id = new.classifier_model_id
    and classifier.model_role = 'calendar_classifier';
  if pinned_classifier_version is null then
    raise exception 'Calendar classification requires a registered classifier';
  end if;
  if coalesce(
       current_setting('written.calendar_v03_sanitizing', true), '0'
     ) <> '1' and not exists (
    select 1
    from semantic_private.observations as observation
    join semantic_private.user_state_versions as state
      on state.user_id = observation.user_id
     and state.revision = new.input_revision
    join ontology.model_versions as classifier
      on classifier.id = new.classifier_model_id
     and classifier.model_role = 'calendar_classifier'
     and classifier.status = 'active'
    join ontology.versions as version
      on version.id = new.ontology_version_id
     and version.status = 'published'
    where observation.id = new.observation_id
      and observation.user_id = new.user_id
      and observation.source_code in ('apple_calendar', 'google_calendar')
      and observation.lifecycle_state = 'active'
  ) then
    raise exception 'Calendar classification must use the current revision, published ontology, and active classifier';
  end if;
  controlled_artifact_type := case
    when new.event_class = 'travel_itinerary' then 'travel_itinerary'
    when new.event_class = 'commercial_reservation' then 'commercial_reservation'
    when new.event_class = 'public_ticketed_event' then 'public_ticket'
    when new.disposition = 'review' then 'unknown_review'
    else 'private_excluded'
  end;
  new.feature_snapshot := jsonb_build_object(
    'classifier_version', pinned_classifier_version,
    'event_class', new.event_class,
    'disposition', new.disposition,
    'reason_codes', jsonb_build_array(
      'calendar_v03_' || new.event_class || '_' || new.disposition
    ),
    'artifact_type', controlled_artifact_type
  );
  return new;
end;
$$;

drop trigger if exists calendar_classifications_guard_current_v03
  on semantic_private.calendar_event_classifications;
create trigger calendar_classifications_guard_current_v03
before insert or update on semantic_private.calendar_event_classifications
for each row execute function semantic_private.guard_calendar_classification_current_v03();

-- Replace every legacy classifier JSON object with the same controlled
-- projection. The migration-local bypass permits historical rows to be
-- sanitized without declaring their old result current or eligible.
alter table semantic_private.calendar_event_classifications
  drop constraint if exists calendar_classifications_safe_payload_check;
select set_config('written.calendar_v03_sanitizing', '1', true);
update semantic_private.calendar_event_classifications
set feature_snapshot = feature_snapshot;
select set_config('written.calendar_v03_sanitizing', '0', true);
alter table semantic_private.calendar_event_classifications
  add constraint calendar_classifications_safe_payload_check check (
    semantic_private.jsonb_payload_is_safe(feature_snapshot, 1024, array[
      'classifier_version', 'event_class', 'disposition', 'reason_codes',
      'artifact_type'
    ]::text[])
    and feature_snapshot ?& array[
      'classifier_version', 'event_class', 'disposition', 'reason_codes',
      'artifact_type'
    ]::text[]
    and feature_snapshot ->> 'classifier_version'
      ~ '^[A-Za-z0-9][A-Za-z0-9._:+-]{0,79}$'
    and feature_snapshot ->> 'event_class' = event_class
    and feature_snapshot ->> 'disposition' = disposition
    and feature_snapshot -> 'reason_codes' = jsonb_build_array(
      'calendar_v03_' || event_class || '_' || disposition
    )
    and feature_snapshot ->> 'artifact_type' = case
      when event_class = 'travel_itinerary' then 'travel_itinerary'
      when event_class = 'commercial_reservation' then 'commercial_reservation'
      when event_class = 'public_ticketed_event' then 'public_ticket'
      when disposition = 'review' then 'unknown_review'
      else 'private_excluded'
    end
  );

create or replace function semantic_private.calendar_classification_is_current_v03(
  target_classification_id uuid,
  target_user_id uuid,
  target_observation_id uuid,
  target_ontology_version_id uuid
)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1
    from semantic_private.calendar_event_classifications as classification
    join semantic_private.user_state_versions as state
      on state.user_id = classification.user_id
     and state.revision = classification.input_revision
    join ontology.model_versions as classifier
      on classifier.id = classification.classifier_model_id
     and classifier.model_role = 'calendar_classifier'
     and classifier.status = 'active'
    join ontology.versions as version
      on version.id = classification.ontology_version_id
     and version.status = 'published'
    where classification.id = target_classification_id
      and classification.user_id = target_user_id
      and classification.observation_id = target_observation_id
      and classification.ontology_version_id = target_ontology_version_id
      and classification.disposition = 'eligible_private_semantics'
      and classification.event_class in (
        'travel_itinerary', 'commercial_reservation',
        'public_ticketed_event'
      )
  );
$$;

create or replace function semantic_private.guard_calendar_typed_source_current_v03()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if coalesce(
       current_setting('written.calendar_v03_sanitizing', true), '0'
     ) <> '1' and not semantic_private.calendar_classification_is_current_v03(
    new.calendar_classification_id, new.user_id,
    new.source_observation_id, new.ontology_version_id
  ) then
    raise exception 'typed Calendar candidate requires a current eligible classification';
  end if;
  new.extraction_payload := jsonb_build_object(
    'extractor_version', 'calendar-v03',
    'parse_method', 'typed_allowlisted_fields',
    'reason_codes', jsonb_build_array('current_allowlisted_classification')
  );
  return new;
end;
$$;

drop trigger if exists travel_segments_guard_current_classification_v03
  on semantic_private.travel_segments;
create trigger travel_segments_guard_current_classification_v03
before insert or update on semantic_private.travel_segments
for each row execute function semantic_private.guard_calendar_typed_source_current_v03();

select set_config('written.calendar_v03_sanitizing', '1', true);
update semantic_private.travel_segments set extraction_payload = extraction_payload;
select set_config('written.calendar_v03_sanitizing', '0', true);
alter table semantic_private.travel_segments
  drop constraint if exists travel_segments_safe_payload_check,
  add constraint travel_segments_safe_payload_check check (
    extraction_payload = jsonb_build_object(
      'extractor_version', 'calendar-v03',
      'parse_method', 'typed_allowlisted_fields',
      'reason_codes', jsonb_build_array('current_allowlisted_classification')
    )
  );

create unique index if not exists concept_revisions_kind_status_v03_uq
on ontology.concept_revisions (
  ontology_version_id, concept_id, concept_kind, status
);

alter table semantic_private.travel_segments
  add column if not exists required_place_kind_v03 text
    generated always as ('place'::text) stored,
  add column if not exists required_place_status_v03 text
    generated always as ('active'::text) stored;
alter table semantic_private.travel_segments
  drop constraint if exists travel_segments_origin_active_place_v03_fkey,
  drop constraint if exists travel_segments_destination_active_place_v03_fkey,
  add constraint travel_segments_origin_active_place_v03_fkey foreign key (
    ontology_version_id, origin_place_concept_id,
    required_place_kind_v03, required_place_status_v03
  ) references ontology.concept_revisions (
    ontology_version_id, concept_id, concept_kind, status
  ) match simple on update restrict on delete restrict,
  add constraint travel_segments_destination_active_place_v03_fkey foreign key (
    ontology_version_id, destination_place_concept_id,
    required_place_kind_v03, required_place_status_v03
  ) references ontology.concept_revisions (
    ontology_version_id, concept_id, concept_kind, status
  ) match simple on update restrict on delete restrict;

create or replace function semantic_private.guard_calendar_journey_payload_v03()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.derivation_payload := jsonb_build_object(
    'builder_version', 'calendar-v03',
    'connection_policy', 'typed_segments_only'
  );
  return new;
end;
$$;
drop trigger if exists travel_journeys_guard_payload_v03
  on semantic_private.travel_journeys;
create trigger travel_journeys_guard_payload_v03
before insert or update on semantic_private.travel_journeys
for each row execute function semantic_private.guard_calendar_journey_payload_v03();
update semantic_private.travel_journeys set derivation_payload = derivation_payload;
alter table semantic_private.travel_journeys
  drop constraint if exists travel_journeys_safe_payload_check,
  add constraint travel_journeys_safe_payload_check check (
    derivation_payload = jsonb_build_object(
      'builder_version', 'calendar-v03',
      'connection_policy', 'typed_segments_only'
    )
  );

alter table semantic_private.travel_journeys
  add column if not exists required_place_kind_v03 text
    generated always as ('place'::text) stored,
  add column if not exists required_place_status_v03 text
    generated always as ('active'::text) stored;
alter table semantic_private.travel_journeys
  drop constraint if exists travel_journeys_anchor_active_place_v03_fkey,
  drop constraint if exists travel_journeys_terminal_active_place_v03_fkey,
  add constraint travel_journeys_anchor_active_place_v03_fkey foreign key (
    ontology_version_id, anchor_place_concept_id,
    required_place_kind_v03, required_place_status_v03
  ) references ontology.concept_revisions (
    ontology_version_id, concept_id, concept_kind, status
  ) match simple on update restrict on delete restrict,
  add constraint travel_journeys_terminal_active_place_v03_fkey foreign key (
    ontology_version_id, terminal_place_concept_id,
    required_place_kind_v03, required_place_status_v03
  ) references ontology.concept_revisions (
    ontology_version_id, concept_id, concept_kind, status
  ) match simple on update restrict on delete restrict;

create or replace function semantic_private.guard_recurring_place_payload_v03()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.derivation_payload := jsonb_build_object(
    'scorer_version', 'calendar-v03',
    'reason_codes', jsonb_build_array('typed_journey_recurrence')
  );
  return new;
end;
$$;
drop trigger if exists recurring_place_candidates_guard_payload_v03
  on semantic_private.recurring_place_candidates;
create trigger recurring_place_candidates_guard_payload_v03
before insert or update on semantic_private.recurring_place_candidates
for each row execute function semantic_private.guard_recurring_place_payload_v03();
update semantic_private.recurring_place_candidates
set derivation_payload = derivation_payload;
alter table semantic_private.recurring_place_candidates
  drop constraint if exists recurring_place_candidates_safe_payload_check,
  add constraint recurring_place_candidates_safe_payload_check check (
    derivation_payload = jsonb_build_object(
      'scorer_version', 'calendar-v03',
      'reason_codes', jsonb_build_array('typed_journey_recurrence')
    )
  );

alter table semantic_private.recurring_place_candidates
  add column if not exists required_place_kind_v03 text
    generated always as ('place'::text) stored,
  add column if not exists required_place_status_v03 text
    generated always as ('active'::text) stored;
alter table semantic_private.recurring_place_candidates
  drop constraint if exists recurring_place_candidates_active_place_v03_fkey,
  add constraint recurring_place_candidates_active_place_v03_fkey foreign key (
    ontology_version_id, place_concept_id,
    required_place_kind_v03, required_place_status_v03
  ) references ontology.concept_revisions (
    ontology_version_id, concept_id, concept_kind, status
  ) on update restrict on delete restrict;

alter table semantic_private.scheduled_travel_candidates
  add column if not exists required_place_kind_v03 text
    generated always as ('place'::text) stored,
  add column if not exists required_place_status_v03 text
    generated always as ('active'::text) stored;
alter table semantic_private.scheduled_travel_candidates
  drop constraint if exists scheduled_travel_candidates_active_place_v03_fkey,
  add constraint scheduled_travel_candidates_active_place_v03_fkey foreign key (
    ontology_version_id, destination_place_concept_id,
    required_place_kind_v03, required_place_status_v03
  ) references ontology.concept_revisions (
    ontology_version_id, concept_id, concept_kind, status
  ) on update restrict on delete restrict;

alter table semantic_private.booked_activity_candidates
  add column if not exists required_place_kind_v03 text
    generated always as ('place'::text) stored,
  add column if not exists required_place_status_v03 text
    generated always as ('active'::text) stored,
  add column if not exists target_concept_kind text,
  add column if not exists target_external_link_id uuid,
  add column if not exists target_external_entity_id uuid,
  add column if not exists required_target_status_v03 text
    generated always as ('active'::text) stored,
  add column if not exists required_external_link_type_v03 text
    generated always as ('same_as'::text) stored,
  add column if not exists required_external_link_status_v03 text
    generated always as ('active'::text) stored;

-- A pre-v0.3 specific target has no durable catalog proof. Downgrade it to a
-- safe generic category instead of preserving an unverifiable label.
update semantic_private.booked_activity_candidates
set target_concept_id = case predicate_key
      when 'booked_activity_at' then
        '3f5f4d44-c55c-57ea-a805-a81cf30cdc4d'::uuid
      when 'booked_event' then
        '8816b5e8-ce07-582b-abdf-86f7359d1f1e'::uuid
      when 'scheduled_dining' then
        '225d65e7-20cb-5d7e-af32-daef5ea5a5b4'::uuid
    end,
    target_external_link_id = null,
    target_external_entity_id = null
where target_external_link_id is null
  and target_concept_id is distinct from case predicate_key
    when 'booked_activity_at' then
      '3f5f4d44-c55c-57ea-a805-a81cf30cdc4d'::uuid
    when 'booked_event' then
      '8816b5e8-ce07-582b-abdf-86f7359d1f1e'::uuid
    when 'scheduled_dining' then
      '225d65e7-20cb-5d7e-af32-daef5ea5a5b4'::uuid
  end;
update semantic_private.booked_activity_candidates as candidate
set target_concept_kind = revision.concept_kind
from ontology.concept_revisions as revision
where revision.ontology_version_id = candidate.ontology_version_id
  and revision.concept_id = candidate.target_concept_id
  and candidate.target_concept_kind is null;
alter table semantic_private.booked_activity_candidates
  alter column target_concept_kind set not null;

create unique index if not exists external_concept_links_booking_v03_uq
on ontology.external_concept_links (
  id, ontology_version_id, concept_id, external_entity_id, link_type, status
);

alter table semantic_private.booked_activity_candidates
  drop constraint if exists booked_activity_candidates_active_place_v03_fkey,
  drop constraint if exists booked_activity_candidates_target_active_v03_fkey,
  drop constraint if exists booked_activity_candidates_external_link_v03_fkey,
  drop constraint if exists booked_activity_candidates_target_binding_v03_check,
  add constraint booked_activity_candidates_active_place_v03_fkey foreign key (
    ontology_version_id, place_concept_id,
    required_place_kind_v03, required_place_status_v03
  ) references ontology.concept_revisions (
    ontology_version_id, concept_id, concept_kind, status
  ) match simple on update restrict on delete restrict,
  add constraint booked_activity_candidates_target_active_v03_fkey foreign key (
    ontology_version_id, target_concept_id,
    target_concept_kind, required_target_status_v03
  ) references ontology.concept_revisions (
    ontology_version_id, concept_id, concept_kind, status
  ) on update restrict on delete restrict,
  add constraint booked_activity_candidates_external_link_v03_fkey foreign key (
    target_external_link_id, ontology_version_id, target_concept_id,
    target_external_entity_id, required_external_link_type_v03,
    required_external_link_status_v03
  ) references ontology.external_concept_links (
    id, ontology_version_id, concept_id, external_entity_id, link_type, status
  ) match simple on update restrict on delete restrict,
  add constraint booked_activity_candidates_target_binding_v03_check check (
    (
      target_external_link_id is null
      and target_external_entity_id is null
      and target_concept_kind = 'hub'
      and (
        (predicate_key = 'booked_activity_at' and target_concept_id =
          '3f5f4d44-c55c-57ea-a805-a81cf30cdc4d'::uuid)
        or (predicate_key = 'booked_event' and target_concept_id =
          '8816b5e8-ce07-582b-abdf-86f7359d1f1e'::uuid)
        or (predicate_key = 'scheduled_dining' and target_concept_id =
          '225d65e7-20cb-5d7e-af32-daef5ea5a5b4'::uuid)
      )
    )
    or (
      target_external_link_id is not null
      and target_external_entity_id is not null
      and (
        (predicate_key = 'booked_activity_at' and target_concept_kind = 'place')
        or (predicate_key = 'booked_event' and target_concept_kind in ('event', 'topic'))
        or (predicate_key = 'scheduled_dining' and target_concept_kind in ('cuisine', 'place'))
      )
    )
  );

create or replace function semantic_private.guard_booked_activity_target_v03()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  resolved_kind text;
  resolved_entity uuid;
  resolved_provider text;
begin
  if coalesce(
       current_setting('written.calendar_v03_sanitizing', true), '0'
     ) <> '1' and not semantic_private.calendar_classification_is_current_v03(
    new.calendar_classification_id, new.user_id,
    new.source_observation_id, new.ontology_version_id
  ) then
    raise exception 'booked target requires a current eligible Calendar classification';
  end if;
  select revision.concept_kind into resolved_kind
  from ontology.concept_revisions as revision
  where revision.ontology_version_id = new.ontology_version_id
    and revision.concept_id = new.target_concept_id
    and revision.status = 'active';
  if resolved_kind is null then
    raise exception 'booked target requires an active concept revision';
  end if;
  new.target_concept_kind := resolved_kind;
  if new.target_external_link_id is null then
    new.target_external_entity_id := null;
  else
    select link.external_entity_id, lower(entity.provider)
    into resolved_entity, resolved_provider
    from ontology.external_concept_links as link
    join ontology.external_entities as entity
      on entity.id = link.external_entity_id
    where link.id = new.target_external_link_id
      and link.ontology_version_id = new.ontology_version_id
      and link.concept_id = new.target_concept_id
      and link.link_type = 'same_as'
      and link.status = 'active';
    if resolved_entity is null or resolved_provider not in (
      'airbnb', 'eventbrite', 'getyourguide', 'opentable',
      'resy', 'ticketmaster', 'viator'
    ) then
      raise exception 'specific booked target requires an active verified vendor identity';
    end if;
    if new.target_external_entity_id is not null
       and new.target_external_entity_id is distinct from resolved_entity then
      raise exception 'booked target external entity does not match its exact link';
    end if;
    new.target_external_entity_id := resolved_entity;
  end if;
  return new;
end;
$$;

drop trigger if exists booked_activity_candidates_guard_target_binding_v03
  on semantic_private.booked_activity_candidates;
create trigger booked_activity_candidates_guard_target_binding_v03
before insert or update on semantic_private.booked_activity_candidates
for each row execute function semantic_private.guard_booked_activity_target_v03();

-- Presentation text is derived from canonical ontology labels, never from a
-- Calendar title/location supplied by a connector or classifier worker.
create or replace function semantic_private.guard_scheduled_travel_journey_terminal()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  canonical_place_label text;
begin
  select revision.preferred_label into canonical_place_label
  from semantic_private.travel_journeys as journey
  join semantic_private.travel_journey_segments as link
    on link.journey_id = journey.id
   and link.user_id = journey.user_id
   and link.ontology_version_id = journey.ontology_version_id
   and link.segment_role in ('terminal', 'one_way')
  join semantic_private.travel_segments as segment
    on segment.id = link.segment_id
   and segment.user_id = link.user_id
   and segment.ontology_version_id = link.ontology_version_id
  join ontology.concept_revisions as revision
    on revision.ontology_version_id = journey.ontology_version_id
   and revision.concept_id = journey.terminal_place_concept_id
   and revision.concept_kind = 'place'
   and revision.status = 'active'
  where journey.id = new.travel_journey_id
    and journey.user_id = new.user_id
    and journey.ontology_version_id = new.ontology_version_id
    and journey.terminal_place_concept_id = new.destination_place_concept_id
    and journey.journey_state <> 'cancelled'
    and segment.destination_place_concept_id = journey.terminal_place_concept_id
    and segment.segment_state <> 'cancelled'
    and (
      coalesce(
        current_setting('written.calendar_v03_sanitizing', true), '0'
      ) = '1'
      or semantic_private.calendar_classification_is_current_v03(
        segment.calendar_classification_id, segment.user_id,
        segment.source_observation_id, segment.ontology_version_id
      )
    )
  limit 1;
  if canonical_place_label is null or (
    coalesce(
      current_setting('written.calendar_v03_sanitizing', true), '0'
    ) <> '1' and exists (
    select 1
    from semantic_private.travel_journey_segments as link
    join semantic_private.travel_segments as segment
      on segment.id = link.segment_id
     and segment.user_id = link.user_id
     and segment.ontology_version_id = link.ontology_version_id
    where link.journey_id = new.travel_journey_id
      and not semantic_private.calendar_classification_is_current_v03(
        segment.calendar_classification_id, segment.user_id,
        segment.source_observation_id, segment.ontology_version_id
      )
    )
  ) then
    raise exception 'scheduled travel candidate requires a current typed terminal journey';
  end if;
  new.display_payload := jsonb_build_object(
    'template_key', 'scheduled_trip',
    'wording_version', 'calendar-v03',
    'predicate_label', 'Scheduled travel to',
    'place_label', canonical_place_label,
    'source_badges', jsonb_build_array('Calendar')
  );
  return new;
end;
$$;

create or replace function semantic_private.scheduled_travel_candidate_is_current_v03(
  target_candidate_id uuid,
  target_user_id uuid
)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1
    from semantic_private.scheduled_travel_candidates as candidate
    join semantic_private.travel_journeys as journey
      on journey.id = candidate.travel_journey_id
     and journey.user_id = candidate.user_id
     and journey.ontology_version_id = candidate.ontology_version_id
     and journey.terminal_place_concept_id = candidate.destination_place_concept_id
    where candidate.id = target_candidate_id
      and candidate.user_id = target_user_id
      and candidate.candidate_state = 'eligible'
      and journey.journey_state <> 'cancelled'
      and exists (
        select 1
        from semantic_private.travel_journey_segments as link
        join semantic_private.travel_segments as segment
          on segment.id = link.segment_id
         and segment.user_id = link.user_id
         and segment.ontology_version_id = link.ontology_version_id
        where link.journey_id = journey.id
          and link.user_id = journey.user_id
          and link.ontology_version_id = journey.ontology_version_id
          and link.segment_role in ('terminal', 'one_way')
          and segment.segment_state <> 'cancelled'
          and segment.destination_place_concept_id = journey.terminal_place_concept_id
          and semantic_private.calendar_classification_is_current_v03(
            segment.calendar_classification_id, segment.user_id,
            segment.source_observation_id, segment.ontology_version_id
          )
      )
      and not exists (
        select 1
        from semantic_private.travel_journey_segments as link
        join semantic_private.travel_segments as segment
          on segment.id = link.segment_id
         and segment.user_id = link.user_id
         and segment.ontology_version_id = link.ontology_version_id
        where link.journey_id = journey.id
          and link.user_id = journey.user_id
          and link.ontology_version_id = journey.ontology_version_id
          and not semantic_private.calendar_classification_is_current_v03(
            segment.calendar_classification_id, segment.user_id,
            segment.source_observation_id, segment.ontology_version_id
          )
      )
  );
$$;

create or replace function semantic_private.guard_booked_activity_target_v03()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  resolved_kind text;
  resolved_entity uuid;
  resolved_provider text;
  canonical_target_label text;
  canonical_place_label text;
  controlled_predicate_label text;
begin
  if coalesce(
       current_setting('written.calendar_v03_sanitizing', true), '0'
     ) <> '1' and not semantic_private.calendar_classification_is_current_v03(
    new.calendar_classification_id, new.user_id,
    new.source_observation_id, new.ontology_version_id
  ) then
    raise exception 'booked target requires a current eligible Calendar classification';
  end if;
  select revision.concept_kind, revision.preferred_label
  into resolved_kind, canonical_target_label
  from ontology.concept_revisions as revision
  where revision.ontology_version_id = new.ontology_version_id
    and revision.concept_id = new.target_concept_id
    and revision.status = 'active';
  if resolved_kind is null then
    raise exception 'booked target requires an active concept revision';
  end if;
  new.target_concept_kind := resolved_kind;
  if new.target_external_link_id is null then
    new.target_external_entity_id := null;
  else
    select link.external_entity_id, lower(entity.provider)
    into resolved_entity, resolved_provider
    from ontology.external_concept_links as link
    join ontology.external_entities as entity
      on entity.id = link.external_entity_id
    where link.id = new.target_external_link_id
      and link.ontology_version_id = new.ontology_version_id
      and link.concept_id = new.target_concept_id
      and link.link_type = 'same_as'
      and link.status = 'active';
    if resolved_entity is null or resolved_provider not in (
      'airbnb', 'eventbrite', 'getyourguide', 'opentable',
      'resy', 'ticketmaster', 'viator'
    ) then
      raise exception 'specific booked target requires an active verified vendor identity';
    end if;
    if new.target_external_entity_id is not null
       and new.target_external_entity_id is distinct from resolved_entity then
      raise exception 'booked target external entity does not match its exact link';
    end if;
    new.target_external_entity_id := resolved_entity;
  end if;
  if new.place_concept_id is not null then
    select revision.preferred_label into canonical_place_label
    from ontology.concept_revisions as revision
    where revision.ontology_version_id = new.ontology_version_id
      and revision.concept_id = new.place_concept_id
      and revision.concept_kind = 'place'
      and revision.status = 'active';
    if canonical_place_label is null then
      raise exception 'booked candidate place must be an active place concept';
    end if;
  end if;
  controlled_predicate_label := case new.predicate_key
    when 'booked_activity_at' then 'Booked activity'
    when 'booked_event' then 'Booked event'
    when 'scheduled_dining' then 'Scheduled dining'
  end;
  new.display_payload := jsonb_build_object(
    'template_key', new.predicate_key,
    'wording_version', 'calendar-v03',
    'predicate_label', controlled_predicate_label,
    'target_label', canonical_target_label,
    'source_badges', jsonb_build_array('Calendar')
  ) || case when canonical_place_label is null then '{}'::jsonb else
    jsonb_build_object('place_label', canonical_place_label) end;
  return new;
end;
$$;

-- Remove any legacy free-text presentation values before the strict triggers
-- become the only write path. The typed evidence rows remain for private audit.
select set_config('written.calendar_v03_sanitizing', '1', true);
update semantic_private.scheduled_travel_candidates as candidate
set display_payload = jsonb_build_object(
  'template_key', 'scheduled_trip',
  'wording_version', 'calendar-v03',
  'predicate_label', 'Scheduled travel to',
  'place_label', revision.preferred_label,
  'source_badges', jsonb_build_array('Calendar')
)
from ontology.concept_revisions as revision
where revision.ontology_version_id = candidate.ontology_version_id
  and revision.concept_id = candidate.destination_place_concept_id
  and revision.concept_kind = 'place'
  and revision.status = 'active';

update semantic_private.booked_activity_candidates as candidate
set display_payload = jsonb_build_object(
  'template_key', candidate.predicate_key,
  'wording_version', 'calendar-v03',
  'predicate_label', case candidate.predicate_key
    when 'booked_activity_at' then 'Booked activity'
    when 'booked_event' then 'Booked event'
    when 'scheduled_dining' then 'Scheduled dining' end,
  'target_label', target_revision.preferred_label,
  'source_badges', jsonb_build_array('Calendar')
) || case when candidate.place_concept_id is null then '{}'::jsonb else
  jsonb_build_object(
    'place_label', (
      select place_revision.preferred_label
      from ontology.concept_revisions as place_revision
      where place_revision.ontology_version_id = candidate.ontology_version_id
        and place_revision.concept_id = candidate.place_concept_id
        and place_revision.concept_kind = 'place'
        and place_revision.status = 'active'
    )
  ) end
from ontology.concept_revisions as target_revision
where target_revision.ontology_version_id = candidate.ontology_version_id
  and target_revision.concept_id = candidate.target_concept_id
  and target_revision.status = 'active';

update semantic_private.memories_snapshot_items as item
set display_label = 'Scheduled travel to ' ||
      (candidate.display_payload ->> 'place_label'),
    display_payload = candidate.display_payload
from semantic_private.scheduled_travel_candidates as candidate
where item.item_kind = 'scheduled_travel_candidate'
  and item.scheduled_travel_candidate_id = candidate.id
  and item.user_id = candidate.user_id;

update semantic_private.memories_snapshot_items as item
set display_label = (candidate.display_payload ->> 'predicate_label') || ': ' ||
      (candidate.display_payload ->> 'target_label'),
    display_payload = candidate.display_payload
from semantic_private.booked_activity_candidates as candidate
where item.item_kind = 'booked_activity_candidate'
  and item.booked_activity_candidate_id = candidate.id
  and item.user_id = candidate.user_id;
select set_config('written.calendar_v03_sanitizing', '0', true);

create or replace function semantic_private.guard_calendar_memories_item_v03()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  controlled_payload jsonb;
begin
  if new.item_kind = 'scheduled_travel_candidate' then
    select candidate.display_payload into controlled_payload
    from semantic_private.scheduled_travel_candidates as candidate
    where candidate.id = new.scheduled_travel_candidate_id
      and candidate.user_id = new.user_id
      and semantic_private.scheduled_travel_candidate_is_current_v03(
        candidate.id, candidate.user_id
      );
    if controlled_payload is null then
      raise exception 'Calendar Memory requires an eligible typed travel candidate';
    end if;
    new.display_label := 'Scheduled travel to ' ||
      (controlled_payload ->> 'place_label');
    new.display_payload := controlled_payload;
  elsif new.item_kind = 'booked_activity_candidate' then
    select candidate.display_payload into controlled_payload
    from semantic_private.booked_activity_candidates as candidate
    where candidate.id = new.booked_activity_candidate_id
      and candidate.user_id = new.user_id
      and candidate.booking_state <> 'cancelled'
      and semantic_private.calendar_classification_is_current_v03(
        candidate.calendar_classification_id, candidate.user_id,
        candidate.source_observation_id, candidate.ontology_version_id
      );
    if controlled_payload is null then
      raise exception 'Calendar Memory requires a current typed booking candidate';
    end if;
    new.display_label := (controlled_payload ->> 'predicate_label') || ': ' ||
      (controlled_payload ->> 'target_label');
    new.display_payload := controlled_payload;
  end if;
  return new;
end;
$$;

drop trigger if exists memories_snapshot_items_guard_calendar_labels_v03
  on semantic_private.memories_snapshot_items;
create trigger memories_snapshot_items_guard_calendar_labels_v03
before insert or update on semantic_private.memories_snapshot_items
for each row execute function semantic_private.guard_calendar_memories_item_v03();

-- Remediate the old fail-open generic Calendar path exactly once. Revision
-- invalidation stales unexposed products; exposed icebreakers remain immutable
-- historical messages. A deterministic rebuild job regenerates current state.
-- Presentation snapshots are derived caches: discard every legacy item for an
-- affected user so no pre-v0.3 free-text label survives inside presentation
-- JSON while the exact-revision rebuild is pending.
delete from semantic_private.memories_snapshot_items as item
using semantic_private.memories_snapshots as snapshot
where snapshot.id = item.snapshot_id
  and snapshot.user_id = item.user_id
  and snapshot.user_id in (select user_id from calendar_v03_legacy_users);

update semantic_private.user_state_versions as state
set revision = state.revision + 1
where state.user_id in (select user_id from calendar_v03_legacy_users);

-- Re-run the source-specific classifier at the new exact revision. These jobs
-- contain durable IDs only; a successful classifier worker may then enqueue a
-- normal recompute job after typed Calendar candidates have been rebuilt.
insert into semantic_private.worker_jobs (
  job_type, user_id, payload, idempotency_key
)
select 'classify_calendar', observation.user_id,
       jsonb_build_object(
         'observation_id', observation.id::text,
         'user_id', observation.user_id::text,
         'input_revision', state.revision,
         'ontology_version_id', (
           select version.id::text
           from ontology.versions as version
           where version.status = 'published'
           order by version.created_at desc, version.id
           limit 1
         ),
         'classifier_model_id', (
           select model.id::text
           from ontology.model_versions as model
           where model.model_role = 'calendar_classifier'
             and model.status = 'active'
           order by model.created_at desc, model.id
           limit 1
         )
       ),
       'calendar-v03-classify:' || observation.id::text || ':' || state.revision::text
from semantic_private.observations as observation
join semantic_private.user_state_versions as state on state.user_id = observation.user_id
where observation.user_id in (select user_id from calendar_v03_legacy_users)
  and observation.source_code in ('apple_calendar', 'google_calendar')
  and observation.lifecycle_state = 'active'
on conflict (idempotency_key) do nothing;

insert into semantic_private.worker_jobs (
  job_type, user_id, payload, idempotency_key
)
select 'recompute_user', state.user_id,
       jsonb_build_object(
         'user_id', state.user_id::text,
         'input_revision', state.revision,
         'ontology_version_id', (
           select version.id::text
           from ontology.versions as version
           where version.status = 'published'
           order by version.created_at desc, version.id
           limit 1
         ),
         'resolver_model_id', (
           select model.id::text
           from ontology.model_versions as model
           where model.model_role = 'resolver' and model.status = 'active'
           order by model.created_at desc, model.id
           limit 1
         ),
         'scorer_model_id', (
           select model.id::text
           from ontology.model_versions as model
           where model.model_role = 'scorer' and model.status = 'active'
           order by model.created_at desc, model.id
           limit 1
         )
       ),
       'calendar-v03-recompute:' || state.user_id::text || ':' || state.revision::text
from semantic_private.user_state_versions as state
where state.user_id in (select user_id from calendar_v03_legacy_users)
on conflict (idempotency_key) do nothing;
update semantic_private.assertion_surface_permissions as permission
set can_select = false, can_name = false, can_explain = false,
    permission_source = 'policy_guard'
where exists (
  select 1
  from semantic_private.user_assertions as assertion
  join semantic_private.semantic_runs as run
    on run.id = assertion.source_semantic_run_id
   and run.user_id = assertion.user_id
  join semantic_private.observation_mappings as mapping
    on mapping.semantic_run_id = run.id
   and mapping.user_id = run.user_id
  join semantic_private.observations as observation
    on observation.id = mapping.observation_id
   and observation.user_id = mapping.user_id
  where assertion.id = permission.assertion_id
    and assertion.user_id = permission.user_id
    and mapping.mapping_state <> 'superseded'
    and observation.source_code in ('apple_calendar', 'google_calendar')
);
delete from semantic_private.assertion_evidence as evidence
using semantic_private.observation_mappings as mapping,
      semantic_private.observations as observation
where mapping.id = evidence.observation_mapping_id
  and mapping.user_id = evidence.user_id
  and observation.id = mapping.observation_id
  and observation.user_id = mapping.user_id
  and observation.source_code in ('apple_calendar', 'google_calendar');
delete from semantic_private.assertion_current_scores as current_score
where exists (
  select 1
  from semantic_private.assertion_score_versions as score
  join semantic_private.observation_mappings as mapping
    on mapping.semantic_run_id = score.semantic_run_id
   and mapping.user_id = score.user_id
  join semantic_private.observations as observation
    on observation.id = mapping.observation_id
   and observation.user_id = mapping.user_id
  where score.id = current_score.assertion_score_version_id
    and score.user_id = current_score.user_id
    and mapping.mapping_state <> 'superseded'
    and observation.source_code in ('apple_calendar', 'google_calendar')
);
update semantic_private.user_assertions as assertion
set machine_state = 'inactive'
where assertion.assertion_origin = 'inferred'
  and assertion.machine_state in ('candidate', 'eligible')
  and exists (
    select 1
    from semantic_private.observation_mappings as mapping
    join semantic_private.observations as observation
      on observation.id = mapping.observation_id
     and observation.user_id = mapping.user_id
    where mapping.semantic_run_id = assertion.source_semantic_run_id
      and mapping.user_id = assertion.user_id
      and mapping.mapping_state <> 'superseded'
      and observation.source_code in ('apple_calendar', 'google_calendar')
  );
update semantic_private.semantic_runs as run
set status = 'stale', finished_at = coalesce(run.finished_at, now())
where run.status in ('running', 'succeeded')
  and exists (
    select 1
    from semantic_private.observation_mappings as mapping
    join semantic_private.observations as observation
      on observation.id = mapping.observation_id
     and observation.user_id = mapping.user_id
    where mapping.semantic_run_id = run.id
      and mapping.user_id = run.user_id
      and mapping.mapping_state <> 'superseded'
      and observation.source_code in ('apple_calendar', 'google_calendar')
  );
update semantic_private.observation_mappings as mapping
set mapping_state = 'superseded'
from semantic_private.observations as observation
where observation.id = mapping.observation_id
  and observation.user_id = mapping.user_id
  and mapping.mapping_state <> 'superseded'
  and observation.source_code in ('apple_calendar', 'google_calendar');

create or replace function semantic_private.guard_calendar_observation_mapping()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if exists (
    select 1
    from semantic_private.observations as observation
    where observation.id = new.observation_id
      and observation.user_id = new.user_id
      and observation.source_code in ('apple_calendar', 'google_calendar')
  ) then
    raise exception 'Calendar observations cannot enter generic observation_mappings';
  end if;
  return new;
end;
$$;

drop trigger if exists observation_mappings_guard_calendar_classification
  on semantic_private.observation_mappings;
create trigger observation_mappings_guard_calendar_classification
before insert or update on semantic_private.observation_mappings
for each row execute function semantic_private.guard_calendar_observation_mapping();

-- New tables are server-internal. No authenticated/anon policy is created.
alter table semantic_private.raw_source_records enable row level security;
alter table semantic_private.healthkit_use_grants enable row level security;
alter table semantic_private.fitness_feature_snapshots enable row level security;
alter table semantic_private.fitness_habit_candidates enable row level security;
alter table semantic_private.fitness_candidate_support enable row level security;
alter table semantic_private.fitness_candidate_observations enable row level security;
alter table semantic_private.healthkit_derived_assertions enable row level security;

revoke all on table
  semantic_private.raw_source_records,
  semantic_private.healthkit_use_grants,
  semantic_private.fitness_feature_snapshots,
  semantic_private.fitness_habit_candidates,
  semantic_private.fitness_candidate_support,
  semantic_private.fitness_candidate_observations,
  semantic_private.healthkit_derived_assertions
from public, anon, authenticated, service_role;

grant select, insert, update on table
  semantic_private.raw_source_records,
  semantic_private.healthkit_use_grants,
  semantic_private.fitness_feature_snapshots,
  semantic_private.fitness_habit_candidates,
  semantic_private.fitness_candidate_support,
  semantic_private.fitness_candidate_observations,
  semantic_private.healthkit_derived_assertions
to service_role;
grant delete on table semantic_private.raw_source_records to service_role;

revoke all on function semantic_private.healthkit_grant_allows(uuid, text, text) from public;
revoke all on function semantic_private.assertion_has_healthkit_evidence(uuid, uuid) from public;
revoke all on function semantic_private.guard_raw_source_record_update() from public;
revoke all on function semantic_private.guard_private_source_generic_lane_v03() from public;
revoke all on function semantic_private.guard_private_observation_projection_v03() from public;
revoke all on function semantic_private.private_observation_projection_is_valid_v03(
  text, text, text, text, timestamptz, text, text, text, text, text,
  jsonb, text, double precision, double precision, text, boolean,
  text, text, timestamptz
) from public;
revoke all on function semantic_private.guard_raw_healthkit_grant() from public;
revoke all on function semantic_private.guard_healthkit_grant_delete() from public;
revoke all on function semantic_private.guard_healthkit_derived_assertion() from public;
revoke all on function semantic_private.guard_assertion_evidence_alignment_v03() from public;
revoke all on function semantic_private.guard_healthkit_surface_permission() from public;
revoke all on function semantic_private.guard_dyad_data_use_purpose() from public;
revoke all on function semantic_private.guard_dyad_alignment_healthkit_purpose() from public;
revoke all on function semantic_private.guard_healthkit_surface_fact() from public;
revoke all on function semantic_private.initialize_healthkit_assertion_permissions() from public;
revoke all on function semantic_private.invalidate_healthkit_use_on_revocation() from public;
revoke all on function semantic_private.guard_fitness_snapshot_builder() from public;
revoke all on function semantic_private.worker_json_has_exact_keys_v03(jsonb, text[], text[]) from public;
revoke all on function semantic_private.worker_json_field_is_valid_v03(jsonb, text, text) from public;
revoke all on function semantic_private.worker_job_payload_is_valid_v03(text, uuid, jsonb) from public;
revoke all on function semantic_private.worker_job_result_is_safe_v03(jsonb) from public;
revoke all on function semantic_private.worker_job_row_is_safe_v03(
  text, uuid, jsonb, text, text, text, jsonb
) from public;
revoke all on function semantic_private.sanitize_invalid_worker_jobs_v03() from public;
revoke all on function semantic_private.guard_worker_job_contract_v03() from public;
revoke all on function semantic_private.guard_fitness_habit_candidate() from public;
revoke all on function semantic_private.validate_fitness_candidate_support() from public;
revoke all on function semantic_private.fitness_candidate_support_is_valid(uuid) from public;
revoke all on function semantic_private.fitness_candidate_is_current(uuid, uuid) from public;
revoke all on function semantic_private.healthkit_assertion_is_current(uuid, uuid) from public;
revoke all on function semantic_private.dyad_run_is_current(uuid) from public;
revoke all on function semantic_private.guard_derive_fitness_job_payload() from public;
revoke all on function semantic_private.guard_fitness_candidate_observation() from public;
revoke all on function semantic_private.guard_healthkit_observation_mapping() from public;
revoke all on function semantic_private.guard_exposed_icebreaker_immutability() from public;
revoke all on function semantic_private.guard_exposed_icebreaker_fact_links() from public;
revoke all on function semantic_private.guard_match_authorization_identity() from public;
revoke all on function semantic_private.mark_icebreaker_exposed(uuid) from public;
revoke all on function semantic_private.guard_calendar_classification_current_v03() from public;
revoke all on function semantic_private.calendar_classification_is_current_v03(uuid, uuid, uuid, uuid) from public;
revoke all on function semantic_private.guard_calendar_typed_source_current_v03() from public;
revoke all on function semantic_private.guard_booked_activity_target_v03() from public;
revoke all on function semantic_private.guard_calendar_memories_item_v03() from public;
revoke all on function semantic_private.scheduled_travel_candidate_is_current_v03(uuid, uuid) from public;
revoke all on function semantic_private.guard_calendar_journey_payload_v03() from public;
revoke all on function semantic_private.guard_recurring_place_payload_v03() from public;
grant execute on function
  semantic_private.healthkit_grant_allows(uuid, text, text),
  semantic_private.assertion_has_healthkit_evidence(uuid, uuid),
  semantic_private.healthkit_assertion_is_current(uuid, uuid),
  semantic_private.calendar_classification_is_current_v03(uuid, uuid, uuid, uuid),
  semantic_private.scheduled_travel_candidate_is_current_v03(uuid, uuid),
  semantic_private.dyad_run_is_current(uuid),
  semantic_private.fitness_candidate_support_is_valid(uuid),
  semantic_private.fitness_candidate_is_current(uuid, uuid),
  semantic_private.private_observation_projection_is_valid_v03(
    text, text, text, text, timestamptz, text, text, text, text, text,
    jsonb, text, double precision, double precision, text, boolean,
    text, text, timestamptz
  )
to service_role;
grant execute on function semantic_private.mark_icebreaker_exposed(uuid) to service_role;

commit;
