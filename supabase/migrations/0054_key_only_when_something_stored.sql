-- 0054 — record the wrapped key only when it protects something.
--
-- **Measured, not predicted.** `0053` records the call's key whenever the batch
-- is non-empty, and its own comment accepted the consequence: a batch that
-- turns out to be entirely duplicates leaves a key protecting nothing, on the
-- grounds that an unused key is far better than a missing one. That trade is
-- still right; what was wrong was assuming the case would be rare.
--
-- The first real re-distillation showed the shape. An unchanged 1,225-row Apple
-- Music library was sent again in three batches, every row collided on its
-- fingerprint, **zero** rows were stored — and three more keys were recorded.
-- Four of nine key rows protected nothing. So the count grows with how often
-- somebody distils rather than with how much they have, which is the wrong
-- variable: a person who reconnects Apple Music weekly accrues keys forever
-- while their vault stands still.
--
-- **The fix is an ordering, and it is free because the function is one
-- transaction.** Insert the rows first, then record the key only if any
-- survived the conflict. There is no foreign key from
-- `raw_source_records.encryption_key_version` to this table, so nothing depends
-- on the key existing first; and within a transaction there is no moment at
-- which another session could observe rows without their key. The property
-- `0053` was protecting — ciphertext never outliving the key that reads it —
-- is untouched, because both still land or neither does.
--
-- Existing orphans are left alone. They are a handful of rows, deleting them
-- would be a data change dressed up as a schema one, and a key row that
-- protects nothing is inert rather than wrong.
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
  p_records jsonb
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
  key_recorded boolean := false;
begin
  if p_user_id is null or p_ingestion_run_id is null then
    raise exception 'user and ingestion run are required'
      using errcode = 'null_value_not_allowed';
  end if;
  if jsonb_typeof(p_records) is distinct from 'array' then
    raise exception 'records must be a json array, got %', jsonb_typeof(p_records)
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

  select count(*) into received from jsonb_array_elements(p_records);

  -- Validated before the insert even though the key is written after it: a
  -- batch that names no key cannot be stored at all, and finding that out after
  -- encrypting and inserting would mean rolling back work already done.
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

    -- **Checked before anything is written, and it must stay that way.** A
    -- version already naming a different key means whichever ciphertext is not
    -- under the stored one is permanently unreadable, and a wrong key does not
    -- announce itself. Refusing costs a retry; accepting costs the data.
    if existing_dek is not null and existing_dek is distinct from incoming_dek then
      raise exception
        'key version % already names a different wrapped key for this user',
        p_key_version
        using errcode = 'unique_violation';
    end if;
  end if;

  with incoming as (
    select
      element ->> 'record_source_code' as source_code,
      element ->> 'data_type' as data_type,
      (element ->> 'occurred_at')::timestamptz as occurred_at,
      element ->> 'source_item_hmac' as source_item_hmac,
      element ->> 'record_fingerprint' as record_fingerprint,
      pg_catalog.decode(element ->> 'encrypted_payload_b64', 'base64') as encrypted_payload,
      element ->> 'consent_purpose' as consent_purpose,
      element ->> 'retention_policy_version' as retention_policy_version
    from jsonb_array_elements(p_records) as element
  ), inserted as (
    insert into semantic_private.raw_source_records (
      user_id, ingestion_run_id, connector_source_code, source_code, data_type,
      occurred_at, source_item_hmac, record_fingerprint,
      encryption_key_version, encrypted_payload,
      consent_purpose, retention_policy_version, lifecycle_state
    )
    select
      p_user_id, p_ingestion_run_id, p_connector_source_code, incoming.source_code,
      incoming.data_type, incoming.occurred_at, incoming.source_item_hmac,
      incoming.record_fingerprint, p_key_version,
      incoming.encrypted_payload, incoming.consent_purpose,
      incoming.retention_policy_version, 'active'
    from incoming
    on conflict (user_id, source_code, record_fingerprint)
      where lifecycle_state = 'active'
      do nothing
    returning 1
  )
  select count(*) into stored from inserted;

  -- **After the rows, and only if any survived.** This is the whole of `0054`.
  -- Every re-distillation of an unchanged library is a batch of pure
  -- duplicates, and recording its key would grow this table with how often
  -- somebody distils rather than with what they have.
  --
  -- Safe within one transaction: no other session can see rows without their
  -- key, and there is no foreign key demanding the key exist first. Both land
  -- or neither does, which is the property `0053` was actually protecting.
  if stored > 0 then
    if not exists (
      select 1 from semantic_private.user_encryption_keys k
       where k.user_id = p_user_id and k.key_version = p_key_version
    ) then
      -- Retire the previous active key. Retiring is not deleting: rows
      -- encrypted under it still name it and still decrypt.
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

  return jsonb_build_object(
    'ingestion_run_id', p_ingestion_run_id,
    'received', received,
    'stored', stored,
    'duplicates', received - stored,
    'key_version', case when stored > 0 then p_key_version end,
    'key_recorded', key_recorded
  );
end
$$;

commit;
