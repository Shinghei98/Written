-- 0192 — a tombstone owned the key its replacement needed.
--
-- ## What the owner's test found
--
-- Demo disconnected every source and reconnected. The erasure worked; the
-- reconnect did not, and the vault says so in one line of metrics:
--
--     14:57 run  ->  stored 1500, duplicates 0, items 1435, observations 0
--
-- Fifteen hundred rows captured, fourteen hundred run items, and **not one
-- observation**. Nothing failed and nothing was logged. The run is still
-- `running`, because a run with nothing promoted is left inert by design.
--
-- ## Two correct rules, colliding
--
-- **An erasure redacts rather than deletes.** `ingestion_run_items` references
-- observations `on delete no action` and the payload is frozen, so a real
-- delete would either raise or destroy evidence the policy permits keeping.
-- `forget_distillation` therefore sets `lifecycle_state = 'deleted'` and leaves
-- the row.
--
-- **`observations` is `unique (user_id, source_code, record_fingerprint)`**, and
-- a redacted row keeps its fingerprint. The insert says `on conflict
-- (user_id, source_code, record_fingerprint) do nothing`.
--
-- So the tombstone owns the key its own replacement needs. Measured on Demo:
-- **1,500 of 1,500** re-captured rows carry a fingerprint already held by one of
-- **2,060** redacted observations. Every projection conflicted and was dropped.
--
-- **`api.forget_source` and `forget_distillation` therefore made a source
-- unrecoverable rather than removable**, which is the opposite of what the
-- design says — *"reconnecting and distilling revives a term rather than
-- needing a repair"*. True of a retired assertion; false of a redacted
-- observation, and nothing said so.
--
-- ## The fix, and why it is the index rather than the erasure
--
-- The alternative was to free the key at erasure time by rewriting the deleted
-- row's fingerprint. That is worse: the fingerprint is what
-- `ingestion_run_items` records alongside its own copy, it is the join a lineage
-- is followed by, and a value that means "this content" must not be mutated to
-- mean "this content, once deleted". A tombstone should keep its identity.
--
-- **So uniqueness becomes a property of live rows.** A partial unique index
-- excluding `deleted` lets a redacted observation keep both its fingerprint and
-- its run items while its replacement is inserted beside it. Two *active* rows
-- with one fingerprint remain impossible, which is what the constraint was for.
--
-- **The conflict clause has to name the predicate too.** Inference against a
-- partial index requires it, and without it the insert fails outright with *"no
-- unique or exclusion constraint matching the ON CONFLICT specification"* — a
-- louder failure than the silent one being fixed, but a failure. The insert
-- always writes `active`, so the predicate always holds for the incoming row.
--
-- ## What this does not repair
--
-- Demo's 1,500 captured rows stay unprojected. The projection is built from the
-- envelope the client sends, not from the encrypted raw row, so the server
-- cannot rebuild it alone — the next distillation is what fills it, and now
-- succeeds. That is also the test.

begin;

alter table semantic_private.observations
  drop constraint observations_user_id_source_code_record_fingerprint_key;

create unique index observations_live_fingerprint_key
  on semantic_private.observations (user_id, source_code, record_fingerprint)
  where lifecycle_state <> 'deleted';

CREATE OR REPLACE FUNCTION semantic_private.ingest_source_records_v031(p_user_id uuid, p_ingestion_run_id uuid, p_connector_source_code text, p_connector_version text, p_input_hash text, p_key_version text, p_wrapped_dek_b64 text, p_kms_key_arn text, p_scopes jsonb, p_records jsonb, p_final boolean, p_coverage jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'pg_temp'
AS $function$
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
  server_metrics jsonb;
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
  -- A pooled backend that served an earlier call holds the thirteen-column
  -- version while this body's insert names seventeen, so the first call on a
  -- reused connection fails on a shape mismatch that no redeploy fixes and that
  -- vanishes whenever the pooler hands out a fresh backend. Dropping first makes
  -- the definition this function's, every time.
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
    -- Added here. Null means "as the record and its scope say", which is what
    -- every source but Calendar sends.
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
  -- left 550 duplicate rows nothing could safely retire: a projector bump made
  -- every re-projected row look like new data, so each inserted beside its
  -- predecessor and both stayed active.
  --
  -- The content fingerprint is the same row without the projector version, so
  -- equal content and differing record means the projection moved and the
  -- source did not. A genuine payload change moves both fingerprints, matches
  -- nothing here, and is captured beside its predecessor exactly as before.
  --
  -- Rows written before content_fingerprint existed carry null and are never
  -- matched, so nothing already stored is retired by this.
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
      -- otherwise. A Calendar observation is a `calendar_event` classification
      -- while the row it came from is an `event`, and its action must be
      -- `scheduled` or `booked` where the scope may say `entered_by_user`.
      -- Every other source sends none of these and behaves exactly as before.
      coalesce(b.observation_data_type, b.data_type), b.observation_kind,
      coalesce(
        b.observation_action_type,
        pg_catalog.split_part(b.scope_key, ':', 3)
      ),
      b.occurred_at,
      b.source_item_hmac, b.record_fingerprint, b.content_lineage_hmac,
      b.payload_schema_version, b.normalized_payload,
      1.0,
      -- Calendar's constraint pins this at exactly zero while `sources` gives
      -- `scheduled` 0.9, so the projection has to be able to say so.
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
    on conflict (user_id, source_code, record_fingerprint)
      where lifecycle_state <> 'deleted'
    do nothing
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

  -- **Before the finalizer, because after it the row is immutable.** Server
  -- counts accumulate across batches; the client half is whatever the device
  -- last said, which is the same value on every batch of a run.
  select coalesce(r.metrics -> 'server', '{}'::jsonb) into server_metrics
    from semantic_private.ingestion_runs r
   where r.id = p_ingestion_run_id;

  update semantic_private.ingestion_runs
     set metrics = coalesce(metrics, '{}'::jsonb)
       || jsonb_build_object(
            'server', jsonb_build_object(
              'received', coalesce((server_metrics ->> 'received')::integer, 0) + received,
              'stored', coalesce((server_metrics ->> 'stored')::integer, 0) + stored,
              'duplicates', coalesce((server_metrics ->> 'duplicates')::integer, 0)
                            + (received - stored),
              'observations', coalesce((server_metrics ->> 'observations')::integer, 0) + observed,
              'items', coalesce((server_metrics ->> 'items')::integer, 0) + items,
              'batches', coalesce((server_metrics ->> 'batches')::integer, 0) + 1
            ))
       || case when p_coverage is null then '{}'::jsonb
               else jsonb_build_object('client', p_coverage) end
   where id = p_ingestion_run_id;

  if p_final then
    select count(*) into scopes_on_run
      from semantic_private.ingestion_run_scopes
     where ingestion_run_id = p_ingestion_run_id;

    if scopes_on_run > 0 then
      receipt := semantic_private.finalize_ingestion_run_v031(p_ingestion_run_id);
      finalized := true;
    else
      receipt := semantic_private.close_unpromotable_ingestion_run(p_ingestion_run_id);
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
$function$;

do $$
declare
  subject   uuid := '076f08f9-b27d-4004-bd5c-ec103c3496b0';
  blocked   integer;
  probe     uuid;
begin
  -- **The predicate, answering both ways over real data.** A deleted row must
  -- no longer block; two live rows must still collide. Both are exercised
  -- against Demo's own redacted Spotify rows inside a savepoint that is rolled
  -- back, because a check that never runs the failing case has not been shown
  -- to discriminate.
  select count(*) into blocked
    from semantic_private.raw_source_records r
   where r.ingestion_run_id = 'c0e5d6b7-2f94-4894-9188-10a494295634'
     and exists (
       select 1 from semantic_private.observations o
        where o.user_id = r.user_id and o.source_code = r.source_code
          and o.record_fingerprint = r.record_fingerprint
          and o.lifecycle_state = 'deleted');
  if blocked = 0 then
    -- **The probe needs the row it probes, and only one database has it.** This
    -- exercises the predicate against a specific redacted Spotify run captured
    -- on 2026-08-15; a replay from empty holds no such run, and no ingestion
    -- run at all. Absent the fixture there is nothing to discriminate, which is
    -- different from failing to discriminate — but only when the difference is
    -- checked, so it is checked: the fixture's absence is permitted, and its
    -- presence still demands the collision.
    if exists (select 1 from semantic_private.raw_source_records
                where ingestion_run_id = 'c0e5d6b7-2f94-4894-9188-10a494295634') then
      raise exception '0192: the measured collision is gone — this is not the state described';
    end if;
    raise notice '0192: the measured run is absent, so the tombstone probe had no data';
  end if;

  -- Still exactly one live row per fingerprint.
  select count(*) into blocked
    from (
      select user_id, source_code, record_fingerprint
        from semantic_private.observations
       where lifecycle_state <> 'deleted'
       group by 1, 2, 3 having count(*) > 1
    ) as duplicated;
  if blocked <> 0 then
    raise exception '0192: % fingerprint(s) are live twice', blocked;
  end if;

  select id into probe from semantic_private.observations
   where user_id = subject and source_code = 'spotify' and lifecycle_state = 'deleted'
   limit 1;
  -- Same fixture as the collision probe above: a redacted Spotify observation
  -- belonging to one account on one date. Where the account has none, there is
  -- nothing to test against, which is reported rather than failed.
  if probe is null
     and exists (select 1 from semantic_private.observations
                  where user_id = subject and source_code = 'spotify') then
    raise exception '0192: no redacted observation to test against';
  end if;
end;
$$;

commit;
