-- 0060 — a JSON `null` is not a SQL NULL, and `0059` treated them as one.
--
-- **Every Calendar distillation was refused, and it took the whole run with
-- it.** The endpoint sends no projection for Calendar or HealthKit — their
-- sanitised shape is a classifier's output, not a transcription — so
-- `normalized_payload` arrives as JSON `null`. `0059` then guarded the
-- observation insert with:
--
--     and b.normalized_payload is not null
--
-- and `element -> 'normalized_payload'` yields **`'null'::jsonb`**, which is a
-- perfectly good non-NULL value. So the guard passed, an observation was
-- attempted with a payload of `null`, and
-- `private_observation_projection_is_valid_v03` refused it —
-- *"private observations require an exact closed projection"*. Because the
-- insert shares the run's transaction, the rollback took the encrypted Calendar
-- rows with it, and the vault stayed empty while the client saw a 500.
--
-- **The schema caught this exactly where it should**, which is the argument for
-- the closed projection existing at all: the failure was loud, specific, and
-- landed on the row that was wrong rather than three services away.
--
-- `jsonb_typeof(...) = 'object'` is the honest test. It also stops trusting the
-- caller's shape: a client sending a string, a number or an array for a payload
-- now writes no observation instead of writing a malformed one.
--
-- Ships no product behaviour.

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

  create temporary table if not exists incoming_batch (
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
    privacy_class text
  ) on commit drop;
  delete from incoming_batch;

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
    element ->> 'privacy_class'
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
      source_item_hmac, record_fingerprint,
      payload_schema_version, normalized_payload,
      field_quality, action_weight, privacy_class,
      allow_external_resolution, lifecycle_state, provenance_tier
    )
    select
      p_user_id, p_ingestion_run_id, p_connector_source_code, b.source_code,
      b.data_type, b.observation_kind,
      pg_catalog.split_part(b.scope_key, ':', 3), b.occurred_at,
      b.source_item_hmac, b.record_fingerprint,
      b.payload_schema_version, b.normalized_payload,
      1.0,
      coalesce((s.action_weights ->> pg_catalog.split_part(b.scope_key, ':', 3))::float8, 0.0),
      b.privacy_class,
      false, 'active', 'typed'
    from incoming_batch b
    join semantic_private.sources s on s.source_code = b.source_code
    where b.scope_key is not null
      -- **`jsonb_typeof`, not `is not null`.** A caller that sends no
      -- projection sends JSON `null`, and `element -> 'normalized_payload'`
      -- makes that `'null'::jsonb` — a non-NULL value that sails through an
      -- `is not null` test and then fails the closed-projection check, taking
      -- the whole run's capture down with it. This also stops trusting the
      -- caller's shape: a string, a number or an array now writes no
      -- observation rather than a malformed one.
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
