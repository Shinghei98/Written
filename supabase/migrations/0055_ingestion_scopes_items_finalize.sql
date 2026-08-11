-- 0055 — a run that can actually finish.
--
-- **1,227 encrypted rows in the vault and not one of them counts as anything.**
-- Measured in production before this migration: seven ingestion runs, all still
-- `running`, none `succeeded`, and `current_source_items`, `observations` and
-- `ingestion_run_items` all empty. Capture was built and promotion was not, so
-- nothing downstream could tell that any row was *currently observed*.
--
-- `finalize_ingestion_run_v031` is where that happens and it says exactly what
-- was missing: it refuses a run with no **scope manifest**, counts
-- `ingestion_run_items` per scope, advances `source_state_heads`, updates
-- `current_source_items`, mints a revision and enqueues worker jobs.
-- `ingest_source_records_v031` wrote neither scopes nor items, so no run could
-- ever be finalized — and Phase 2's classifiers have nothing to run against
-- while "currently observed" is empty.
--
-- **Three things the schema decides rather than us**, each read out of a
-- constraint:
--
--   * `ingestion_run_scopes.action_type` is `not null`, so a scope is
--     `(source_code, data_type, action_type)` and **a row with no action can
--     belong to no scope**. A `user/bio`, a calendar container, the Apple Music
--     subscription flag: kept in the vault, never promoted. That is the
--     contract's *capture broadly, promote narrowly* falling out of the schema
--     rather than being imposed on it, and it is product-visible — an
--     occupation somebody typed is stored and never becomes evidence.
--   * Only `completeness = 'complete'` demands the item count match, and only
--     `complete` licenses expiring an item that went missing. Every Apple Music
--     read is capped, so **`complete` would be a lie**, and it is the lie §10
--     forbids: absence must never be inferred from omission. The client sends
--     `partial`.
--   * A `present` run item needs a `raw_source_record_id`, and the record
--     insert is `on conflict do nothing` — so a duplicate returns no id.
--     **A duplicate still needs a run item**: the item was *seen* this run even
--     though its content did not change, and a head that missed it would read
--     as the item having gone away. Ids are resolved by lookup, not only from
--     `returning`.
--
-- **Still exactly one callable function.** `0052`'s central claim is the size of
-- `semantic_ingestor`'s surface and its assertion counts callable functions.
-- `finalize_ingestion_run_v031` is `security definer` owned by `postgres`, so
-- calling it from *inside* this function needs no grant — the count stays at
-- one and stays honest.
--
-- Ships no product behaviour on its own.

begin;

-- The parameter list changes, so `create or replace` would overload rather than
-- replace — `0026`/`0027` paid for that and `0053` records it. Two overloads
-- would also make `0052`'s assertion correctly fail.
drop function if exists semantic_private.ingest_source_records_v031(
  uuid, uuid, text, text, text, text, text, text, jsonb
);

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
  key_recorded boolean := false;
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

  -- **The manifest is immutable, so a retry must not rewrite it.** The client
  -- sends it with every batch rather than only the first, because a batch that
  -- lands alone after a failure still has to be able to declare its scopes;
  -- `do nothing` is what makes sending it repeatedly harmless.
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

    -- Checked before anything is written. A version already naming a different
    -- key means whichever ciphertext is not under the stored one is
    -- permanently unreadable, and a wrong key does not announce itself.
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

  -- Written after the rows and only if any survived: every re-distillation of
  -- an unchanged library is a batch of pure duplicates, and recording its key
  -- would grow that table with how often somebody distils rather than with what
  -- they have. See `0054`.
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

  -- **A run item for every record that has a scope, inserted or not.** The
  -- join resolves the row this batch is talking about whether this call created
  -- it or an earlier one did — which is the whole point: an item seen again is
  -- still present, and a head that missed it would read as the item having gone
  -- away. Records with no `scope_key` carry no action and are deliberately
  -- absent from here.
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
    -- Called from inside rather than granted to the role, so
    -- `semantic_ingestor` still reaches exactly one function. It is
    -- `security definer` owned by the same role that owns this one.
    receipt := semantic_private.finalize_ingestion_run_v031(p_ingestion_run_id);
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
    'finalized', p_final,
    'finalization_receipt', receipt
  );
end
$$;

revoke all on function semantic_private.ingest_source_records_v031(
  uuid, uuid, text, text, text, text, text, text, jsonb, jsonb, boolean
) from public, anon, authenticated, service_role;

grant execute on function semantic_private.ingest_source_records_v031(
  uuid, uuid, text, text, text, text, text, text, jsonb, jsonb, boolean
) to semantic_ingestor;

comment on function semantic_private.ingest_source_records_v031(
  uuid, uuid, text, text, text, text, text, text, jsonb, jsonb, boolean
) is
  'The only thing semantic_ingestor may do. Records the call''s wrapped data '
  'key, the rows it protects, the run''s immutable scope manifest and one run '
  'item per scoped record; finalizes the run when the last batch says so. '
  'Idempotent throughout.';

-- ---------------------------------------------------------------------------

-- `0052`'s central claim, re-checked because this migration replaced the one
-- function it rests on — and because `p_final` now reaches a *second* function
-- without granting it.
do $$
declare
  readable text;
  callable integer;
begin
  select pg_catalog.string_agg(c.relname, ', ' order by c.relname)
    into readable
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
   where n.nspname in ('semantic_private', 'ontology', 'public', 'private')
     and c.relkind in ('r', 'v', 'm', 'p')
     and pg_catalog.has_table_privilege('semantic_ingestor', c.oid, 'select');

  if readable is not null then
    raise exception 'semantic_ingestor can read tables it must not: %', readable;
  end if;

  select pg_catalog.count(*)
    into callable
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'semantic_private'
     and pg_catalog.has_function_privilege('semantic_ingestor', p.oid, 'execute');

  if callable <> 1 then
    raise exception
      'semantic_ingestor should be able to call exactly one function, can call %',
      callable;
  end if;
end
$$;

commit;
