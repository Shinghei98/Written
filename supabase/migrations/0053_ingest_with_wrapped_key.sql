-- 0053 — the wrapped data key arrives with the rows it protects.
--
-- **The gap this closes was structural, and it was found by designing the
-- Lambda rather than by reading the schema.** Three facts that are each correct
-- and together left no way to encrypt anything:
--
--   1. §12 requires decrypt to be limited to the worker path, so
--      `written-semantic-ingestion` holds `GenerateDataKey` and `Encrypt` and
--      **not** `Decrypt` — verified by simulation, not by reading policy JSON.
--   2. `0050` models one *active* data key per user, wrapped, to be reused.
--   3. `0052` gives `semantic_ingestor` execute on exactly one function, which
--      writes records and cannot touch `user_encryption_keys`.
--
-- **A stored wrapped DEK is unusable to the identity obliged to encrypt with
-- it.** Recovering it means `Decrypt`, which ingestion does not have and must
-- not be given: the two-identity split exists so that neither alone can read
-- the vault, and an ingestion role that could unwrap keys would collapse it.
-- `kms:Encrypt` on the payload directly is not a way out either — it caps at
-- 4 KB of plaintext.
--
-- **So the data key is per *call*, and that is inherent rather than chosen.** A
-- write-only identity cannot reuse a key it cannot recover, and a Lambda is
-- stateless, so every invocation generates a fresh DEK, encrypts with it,
-- discards the plaintext and hands the wrapped copy over here. `0050` already
-- anticipated the shape: *"Retired is not deleted: rows encrypted under it
-- still name it."* The worker, which does hold `Decrypt`, unwraps by version.
--
-- **One call, not two.** The key and the rows it protects arrive in the same
-- statement, so they cannot half-fail. Two calls would have a failure mode
-- where ciphertext exists and the key to read it does not — which is
-- indistinguishable from data loss and is not recoverable by retrying.
--
-- The role's surface is still exactly one function. That is checked below
-- rather than asserted, because `0052`'s whole argument is the size of that
-- surface.
--
-- Ships no product behaviour. Nothing calls it yet.

begin;

-- **`create or replace` would overload rather than replace**, because the
-- parameter list changes — the trap `0026`/`0027` paid for, where `0020`'s
-- five-argument `private.notify` sat alongside a six-argument one and left a
-- latent ambiguity that would have failed from inside a trigger on `likes`.
-- Dropping by full signature is the only way to change a function's parameters.
--
-- It also matters here for a second reason: two overloads would mean two
-- callable functions, and the assertion at the foot — which is `0052`'s central
-- claim — would correctly fail.
drop function if exists semantic_private.ingest_source_records_v031(
  uuid, uuid, text, text, text, jsonb
);

/*
 * As `0052`, plus the wrapped key.
 *
 * `p_key_version` is stamped onto every row rather than read per element. One
 * call encrypts under one key, so a per-record version could only ever be a
 * contradiction waiting to be written — and a row naming a key that did not
 * encrypt it is unreadable in the one way nothing can detect.
 *
 * Still `security definer` with a pinned `search_path`, still takes `p_user_id`
 * rather than deriving it: the endpoint verified the caller's Supabase access
 * token and read `sub` from it, and Postgres has no way to re-check that. What
 * the role cannot do is read any of it back.
 */
-- `create or replace`, and only *because* the drop above removed the old
-- signature. Replacing is idempotent on the same argument list, so the file
-- replays; a bare `create` fails the second time, which the harness caught.
-- The pairing is what matters — the drop handles the signature change, the
-- replace handles being run twice, and neither substitutes for the other.
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

  -- **An empty batch records no key.** A probe call, or a run whose rows were
  -- all filtered before it got here, would otherwise leave a key protecting
  -- nothing — and every such row has to be kept for the life of the account,
  -- since nothing downstream can prove it is unused.
  if received > 0 then
    if p_key_version is null or p_wrapped_dek_b64 is null or p_kms_key_arn is null then
      raise exception 'a non-empty batch must carry its wrapped data key'
        using errcode = 'null_value_not_allowed';
    end if;

    incoming_dek := pg_catalog.decode(p_wrapped_dek_b64, 'base64');

    select k.wrapped_dek into existing_dek
      from semantic_private.user_encryption_keys k
     where k.user_id = p_user_id and k.key_version = p_key_version;

    if existing_dek is null then
      -- **Retire the previous active key before admitting this one.** The
      -- partial unique index in `0050` permits one un-retired key per person,
      -- and retiring is not deleting: rows encrypted under the old version
      -- still name it and still decrypt. Under per-call keys "active" means
      -- the one the most recent ingestion used, which is the only sense the
      -- word can carry when a key is never reused.
      update semantic_private.user_encryption_keys
         set retired_at = pg_catalog.now()
       where user_id = p_user_id and retired_at is null;

      insert into semantic_private.user_encryption_keys (
        user_id, key_version, wrapped_dek, kms_key_arn
      )
      values (p_user_id, p_key_version, incoming_dek, p_kms_key_arn);
      key_recorded := true;

    elsif existing_dek is distinct from incoming_dek then
      -- **The one failure that must never be papered over.** A version already
      -- names a different key, so whichever ciphertext is not encrypted under
      -- the stored one is permanently unreadable — and nothing downstream could
      -- ever detect it, because a wrong key does not announce itself. Refusing
      -- costs a retry; accepting costs the data.
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

  return jsonb_build_object(
    'ingestion_run_id', p_ingestion_run_id,
    'received', received,
    'stored', stored,
    'duplicates', received - stored,
    'key_version', case when received > 0 then p_key_version end,
    'key_recorded', key_recorded
  );
end
$$;

revoke all on function semantic_private.ingest_source_records_v031(
  uuid, uuid, text, text, text, text, text, text, jsonb
) from public, anon, authenticated, service_role;

grant execute on function semantic_private.ingest_source_records_v031(
  uuid, uuid, text, text, text, text, text, text, jsonb
) to semantic_ingestor;

comment on function semantic_private.ingest_source_records_v031(
  uuid, uuid, text, text, text, text, text, text, jsonb
) is
  'The only thing semantic_ingestor may do. Records the call''s wrapped data '
  'key and the rows it protects in one statement, so ciphertext can never '
  'outlive the key that reads it. Idempotent on '
  '(user_id, source_code, record_fingerprint) for active rows.';

-- ---------------------------------------------------------------------------

-- `0052`'s central claim, re-checked because this migration replaced the one
-- function it rests on. A `drop` that missed and a `create` that overloaded
-- would both show up here as a count of two.
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
