-- 0052 — an identity for the ingestion endpoint that can write the vault and
-- read nothing.
--
-- **The decision this encodes, because it reverses a piece of reasoning that is
-- written down elsewhere and was wrong.** `semantic/docs/KMS_DESIGN.md` argued
-- for hosting ingestion on AWS on the grounds that a Supabase edge function
-- would need a standing AWS key in its environment. True — and incomplete. A
-- Lambda cannot reach `semantic_private` either: RLS is on with no policy and
-- `authenticated` has no usage on the schema, so a write needs a Postgres
-- credential. Hosting on AWS does not remove the standing secret; it swaps
-- which one it is.
--
-- That matters because the two are not equivalent. A leaked encrypt-only KMS
-- key lets somebody write rubbish into the vault and decrypt nothing. A leaked
-- `service_role` key reads and writes every table in the project and bypasses
-- RLS entirely — it is the largest credential this project has. Putting *that*
-- in a second cloud to avoid a smaller one in the first is a bad trade.
--
-- So the endpoint does not get `service_role`. It gets this role, which can
-- call one function and nothing else.
--
-- **Why a `security definer` function rather than table grants plus policies.**
-- Every table in `semantic_private` has RLS on and no policy — a posture that
-- is uniform, states in one sentence, and is what the 71 `rls_enabled_no_policy`
-- advisor findings are confirming rather than complaining about. Granting this
-- role `insert` would mean adding the schema's first policies, and a posture
-- with two exceptions is one nobody can check at a glance. A function also
-- fixes the shape of what may be written, where a table grant would let the
-- caller set any column the triggers do not police.
--
-- **The password is not here, and that is deliberate.** The role is created
-- `nologin` with no password. Whoever deploys this runs, once, out of band:
--
--     alter role semantic_ingestor login password '<generated>';
--
-- and puts that password in AWS Secrets Manager. A secret in a migration is a
-- secret in git; `private.push_config` is filled in by hand for the same
-- reason. Until that statement is run the role cannot connect at all, so this
-- migration on its own grants nobody anything.
--
-- Ships no product behaviour. Nothing calls the function yet.

begin;

-- `create role` has no `if not exists`.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'semantic_ingestor') then
    create role semantic_ingestor nologin noinherit;
  end if;
end
$$;

-- Usage is needed to *call* a function in the schema. On its own it grants no
-- access to any table: without table privileges the role cannot select a row
-- even with RLS out of the picture, which the assertion at the foot checks.
grant usage on schema semantic_private to semantic_ingestor;

-- Nothing is granted on tables. Written as executable revokes rather than left
-- as an absence, so a later `grant ... on all tables in schema` — the trap
-- `0048` and `0050` both record, which binds at execution time — does not
-- silently widen this role. They are no-ops today by design; the assertion at
-- the foot is what actually checks the outcome.
revoke all on all tables in schema semantic_private from semantic_ingestor;
revoke all on all sequences in schema semantic_private from semantic_ingestor;
revoke all on schema ontology from semantic_ingestor;

-- Emphatically not the app's own schema, which holds the push secret and the
-- collaborator list. `0042`'s header prescribes checking this and the replay
-- harness checks it for the client roles; this role is new, so it is named.
revoke all on schema private from semantic_ingestor;

-- **`public` is deliberately not in that list, and the reason is worth writing
-- down because the obvious statement does not work.** `has_schema_privilege`
-- reports `usage = true` on `public` for this role and will keep doing so:
-- that privilege is granted to the `PUBLIC` pseudo-role, and revoking from one
-- named role cannot take away what everybody has. Revoking it from `PUBLIC`
-- would take it from `anon` and `authenticated` too and break the app.
--
-- Measured in production after this migration was applied, which is how the
-- misconception was found rather than shipped: usage `true`, readable tables
-- **0**. Schema usage on its own grants nothing — without a table privilege the
-- role cannot select a row — so the property that matters is the count, and
-- the count is what the assertion below reads.

-- ---------------------------------------------------------------------------

/*
 * The one thing the ingestion endpoint may do.
 *
 * `security definer`, so it runs as the owner and RLS does not apply — which
 * is the same mechanism `private.notify` uses and the reason neither needs a
 * policy. `search_path` is pinned and every name below is schema-qualified,
 * because a `security definer` function with a mutable search path is how a
 * caller who can create a table gets the definer to read theirs instead.
 *
 * **It takes `p_user_id` and does not derive it**, which is worth being blunt
 * about: this role can write vault rows for anybody. That is unavoidable for a
 * service identity — the endpoint is the thing that verified the caller's
 * Supabase access token and read `sub` out of it, and Postgres has no way to
 * re-check that. What the role cannot do is read any of it back.
 *
 * Idempotent by construction. `raw_source_records_active_fingerprint_v031_idx`
 * is a partial unique index on (user_id, source_code, record_fingerprint) where
 * the row is active, so a retry after a dropped connection stores nothing the
 * first attempt already stored. The partial predicate has to be repeated in the
 * `on conflict` clause for Postgres to infer that index — omit it and the
 * statement fails to plan rather than silently doing something else.
 */
create or replace function semantic_private.ingest_source_records_v031(
  p_user_id uuid,
  p_ingestion_run_id uuid,
  p_connector_source_code text,
  p_connector_version text,
  p_input_hash text,
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
  received integer;
  stored integer;
begin
  if p_user_id is null or p_ingestion_run_id is null then
    raise exception 'user and ingestion run are required'
      using errcode = 'null_value_not_allowed';
  end if;
  if jsonb_typeof(p_records) is distinct from 'array' then
    raise exception 'records must be a json array, got %', jsonb_typeof(p_records)
      using errcode = 'invalid_parameter_value';
  end if;

  -- Open the run, or adopt the one a previous attempt opened. `on conflict do
  -- nothing` rather than an upsert: a run's connector and owner are facts about
  -- the attempt and must not be rewritten by a later call claiming otherwise.
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

  -- **The check that makes a client-minted run id safe.** The endpoint lets the
  -- device choose the id so a retry resumes rather than opening a second run;
  -- without this, choosing somebody else's id would append to their run.
  if existing_user is distinct from p_user_id
     or existing_connector is distinct from p_connector_source_code then
    raise exception 'ingestion run % belongs to a different user or connector',
      p_ingestion_run_id
      using errcode = 'insufficient_privilege';
  end if;

  -- A finalized run has already had its membership, coverage and tombstones
  -- decided by `finalize_ingestion_run_v031`. Adding rows afterwards would make
  -- that decision wrong with nothing to notice it.
  if existing_status is distinct from 'running' then
    raise exception 'ingestion run % is % and cannot accept records',
      p_ingestion_run_id, existing_status
      using errcode = 'object_not_in_prerequisite_state';
  end if;

  select count(*) into received from jsonb_array_elements(p_records);

  with incoming as (
    select
      element ->> 'record_source_code' as source_code,
      element ->> 'data_type' as data_type,
      (element ->> 'occurred_at')::timestamptz as occurred_at,
      element ->> 'source_item_hmac' as source_item_hmac,
      element ->> 'record_fingerprint' as record_fingerprint,
      element ->> 'encryption_key_version' as encryption_key_version,
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
      incoming.record_fingerprint, incoming.encryption_key_version,
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
    'duplicates', received - stored
  );
end
$$;

-- A function is executable by `public` unless told otherwise, and this one runs
-- as its owner. The revoke is the whole of the access control.
revoke all on function semantic_private.ingest_source_records_v031(
  uuid, uuid, text, text, text, jsonb
) from public, anon, authenticated, service_role;

grant execute on function semantic_private.ingest_source_records_v031(
  uuid, uuid, text, text, text, jsonb
) to semantic_ingestor;

comment on function semantic_private.ingest_source_records_v031(
  uuid, uuid, text, text, text, jsonb
) is
  'The only thing semantic_ingestor may do. Writes encrypted vault rows for a '
  'user the endpoint has already authenticated; reads nothing back. Idempotent '
  'on (user_id, source_code, record_fingerprint) for active rows.';

-- ---------------------------------------------------------------------------

/*
 * The one connector that legitimately delivers another source's records.
 *
 * `0048` seeded `connector_record_source_matrix` with identity rows only, so
 * every cross pair is refused until somebody writes down why it is allowed.
 * Exactly one is real, and it was found by running the function rather than by
 * reading the distillers: `AppleMusicDistiller` emits a row with
 * `source: "user"` — whether the person has an Apple Music subscription, which
 * is discovered while talking to Apple Music and is a fact about the account
 * rather than about the music. Without this row that record is refused at
 * ingestion with `connector apple_music may not deliver user records`, which is
 * the guard working correctly and the data never arriving.
 *
 * This is the shape `0048` intended: the pair is *possible* and must be
 * *declared*. Note what it does not do — the record is still stored as `user`
 * evidence, not as Apple Music evidence, which is the provenance defect `0048`
 * exists to fix.
 */
insert into semantic_private.connector_record_source_matrix (
  connector_source_code, record_source_code, rationale
)
values (
  'apple_music', 'user',
  'AppleMusicDistiller reports subscription state as a user record: a fact '
  'about the account, discovered during an Apple Music run. Stored as user '
  'evidence, never as listening evidence.'
)
on conflict (connector_source_code, record_source_code) do nothing;

-- ---------------------------------------------------------------------------

-- Assert the shape rather than trusting the statements above, in the manner
-- `0051` asserts its two patterns match: read the catalog at migration time and
-- raise if it disagrees. A revoke that silently did nothing is exactly the kind
-- of thing that is discovered later, by someone reading a table they should not
-- have been able to reach.
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
     and pg_catalog.has_function_privilege(
           'semantic_ingestor', p.oid, 'execute');

  if callable <> 1 then
    raise exception
      'semantic_ingestor should be able to call exactly one function, can call %',
      callable;
  end if;
end
$$;

commit;
