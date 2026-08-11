-- 0056 — a run with nothing promotable must still keep what it captured.
--
-- **`0055` could throw away a whole batch, and the first probe after deploying
-- it did exactly that.** The probe sends one `user/probe` record. `user` rows
-- carry no action, so they belong to no scope; the run therefore had no scope
-- manifest; `finalize_ingestion_run_v031` refuses that outright — *"finalization
-- requires at least one immutable scope manifest"* — and because the finalize
-- happens inside the same transaction as the insert, **the rollback took the
-- captured rows with it**. Production went from seven runs to seven runs and
-- nothing was stored.
--
-- The probe made it visible; it is not a probe defect. **Every `user`
-- distillation has this shape**: `bio`, `occupation`, `flirt_level`, `gender`
-- and the rest are all `notAnAction` by construction, so a `user` run is
-- *entirely* unpromotable and would have lost everything it captured, silently,
-- on the `final` batch.
--
-- **Capture must not depend on promotion.** That is the contract's governing
-- rule read the right way round: *capture broadly, promote narrowly* means a
-- row nobody can promote is still a row worth keeping. A run that observed
-- nothing promotable has no head to advance and no current state to change —
-- the finalizer has nothing to do, which is different from the run having
-- failed.
--
-- So `p_final` finalizes **if the run has at least one scope**, and otherwise
-- leaves it `running` and says so in the receipt. Such a run is inert: its rows
-- are in the vault, nothing downstream can see them, and nothing is lost. The
-- alternative — failing it — would be claiming an error where there was none.
--
-- Ships no product behaviour on its own.

begin;

-- Same signature, so a plain replace: the drop in `0055` handled the parameter
-- change and this only alters the body.
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

  -- The manifest is immutable, so a retry must not rewrite it. The client sends
  -- it with every batch because a batch that lands alone after a failure still
  -- has to declare its scopes; `do nothing` makes that harmless.
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
    retention_policy_version text
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
    element ->> 'retention_policy_version'
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

  -- A run item for every record that has a scope, inserted or not: an item seen
  -- again is still present, and a head that missed it would read as the item
  -- having gone away.
  with written as (
    insert into semantic_private.ingestion_run_items (
      ingestion_run_id, user_id, source_code, scope_key,
      source_item_hmac, record_fingerprint, item_state,
      raw_source_record_id, occurred_at
    )
    select
      p_ingestion_run_id, p_user_id, b.source_code, b.scope_key,
      b.source_item_hmac, b.record_fingerprint, 'present',
      r.id, b.occurred_at
    from incoming_batch b
    join semantic_private.raw_source_records r
      on r.user_id = p_user_id
     and r.source_code = b.source_code
     and r.record_fingerprint = b.record_fingerprint
     and r.lifecycle_state = 'active'
    where b.scope_key is not null
    on conflict (ingestion_run_id, scope_key, source_item_hmac) do nothing
    returning 1
  )
  select count(*) into items from written;

  if p_final then
    -- **Counted across the run, not this batch.** The scopes may have been
    -- declared by an earlier batch, and a final batch that happens to contain
    -- only unpromotable rows must still finalize what came before it.
    select count(*) into scopes_on_run
      from semantic_private.ingestion_run_scopes
     where ingestion_run_id = p_ingestion_run_id;

    if scopes_on_run > 0 then
      receipt := semantic_private.finalize_ingestion_run_v031(p_ingestion_run_id);
      finalized := true;
    end if;
    -- Otherwise the run observed nothing promotable. It stays `running` and
    -- inert: the rows are captured, nothing downstream can see them, and
    -- nothing is lost. Finalizing would have raised and rolled the capture
    -- back; failing it would claim an error that did not happen.
  end if;

  return jsonb_build_object(
    'ingestion_run_id', p_ingestion_run_id,
    'received', received,
    'stored', stored,
    'duplicates', received - stored,
    'scopes_declared', scopes,
    'items_recorded', items,
    'key_version', case when stored > 0 then p_key_version end,
    'key_recorded', key_recorded,
    'finalized', finalized,
    'finalization_receipt', receipt
  );
end
$$;

commit;
