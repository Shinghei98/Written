-- 0064 — an observation may name its own vocabulary, because the contract's is
-- not the connector's.
--
-- **Three mismatches, none of them a bug.** A captured Calendar row is *an event
-- from Apple Calendar*; the observation it supports is *a sanitised calendar
-- classification*. They are different things and the schema names them
-- differently, which `private_observation_projection_is_valid_v03` states
-- outright:
--
--   | | the record carries | the observation must be |
--   |---|---|---|
--   | `data_type`     | `event`                       | `calendar_event`        |
--   | `action_type`   | `booked` / `entered_by_user`  | `booked` / `scheduled`  |
--   | `action_weight` | `scheduled` = 0.9 in `sources`| exactly `0.0`           |
--
-- `ingest_source_records_v031` derived all three from the record and its scope,
-- so a Calendar projection could not be written at all: `event` is not
-- `calendar_event`, `entered_by_user` is not in the allowed pair, and a
-- `scheduled` action would have carried 0.9 into a column the constraint pins
-- at zero.
--
-- **The scope keeps its own vocabulary and that is deliberate.** A scope
-- describes what was *captured* — and `event` producing both `booked` and
-- `entered_by_user` scopes is the per-row refinement that the Calendar source
-- exists for. Rewriting the scope to match the observation would throw that
-- away. Two vocabularies, one for capture and one for evidence, each named where
-- it applies.
--
-- **`content_lineage_hmac` becomes settable for the same reason.** A candidate
-- projection requires one, and it is the classifier's output — an HMAC over the
-- private title, which is the only thing the title ever contributes. Nothing
-- could supply it before.
--
-- Every field is optional and every default is exactly today's behaviour, so
-- music and HealthKit are untouched.

begin;

create or replace function semantic_private.ingest_source_records_v031(
  p_user_id uuid,
  p_ingestion_run_id uuid,
  p_connector_source_code text,
  p_connector_version text,
  p_input_hash text,
  p_key_version text,
  p_wrapped_dek_b64 text,
  p_kms_key_arn text,
  p_scopes jsonb,
  p_records jsonb,
  p_final boolean
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  existing_user uuid;
  existing_connector text;
  existing_status text;
  existing_dek bytea;
  incoming_dek bytea;
  received integer;
  stored integer;
  items integer := 0;
  scopes integer := 0;
  observed integer := 0;
  scopes_on_run integer := 0;
  key_recorded boolean := false;
  finalized boolean := false;
  receipt jsonb;
begin
  if p_user_id is null or p_ingestion_run_id is null then
    raise exception 'user and ingestion run are required'
      using errcode = 'null_value_not_allowed';
  end if;
  if jsonb_typeof(p_records) is distinct from 'array' then
    raise exception 'records must be a json array, got %', jsonb_typeof(p_records)
      using errcode = 'invalid_parameter_value';
  end if;
  if p_scopes is not null and jsonb_typeof(p_scopes) is distinct from 'array' then
    raise exception 'scopes must be a json array, got %', jsonb_typeof(p_scopes)
      using errcode = 'invalid_parameter_value';
  end if;

  insert into semantic_private.ingestion_runs (
    id, user_id, source_code, connector_source_code,
    connector_version, input_hash, status, run_kind
  )
  values (
    p_ingestion_run_id, p_user_id, p_connector_source_code, p_connector_source_code,
    p_connector_version, p_input_hash, 'running', 'connector'
  )
  on conflict (id) do nothing;

  select r.user_id, r.connector_source_code, r.status
    into existing_user, existing_connector, existing_status
    from semantic_private.ingestion_runs r
   where r.id = p_ingestion_run_id;

  if existing_user is distinct from p_user_id
     or existing_connector is distinct from p_connector_source_code then
    raise exception 'ingestion run % belongs to a different user or connector',
      p_ingestion_run_id
      using errcode = 'insufficient_privilege';
  end if;

  if existing_status is distinct from 'running' then
    raise exception 'ingestion run % is % and cannot accept records',
      p_ingestion_run_id, existing_status
      using errcode = 'object_not_in_prerequisite_state';
  end if;

  if p_scopes is not null then
    with incoming_scopes as (
      select
        element ->> 'scope_key' as scope_key,
        element ->> 'source_code' as source_code,
        element ->> 'data_type' as data_type,
        element ->> 'action_type' as action_type,
        element ->> 'snapshot_mode' as snapshot_mode,
        element ->> 'completeness' as completeness,
        (element ->> 'expected_item_count')::integer as expected_item_count,
        (element ->> 'window_start')::timestamptz as window_start,
        (element ->> 'window_end')::timestamptz as window_end
      from jsonb_array_elements(p_scopes) as element
    ), written as (
      insert into semantic_private.ingestion_run_scopes (
        ingestion_run_id, user_id, source_code, connector_source_code, scope_key,
        data_type, action_type, snapshot_mode, completeness,
        expected_item_count, window_start, window_end
      )
      select
        p_ingestion_run_id, p_user_id, incoming_scopes.source_code,
        p_connector_source_code, incoming_scopes.scope_key,
        incoming_scopes.data_type, incoming_scopes.action_type,
        incoming_scopes.snapshot_mode, incoming_scopes.completeness,
        incoming_scopes.expected_item_count,
        incoming_scopes.window_start, incoming_scopes.window_end
      from incoming_scopes
      on conflict (ingestion_run_id, scope_key) do nothing
      returning 1
    )
    select count(*) into scopes from written;
  end if;

  select count(*) into received from jsonb_array_elements(p_records);

  if received > 0
     and (p_key_version is null or p_wrapped_dek_b64 is null or p_kms_key_arn is null) then
    raise exception 'a non-empty batch must carry its wrapped data key'
      using errcode = 'null_value_not_allowed';
  end if;

  if received > 0 then
    incoming_dek := pg_catalog.decode(p_wrapped_dek_b64, 'base64');

    select k.wrapped_dek into existing_dek
      from semantic_private.user_encryption_keys k
     where k.user_id = p_user_id and k.key_version = p_key_version;

    if existing_dek is not null and existing_dek is distinct from incoming_dek then
      raise exception
        'key version % already names a different wrapped key for this user',
        p_key_version
        using errcode = 'unique_violation';
    end if;
  end if;

  -- **`create temporary table if not exists` keeps the table a warm connection
  -- already has**, which was safe while the shape never changed and is not now.
  -- A pooled backend that served a pre-0064 call holds a thirteen-column
  -- `incoming_batch`, and the insert below names seventeen — so the first call
  -- on a reused connection would fail on a shape mismatch that no amount of
  -- re-deploying fixes and that disappears when the pooler happens to hand out
  -- a fresh backend. Dropping first makes the definition this function's, every
  -- time.
  drop table if exists incoming_batch;
  create temporary table incoming_batch (
    source_code text,
    data_type text,
    scope_key text,
    occurred_at timestamptz,
    source_item_hmac text,
    record_fingerprint text,
    encrypted_payload bytea,
    consent_purpose text,
    retention_policy_version text,
    normalized_payload jsonb,
    observation_kind text,
    payload_schema_version text,
    privacy_class text,
    observation_data_type text,
    observation_action_type text,
    observation_action_weight double precision,
    content_lineage_hmac text
  ) on commit drop;

  insert into incoming_batch
  select
    element ->> 'record_source_code',
    element ->> 'data_type',
    element ->> 'scope_key',
    (element ->> 'occurred_at')::timestamptz,
    element ->> 'source_item_hmac',
    element ->> 'record_fingerprint',
    pg_catalog.decode(element ->> 'encrypted_payload_b64', 'base64'),
    element ->> 'consent_purpose',
    element ->> 'retention_policy_version',
    element -> 'normalized_payload',
    element ->> 'observation_kind',
    element ->> 'payload_schema_version',
    element ->> 'privacy_class',
    element ->> 'observation_data_type',
    element ->> 'observation_action_type',
    (element ->> 'observation_action_weight')::float8,
    element ->> 'content_lineage_hmac'
  from jsonb_array_elements(p_records) as element;

  with inserted as (
    insert into semantic_private.raw_source_records (
      user_id, ingestion_run_id, connector_source_code, source_code, data_type,
      occurred_at, source_item_hmac, record_fingerprint,
      encryption_key_version, encrypted_payload,
      consent_purpose, retention_policy_version, lifecycle_state
    )
    select
      p_user_id, p_ingestion_run_id, p_connector_source_code, b.source_code,
      b.data_type, b.occurred_at, b.source_item_hmac,
      b.record_fingerprint, p_key_version,
      b.encrypted_payload, b.consent_purpose,
      b.retention_policy_version, 'active'
    from incoming_batch b
    on conflict (user_id, source_code, record_fingerprint)
      where lifecycle_state = 'active'
      do nothing
    returning 1
  )
  select count(*) into stored from inserted;

  if stored > 0 then
    if not exists (
      select 1 from semantic_private.user_encryption_keys k
       where k.user_id = p_user_id and k.key_version = p_key_version
    ) then
      update semantic_private.user_encryption_keys
         set retired_at = pg_catalog.now()
       where user_id = p_user_id and retired_at is null;

      insert into semantic_private.user_encryption_keys (
        user_id, key_version, wrapped_dek, kms_key_arn
      )
      values (p_user_id, p_key_version, incoming_dek, p_kms_key_arn);
      key_recorded := true;
    end if;
  end if;

  with written as (
    insert into semantic_private.observations (
      user_id, ingestion_run_id, connector_source_code, source_code, data_type,
      observation_kind, action_type, occurred_at,
      source_item_hmac, record_fingerprint, content_lineage_hmac,
      payload_schema_version, normalized_payload,
      field_quality, action_weight, privacy_class,
      allow_external_resolution, lifecycle_state, provenance_tier
    )
    select
      p_user_id, p_ingestion_run_id, p_connector_source_code, b.source_code,
      -- **The projection's vocabulary where it states one**, the record's
      -- otherwise. Calendar's observation is a `calendar_event` classification
      -- while the row it came from is an `event`; every other source sends
      -- nothing here and behaves exactly as before.
      coalesce(b.observation_data_type, b.data_type), b.observation_kind,
      coalesce(
        b.observation_action_type,
        pg_catalog.split_part(b.scope_key, ':', 3)
      ),
      b.occurred_at,
      b.source_item_hmac, b.record_fingerprint, b.content_lineage_hmac,
      b.payload_schema_version, b.normalized_payload,
      1.0,
      coalesce(
        b.observation_action_weight,
        (s.action_weights ->> pg_catalog.split_part(b.scope_key, ':', 3))::float8,
        0.0
      ),
      b.privacy_class,
      false, 'active', 'typed'
    from incoming_batch b
    join semantic_private.sources s on s.source_code = b.source_code
    where b.scope_key is not null
      and jsonb_typeof(b.normalized_payload) = 'object'
      and b.observation_kind is not null
      and b.payload_schema_version is not null
      and b.privacy_class is not null
    on conflict (user_id, source_code, record_fingerprint) do nothing
    returning 1
  )
  select count(*) into observed from written;

  with written as (
    insert into semantic_private.ingestion_run_items (
      ingestion_run_id, user_id, source_code, scope_key,
      source_item_hmac, record_fingerprint, item_state,
      raw_source_record_id, observation_id, occurred_at
    )
    select
      p_ingestion_run_id, p_user_id, b.source_code, b.scope_key,
      b.source_item_hmac, b.record_fingerprint, 'present',
      r.id, o.id, b.occurred_at
    from incoming_batch b
    join semantic_private.raw_source_records r
      on r.user_id = p_user_id
     and r.source_code = b.source_code
     and r.record_fingerprint = b.record_fingerprint
     and r.lifecycle_state = 'active'
    left join semantic_private.observations o
      on o.user_id = p_user_id
     and o.source_code = b.source_code
     and o.record_fingerprint = b.record_fingerprint
    where b.scope_key is not null
    on conflict (ingestion_run_id, scope_key, source_item_hmac) do nothing
    returning 1
  )
  select count(*) into items from written;

  if p_final then
    select count(*) into scopes_on_run
      from semantic_private.ingestion_run_scopes
     where ingestion_run_id = p_ingestion_run_id;

    if scopes_on_run > 0 then
      receipt := semantic_private.finalize_ingestion_run_v031(p_ingestion_run_id);
      finalized := true;
    end if;
  end if;

  return jsonb_build_object(
    'ingestion_run_id', p_ingestion_run_id,
    'received', received,
    'stored', stored,
    'duplicates', received - stored,
    'scopes_declared', scopes,
    'items_recorded', items,
    'observations_written', observed,
    'key_version', case when stored > 0 then p_key_version end,
    'key_recorded', key_recorded,
    'finalized', finalized,
    'finalization_receipt', receipt
  );
end
$$;

commit;
