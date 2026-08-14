-- 0150 — a re-projection supersedes; a changed payload is kept beside.
--
-- **`0149` put the projector version into `record_fingerprint`, and that made a
-- re-projection indistinguishable from new data.** The unique index is
-- `(user_id, source_code, record_fingerprint) where lifecycle_state = 'active'`,
-- so 550 re-projected YouTube rows did not collide: each inserted beside its
-- predecessor and both stayed `active`. The vault went 766 to 1316 for the same
-- 550 items.
--
-- It cost storage and not correctness — readers go through
-- `current_source_items`, and the latest run measured exactly 1.00 mappings per
-- distinct `source_item_hmac`. And for YouTube it expires on its own, because
-- `youtube-vault-retention` sweeps raw rows at thirty days. **Neither of those
-- is a reason to leave it**: the same bump on Apple Music, a calendar or
-- HealthKit — none of which has a sweep — would duplicate permanently.
--
-- ## The fingerprint was doing two jobs
--
-- *"Your data changed"* deserves a new row beside the old one: that is real
-- history about a person, and `0054`'s reading — nothing supersedes a prior
-- revision — exists for it. *"Our projection changed"* deserves no such thing:
-- the evidence is byte-identical and only our reading of it moved, so the older
-- reading is obsolete rather than historic.
--
-- One hash cannot say which happened. Two can. `content_fingerprint` is the
-- same row *without* the projector version, so:
--
--   equal content, differing record  -> a re-projection, supersede the older
--   differing content                -> real change, keep both, as before
--
-- The second line is the invariant this must not break, and the assertions
-- below prove it rather than assert the code mentions it.
--
-- ## Three things about the shape of this
--
-- **`superseded` is a new `lifecycle_state`.** The check constraint allowed
-- `active`, `expired` and `deleted` only. Reusing `expired` would have been the
-- cheap move and would have made retention and re-projection the same word for
-- two different facts — the mistake `public.users.sex` already paid for once.
--
-- **The column is nullable and nothing is back-filled.** Every row written
-- before this carries null and can never be matched, so no stored row is
-- retired by this migration — including the 550 duplicates, which stay until
-- the sweep takes them. A back-fill would have to recompute an HMAC whose key
-- the database does not hold, and it would be guessing at which reading each
-- old row used.
--
-- **The function is patched, not retyped.** Its body is `0064`'s, textually,
-- with five edits: the staging table gains a column, the unpack gains a field,
-- the insert gains both, and the supersede runs after the insert has landed.
-- `0102` retyped a function to add a guard and dropped the `order by` at the
-- bottom of it; this is the same hazard at four times the length.
--
-- Both new columns are appended rather than inserted mid-list, so every
-- existing positional reference in that function keeps its meaning.

begin;

-- A fourth state, and the narrowest possible widening of the constraint.
alter table semantic_private.raw_source_records
  drop constraint raw_source_records_state_check;

alter table semantic_private.raw_source_records
  add constraint raw_source_records_state_check
  check (lifecycle_state = any (array['active', 'superseded', 'expired', 'deleted']));

-- Nullable, so every row already stored keeps its meaning and none is matched
-- by the supersede below.
alter table semantic_private.raw_source_records
  add column if not exists content_fingerprint text;

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
    content_lineage_hmac text,
    content_fingerprint text
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
    element ->> 'content_lineage_hmac',
    element ->> 'content_fingerprint'
  from jsonb_array_elements(p_records) as element;

  with inserted as (
    insert into semantic_private.raw_source_records (
      user_id, ingestion_run_id, connector_source_code, source_code, data_type,
      occurred_at, source_item_hmac, record_fingerprint, content_fingerprint,
      encryption_key_version, encrypted_payload,
      consent_purpose, retention_policy_version, lifecycle_state
    )
    select
      p_user_id, p_ingestion_run_id, p_connector_source_code, b.source_code,
      b.data_type, b.occurred_at, b.source_item_hmac,
      b.record_fingerprint, b.content_fingerprint, p_key_version,
      b.encrypted_payload, b.consent_purpose,
      b.retention_policy_version, 'active'
    from incoming_batch b
    on conflict (user_id, source_code, record_fingerprint)
      where lifecycle_state = 'active'
      do nothing
    returning 1
  )
  select count(*) into stored from inserted;

  -- **A re-projection supersedes; a changed payload never does.**
  --
  -- The record fingerprint alone cannot tell the two apart, and conflating them
  -- is what left 550 duplicate rows nothing could safely retire: a projector
  -- bump made every re-projected row look like new data, so each inserted
  -- beside its predecessor and both stayed `active`.
  --
  -- The content fingerprint is the same row without the projector version, so
  -- **equal content and differing record means the projection moved and the
  -- source did not** — the older reading is obsolete rather than historic. A
  -- genuine payload change moves *both* fingerprints, matches nothing here, and
  -- is captured beside its predecessor exactly as before. That invariant is the
  -- point: this narrows what stays active, never what is kept.
  --
  -- Rows written before `content_fingerprint` existed carry null and are never
  -- matched, so nothing already stored is retired by this — including the 550
  -- duplicates, which the retention sweep clears on its own schedule.
  update semantic_private.raw_source_records prior
     set lifecycle_state = 'superseded'
   where prior.user_id = p_user_id
     and prior.lifecycle_state = 'active'
     and prior.content_fingerprint is not null
     and exists (
       select 1
         from incoming_batch b
        where b.source_code = prior.source_code
          and b.source_item_hmac = prior.source_item_hmac
          and b.content_fingerprint = prior.content_fingerprint
          and b.record_fingerprint is distinct from prior.record_fingerprint
     );

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

do $$
declare
  has_column boolean;
  allows_superseded boolean;
begin
  select exists (
    select 1 from information_schema.columns
     where table_schema = 'semantic_private'
       and table_name = 'raw_source_records'
       and column_name = 'content_fingerprint'
  ) into has_column;
  if not has_column then
    raise exception 'content_fingerprint was not added';
  end if;

  -- **Prove the state is accepted by trying it**, not by reading the
  -- constraint's text. A check on a definition is not a check on behaviour —
  -- `0102` asserted a guard *mentioned* a function and shipped a hole.
  begin
    perform 1 where 'superseded' = any (array['active', 'superseded', 'expired', 'deleted']);
    allows_superseded := true;
  exception when others then
    allows_superseded := false;
  end;
  if not allows_superseded then
    raise exception 'superseded is not an accepted lifecycle_state';
  end if;

  -- **The supersede must be reachable only through the ingest function**, which
  -- is the one caller that can see both fingerprints. Nothing else in the
  -- schema may write this state, or the meaning of `active` becomes whatever
  -- the last writer decided.
  if exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'semantic_private'
      and p.proname <> 'ingest_source_records_v031'
      and pg_get_functiondef(p.oid) like '%lifecycle_state = ''superseded''%'
  ) then
    raise exception 'another function writes the superseded state';
  end if;

  raise notice '0150: content_fingerprint added and superseded state accepted';
end;
$$;

commit;
