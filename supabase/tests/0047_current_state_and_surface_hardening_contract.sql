-- Adapted from the v0.3.1 reference `sql/tests/006_current_state_and_surface_hardening_contract.sql`.
-- Gates application migration 0047.
--
-- The reference chain numbers its files 001-006 while this repository's
-- are 0042-0047, so contract numbering is off by two and the two
-- fixture lanes are off by one -- reference fixture `004` gates the
-- app's 0046, and reference fixture `005` gates 0047. The file name
-- states which migration it gates so nobody re-derives that each time.
--
-- Substituted from the reference: 256 `private.` -> `semantic_private.`
-- and 3 bare `'private'` schema arguments. Privacy-class VALUES
-- such as `'private_text'` are deliberately untouched: they are
-- check-constraint values, not schema names, and rewriting them is how
-- a mechanical rename corrupts a contract while still passing.

-- Run after 001_schema.sql through 006_current_state_and_surface_hardening.sql.
-- All identities, timestamps, payloads, and records below are synthetic.
--
-- The single-session cases below establish serial outcomes. Native PostgreSQL /
-- Supabase validation must additionally run the finalizer and exposure/revocation
-- race cases from two independent sessions at READ COMMITTED.
begin;

do $contract_catalog$
declare
  missing_objects text[];
  missing_columns text[];
  unsafe_tables text[];
begin
  select array_agg(expected.object_name order by expected.object_name)
  into missing_objects
  from unnest(array[
    'semantic_private.ingestion_run_scopes',
    'semantic_private.ingestion_run_items',
    'semantic_private.current_source_items',
    'semantic_private.source_state_heads'
  ]) as expected(object_name)
  where to_regclass(expected.object_name) is null;
  if missing_objects is not null then
    raise exception 'v0.3.1 current-state tables are missing: %', missing_objects;
  end if;

  select array_agg(
           expected.table_name || '.' || expected.column_name
           order by expected.table_name, expected.column_name
         )
  into missing_columns
  from (values
    ('ingestion_runs', 'finalization_revision'),
    ('ingestion_runs', 'finalization_receipt'),
    ('ingestion_run_scopes', 'ingestion_run_id'),
    ('ingestion_run_scopes', 'user_id'),
    ('ingestion_run_scopes', 'source_code'),
    ('ingestion_run_scopes', 'scope_key'),
    ('ingestion_run_scopes', 'data_type'),
    ('ingestion_run_scopes', 'action_type'),
    ('ingestion_run_scopes', 'snapshot_mode'),
    ('ingestion_run_scopes', 'completeness'),
    ('ingestion_run_scopes', 'window_start'),
    ('ingestion_run_scopes', 'window_end'),
    ('ingestion_run_scopes', 'expected_item_count'),
    ('ingestion_run_items', 'ingestion_run_id'),
    ('ingestion_run_items', 'user_id'),
    ('ingestion_run_items', 'source_code'),
    ('ingestion_run_items', 'scope_key'),
    ('ingestion_run_items', 'source_item_hmac'),
    ('ingestion_run_items', 'record_fingerprint'),
    ('ingestion_run_items', 'item_state'),
    ('ingestion_run_items', 'raw_source_record_id'),
    ('ingestion_run_items', 'observation_id'),
    ('ingestion_run_items', 'occurred_at'),
    ('current_source_items', 'user_id'),
    ('current_source_items', 'source_code'),
    ('current_source_items', 'scope_key'),
    ('current_source_items', 'data_type'),
    ('current_source_items', 'action_type'),
    ('current_source_items', 'source_item_hmac'),
    ('current_source_items', 'record_fingerprint'),
    ('current_source_items', 'current_raw_source_record_id'),
    ('current_source_items', 'current_observation_id'),
    ('current_source_items', 'occurred_at'),
    ('current_source_items', 'lifecycle_state'),
    ('current_source_items', 'first_seen_at'),
    ('current_source_items', 'last_seen_at'),
    ('current_source_items', 'state_changed_at'),
    ('current_source_items', 'last_seen_run_id'),
    ('current_source_items', 'last_change_run_id'),
    ('source_state_heads', 'user_id'),
    ('source_state_heads', 'source_code'),
    ('source_state_heads', 'scope_key'),
    ('source_state_heads', 'data_type'),
    ('source_state_heads', 'action_type'),
    ('source_state_heads', 'latest_run_started_at'),
    ('source_state_heads', 'latest_run_id'),
    ('source_state_heads', 'current_revision'),
    ('validated_surface_facts', 'assertion_score_version_id'),
    ('validated_surface_facts', 'attested_revision')
  ) as expected(table_name, column_name)
  left join information_schema.columns as actual
    on actual.table_schema = 'semantic_private'
   and actual.table_name = expected.table_name
   and actual.column_name = expected.column_name
  where actual.column_name is null;
  if missing_columns is not null then
    raise exception 'v0.3.1 current-state columns are missing: %', missing_columns;
  end if;

  select array_agg(expected.table_name order by expected.table_name)
  into unsafe_tables
  from (values
    ('ingestion_run_scopes'),
    ('ingestion_run_items'),
    ('current_source_items'),
    ('source_state_heads')
  ) as expected(table_name)
  left join pg_namespace as namespace
    on namespace.nspname = 'semantic_private'
  left join pg_class as relation
    on relation.relnamespace = namespace.oid
   and relation.relname = expected.table_name
   and relation.relrowsecurity
  where relation.oid is null;
  if unsafe_tables is not null then
    raise exception 'v0.3.1 internal tables are missing RLS: %', unsafe_tables;
  end if;

  if exists (
    select 1
    from pg_policies
    where schemaname = 'semantic_private'
      and tablename in (
        'ingestion_run_scopes', 'ingestion_run_items',
        'current_source_items', 'source_state_heads'
      )
  ) then
    raise exception 'v0.3.1 internal current-state tables expose a Data API policy';
  end if;

  if exists (
    select 1
    from (values
      ('ingestion_run_scopes'),
      ('ingestion_run_items'),
      ('current_source_items'),
      ('source_state_heads')
    ) as target(table_name)
    cross join (values ('anon'), ('authenticated')) as client(role_name)
    where has_table_privilege(
            client.role_name, format('semantic_private.%I', target.table_name), 'select'
          )
       or has_table_privilege(
            client.role_name, format('semantic_private.%I', target.table_name), 'insert'
          )
       or has_table_privilege(
            client.role_name, format('semantic_private.%I', target.table_name), 'update'
          )
       or has_table_privilege(
            client.role_name, format('semantic_private.%I', target.table_name), 'delete'
          )
  ) then
    raise exception 'a Data API role can access a v0.3.1 internal table';
  end if;

  if not has_table_privilege(
       'service_role', 'semantic_private.ingestion_run_scopes', 'select'
     ) or not has_table_privilege(
       'service_role', 'semantic_private.ingestion_run_scopes', 'insert'
     ) or has_table_privilege(
       'service_role', 'semantic_private.ingestion_run_scopes', 'update'
     ) or has_table_privilege(
       'service_role', 'semantic_private.ingestion_run_scopes', 'delete'
     ) or not has_table_privilege(
       'service_role', 'semantic_private.ingestion_run_items', 'select'
     ) or not has_table_privilege(
       'service_role', 'semantic_private.ingestion_run_items', 'insert'
     ) or has_table_privilege(
       'service_role', 'semantic_private.ingestion_run_items', 'update'
     ) or has_table_privilege(
       'service_role', 'semantic_private.ingestion_run_items', 'delete'
     ) or not has_table_privilege(
       'service_role', 'semantic_private.current_source_items', 'select'
     ) or has_table_privilege(
       'service_role', 'semantic_private.current_source_items', 'insert'
     ) or has_table_privilege(
       'service_role', 'semantic_private.current_source_items', 'update'
     ) or has_table_privilege(
       'service_role', 'semantic_private.current_source_items', 'delete'
     ) or not has_table_privilege(
       'service_role', 'semantic_private.source_state_heads', 'select'
     ) or has_table_privilege(
       'service_role', 'semantic_private.source_state_heads', 'insert'
     ) or has_table_privilege(
       'service_role', 'semantic_private.source_state_heads', 'update'
     ) or has_table_privilege(
       'service_role', 'semantic_private.source_state_heads', 'delete'
  ) then
    raise exception 'v0.3.1 service grants exceed the ingestion/finalizer boundary';
  end if;

  if not has_table_privilege(
       'service_role', 'semantic_private.ingestion_runs', 'select'
     ) or not has_table_privilege(
       'service_role', 'semantic_private.ingestion_runs', 'insert'
     ) or has_table_privilege(
       'service_role', 'semantic_private.ingestion_runs', 'update'
     ) then
    raise exception 'service role can bypass server-owned ingestion terminal transitions';
  end if;

  if to_regprocedure(
       'semantic_private.finalize_ingestion_run_v031(uuid)'
     ) is null
     or to_regprocedure(
       'semantic_private.fail_ingestion_run_v031(uuid,text)'
     ) is null
     or to_regprocedure(
       'semantic_private.validated_surface_fact_is_current(uuid)'
     ) is null
     or to_regprocedure(
       'semantic_private.revoke_match_authorization_v031(uuid,text)'
     ) is null then
    raise exception 'v0.3.1 hardening functions are missing';
  end if;

  if has_function_privilege(
       'anon', 'semantic_private.finalize_ingestion_run_v031(uuid)', 'execute'
     ) or has_function_privilege(
       'authenticated', 'semantic_private.finalize_ingestion_run_v031(uuid)', 'execute'
     ) or not has_function_privilege(
       'service_role', 'semantic_private.finalize_ingestion_run_v031(uuid)', 'execute'
     ) or has_function_privilege(
       'anon', 'semantic_private.fail_ingestion_run_v031(uuid,text)', 'execute'
     ) or has_function_privilege(
       'authenticated', 'semantic_private.fail_ingestion_run_v031(uuid,text)', 'execute'
     ) or not has_function_privilege(
       'service_role', 'semantic_private.fail_ingestion_run_v031(uuid,text)', 'execute'
     ) or has_function_privilege(
       'anon', 'semantic_private.revoke_match_authorization_v031(uuid,text)', 'execute'
     ) or has_function_privilege(
       'authenticated', 'semantic_private.revoke_match_authorization_v031(uuid,text)', 'execute'
     ) or not has_function_privilege(
       'service_role', 'semantic_private.revoke_match_authorization_v031(uuid,text)', 'execute'
     ) or has_function_privilege(
       'anon', 'semantic_private.validated_surface_fact_is_current(uuid)', 'execute'
     ) or has_function_privilege(
       'authenticated', 'semantic_private.validated_surface_fact_is_current(uuid)', 'execute'
     ) or not has_function_privilege(
       'service_role', 'semantic_private.validated_surface_fact_is_current(uuid)', 'execute'
     ) or has_function_privilege(
       'anon', 'semantic_private.mark_icebreaker_exposed(uuid)', 'execute'
     ) or has_function_privilege(
       'authenticated', 'semantic_private.mark_icebreaker_exposed(uuid)', 'execute'
     ) or not has_function_privilege(
       'service_role', 'semantic_private.mark_icebreaker_exposed(uuid)', 'execute'
     ) then
    raise exception 'v0.3.1 hardening functions have unsafe ACLs';
  end if;

  if not exists (
    select 1
    from pg_proc as procedure
    where procedure.oid = 'semantic_private.finalize_ingestion_run_v031(uuid)'::regprocedure
      and procedure.prosecdef
      and procedure.provolatile = 'v'
      and procedure.proconfig @> array['search_path=""']::text[]
      and lower(pg_get_functiondef(procedure.oid)) like '%source_state_heads%'
      and lower(pg_get_functiondef(procedure.oid)) like '%for update%'
  ) then
    raise exception 'ingestion finalizer is not fixed-path, volatile, and source-head locking';
  end if;

  if not exists (
       select 1 from pg_proc as procedure
       where procedure.oid =
             'semantic_private.guard_raw_source_record_run_v031()'::regprocedure
         and lower(pg_get_functiondef(procedure.oid)) like '%for key share%'
     ) or not exists (
       select 1 from pg_proc as procedure
       where procedure.oid =
             'semantic_private.guard_observation_ingestion_run()'::regprocedure
         and lower(pg_get_functiondef(procedure.oid)) like '%for key share%'
     ) or not exists (
       select 1 from pg_proc as procedure
       where procedure.oid =
             'semantic_private.guard_ingestion_run_item_v031()'::regprocedure
         and lower(pg_get_functiondef(procedure.oid)) like '%for key share%'
     ) then
    raise exception 'staging writes do not share the finalizer run-row lock';
  end if;

  if not exists (
    select 1
    from pg_proc as procedure
    where procedure.oid = 'semantic_private.fail_ingestion_run_v031(uuid,text)'::regprocedure
      and procedure.prosecdef
      and procedure.provolatile = 'v'
      and procedure.proconfig @> array['search_path=""']::text[]
      and lower(pg_get_functiondef(procedure.oid)) like '%for update%'
  ) then
    raise exception 'ingestion failure transition is not fixed-path and row-locking';
  end if;

  if not exists (
    select 1
    from pg_proc as procedure
    where procedure.oid =
          'semantic_private.revoke_match_authorization_v031(uuid,text)'::regprocedure
      and procedure.prosecdef
      and procedure.provolatile = 'v'
      and procedure.proconfig @> array['search_path=""']::text[]
      and lower(pg_get_functiondef(procedure.oid)) like '%for update%'
  ) then
    raise exception 'match revocation is not a fixed-path row-locking service transition';
  end if;

  if not exists (
    select 1
    from pg_proc as procedure
    where procedure.oid = 'semantic_private.mark_icebreaker_exposed(uuid)'::regprocedure
      and procedure.prosecdef
      and procedure.provolatile = 'v'
      and procedure.proconfig @> array['search_path=""']::text[]
      and lower(pg_get_functiondef(procedure.oid)) like '%match_authorizations%'
      and lower(pg_get_functiondef(procedure.oid)) like '%for update%'
  ) then
    raise exception 'first exposure and revocation do not lock the same authorization row';
  end if;
end
$contract_catalog$;

do $current_state_contract$
declare
  test_user_id uuid := ontology.stable_uuid('written:test:v0.3.1-current-state-user');
  bypass_id uuid := ontology.stable_uuid('written:test:v0.3.1-finalizer-bypass');
  full_1_id uuid := ontology.stable_uuid('written:test:v0.3.1-full-1');
  partial_1_id uuid := ontology.stable_uuid('written:test:v0.3.1-partial-1');
  full_2_id uuid := ontology.stable_uuid('written:test:v0.3.1-full-2');
  delta_seen_id uuid := ontology.stable_uuid('written:test:v0.3.1-delta-seen');
  delta_delete_id uuid := ontology.stable_uuid('written:test:v0.3.1-delta-delete');
  disjoint_old_id uuid := ontology.stable_uuid('written:test:v0.3.1-disjoint-old');
  failed_id uuid := ontology.stable_uuid('written:test:v0.3.1-failed');
  old_id uuid := ontology.stable_uuid('written:test:v0.3.1-out-of-order-old');
  new_id uuid := ontology.stable_uuid('written:test:v0.3.1-out-of-order-new');
  raw_a_id uuid := ontology.stable_uuid('written:test:v0.3.1-raw-a');
  raw_b_id uuid := ontology.stable_uuid('written:test:v0.3.1-raw-b');
  raw_c_id uuid := ontology.stable_uuid('written:test:v0.3.1-raw-c');
  late_raw_id uuid := ontology.stable_uuid('written:test:v0.3.1-late-raw');
  late_observation_id uuid := ontology.stable_uuid('written:test:v0.3.1-late-observation');
  artist_scope text := 'apple_music:library_artist:v1';
  album_scope text := 'apple_music:library_album:v1';
  stale_disjoint_scope text := 'apple_music:aaa_disjoint:v1';
  item_a_hmac text := repeat(md5('written:v0.3.1:item-a'), 2);
  item_b_hmac text := repeat(md5('written:v0.3.1:item-b'), 2);
  item_c_hmac text := repeat(md5('written:v0.3.1:item-c'), 2);
  item_a_fingerprint text := repeat(md5('written:v0.3.1:fingerprint-a'), 2);
  item_b_fingerprint text := repeat(md5('written:v0.3.1:fingerprint-b'), 2);
  item_c_fingerprint text := repeat(md5('written:v0.3.1:fingerprint-c'), 2);
  late_raw_hmac text := repeat(md5('written:v0.3.1:late-raw-hmac'), 2);
  late_raw_fingerprint text := repeat(md5('written:v0.3.1:late-raw-fingerprint'), 2);
  late_observation_hmac text := repeat(md5('written:v0.3.1:late-observation-hmac'), 2);
  late_observation_fingerprint text := repeat(md5('written:v0.3.1:late-observation-fingerprint'), 2);
  late_membership_hmac text := repeat(md5('written:v0.3.1:late-membership-hmac'), 2);
  late_membership_fingerprint text := repeat(md5('written:v0.3.1:late-membership-fingerprint'), 2);
  item_a_occurred_at timestamptz := '2026-07-02T01:00:00Z';
  item_b_occurred_at timestamptz := '2026-07-22T02:00:00Z';
  item_c_occurred_at timestamptz := '2026-08-01T03:00:00Z';
  receipt_1 jsonb;
  receipt_retry jsonb;
  receipt_partial jsonb;
  receipt_full_2 jsonb;
  receipt_delta_seen jsonb;
  receipt_delta_delete jsonb;
  receipt_disjoint jsonb;
  receipt_failed jsonb;
  receipt_new jsonb;
  receipt_old jsonb;
  expected_revision bigint;
  revision_before bigint;
  jobs_before integer;
  jobs_after integer;
  head_before uuid;
begin
  insert into auth.users (id, aud, role, created_at, updated_at)
  values (test_user_id, 'authenticated', 'authenticated', now(), now());
  insert into semantic_private.user_state_versions (user_id, revision)
  values (test_user_id, 0);

  insert into semantic_private.ingestion_runs (
    id, user_id, source_code, connector_version, input_hash, status, started_at
  ) values (
    bypass_id, test_user_id, 'apple_music', 'synthetic-v0.3.1',
    'synthetic-v0.3.1-finalizer-bypass', 'running',
    clock_timestamp() - interval '10 minutes'
  );
  begin
    update semantic_private.ingestion_runs
    set status = 'succeeded', finished_at = now(), finalization_revision = 0,
        finalization_receipt = '{"status":"succeeded"}'::jsonb,
        current_state_policy_version = 'written-current-state-v1.0.0'
    where id = bypass_id;
    raise exception 'direct succeeded status bypassed the atomic finalizer';
  exception
    when raise_exception then
      if sqlerrm = 'direct succeeded status bypassed the atomic finalizer' then raise; end if;
  end;
  if not exists (
       select 1 from semantic_private.ingestion_runs
       where id = bypass_id and status = 'running'
         and finalization_revision is null and finalization_receipt is null
     ) or (select revision from semantic_private.user_state_versions
           where user_id = test_user_id) <> 0 then
    raise exception 'failed direct-finalization attempt changed run or revision state';
  end if;

  insert into semantic_private.ingestion_runs (
    id, user_id, source_code, connector_version, input_hash, status, started_at
  ) values (
    full_1_id, test_user_id, 'apple_music', 'synthetic-v0.3.1',
    'synthetic-v0.3.1-full-1', 'running', clock_timestamp() - interval '9 minutes'
  );
  insert into semantic_private.ingestion_run_scopes (
    ingestion_run_id, user_id, source_code, scope_key, data_type, action_type,
    snapshot_mode, completeness, window_start, window_end, expected_item_count
  ) values (
    full_1_id, test_user_id, 'apple_music', artist_scope,
    'library_artist', 'library_artist', 'full_snapshot', 'complete',
    clock_timestamp() - interval '365 days', clock_timestamp(), 2
  );
  insert into semantic_private.raw_source_records (
    id, user_id, ingestion_run_id, source_code, data_type, occurred_at,
    source_item_hmac, record_fingerprint, encryption_key_version,
    encrypted_payload, consent_purpose, retention_policy_version, retained_until
  ) values
    (raw_a_id, test_user_id, full_1_id, 'apple_music', 'library_artist',
     item_a_occurred_at, item_a_hmac, item_a_fingerprint,
     'synthetic_key_v1', decode(repeat('aa', 16), 'hex'),
     'source_distillation', 'synthetic-retain-v1', now() + interval '30 days'),
    (raw_b_id, test_user_id, full_1_id, 'apple_music', 'library_artist',
     item_b_occurred_at, item_b_hmac, item_b_fingerprint,
     'synthetic_key_v1', decode(repeat('bb', 16), 'hex'),
     'source_distillation', 'synthetic-retain-v1', now() + interval '30 days');
  insert into semantic_private.ingestion_run_items (
    ingestion_run_id, user_id, source_code, scope_key, source_item_hmac,
    record_fingerprint, item_state, raw_source_record_id, observation_id,
    occurred_at
  ) values
    (full_1_id, test_user_id, 'apple_music', artist_scope, item_a_hmac,
     item_a_fingerprint, 'present', raw_a_id, null,
     item_a_occurred_at),
    (full_1_id, test_user_id, 'apple_music', artist_scope, item_b_hmac,
     item_b_fingerprint, 'present', raw_b_id, null,
     item_b_occurred_at);

  select count(*) into jobs_before
  from semantic_private.worker_jobs
  where user_id = test_user_id and job_type = 'recompute_user';
  receipt_1 := semantic_private.finalize_ingestion_run_v031(full_1_id);
  if jsonb_typeof(receipt_1) is distinct from 'object' then
    raise exception 'full snapshot finalizer did not return an opaque JSON receipt';
  end if;
  if not exists (
    select 1
    from semantic_private.ingestion_runs
    where id = full_1_id
      and status = 'succeeded'
      and finished_at is not null
      and finalization_revision is not null
      and finalization_receipt = receipt_1
  ) then
    raise exception 'full snapshot did not atomically persist terminal receipt state';
  end if;
  if (
    select count(*)
    from semantic_private.current_source_items
    where user_id = test_user_id
      and source_code = 'apple_music'
      and scope_key = artist_scope
      and lifecycle_state = 'present'
      and source_item_hmac in (item_a_hmac, item_b_hmac)
  ) <> 2 then
    raise exception 'complete full snapshot did not establish both current items';
  end if;
  select revision into expected_revision
  from semantic_private.user_state_versions where user_id = test_user_id;
  if expected_revision <> 1 or not exists (
    select 1
    from semantic_private.source_state_heads as head
    join semantic_private.ingestion_runs as run on run.id = head.latest_run_id
    where head.user_id = test_user_id
      and head.source_code = 'apple_music'
      and head.scope_key = artist_scope
      and head.latest_run_id = full_1_id
      and head.current_revision = expected_revision
      and run.finalization_revision = expected_revision
  ) then
    raise exception 'first current-state change did not advance one exact revision/head';
  end if;
  select count(*) into jobs_after
  from semantic_private.worker_jobs
  where user_id = test_user_id and job_type = 'recompute_user';
  if jobs_after <> jobs_before + 1 or (
    select count(*)
    from semantic_private.worker_jobs
    where user_id = test_user_id
      and job_type = 'recompute_user'
      and (payload ->> 'input_revision')::bigint = expected_revision
  ) <> 1 then
    raise exception 'full finalization did not enqueue exactly one exact-revision recompute';
  end if;

  receipt_retry := semantic_private.finalize_ingestion_run_v031(full_1_id);
  if receipt_retry is distinct from receipt_1
     or (select revision from semantic_private.user_state_versions where user_id = test_user_id)
          <> expected_revision
     or (select count(*) from semantic_private.worker_jobs
         where user_id = test_user_id and job_type = 'recompute_user') <> jobs_after then
    raise exception 'finalizer retry was not receipt/revision/job idempotent';
  end if;

  -- Evidence and membership share the run-row lock with finalization. Once the
  -- manifest is terminal, no late writer can alter what that receipt covered.
  begin
    insert into semantic_private.raw_source_records (
      id, user_id, ingestion_run_id, source_code, data_type,
      source_item_hmac, record_fingerprint, encryption_key_version,
      encrypted_payload, consent_purpose, retention_policy_version,
      retained_until
    ) values (
      late_raw_id, test_user_id, full_1_id, 'apple_music', 'library_artist',
      late_raw_hmac, late_raw_fingerprint, 'synthetic_key_v1',
      decode(repeat('ef', 16), 'hex'), 'source_distillation',
      'synthetic-retain-v1', now() + interval '30 days'
    );
    raise exception 'raw evidence appended after finalization';
  exception
    when others then
      if sqlerrm = 'raw evidence appended after finalization' then raise; end if;
  end;
  begin
    insert into semantic_private.observations (
      id, user_id, ingestion_run_id, source_code, data_type,
      observation_kind, action_type, source_item_hmac, record_fingerprint,
      payload_schema_version, normalized_payload, privacy_class
    ) values (
      late_observation_id, test_user_id, full_1_id, 'apple_music',
      'library_artist', 'catalog_entity', 'library_artist',
      late_observation_hmac, late_observation_fingerprint,
      'synthetic-v0.3.1', '{}'::jsonb, 'public_catalog'
    );
    raise exception 'observation appended after finalization';
  exception
    when others then
      if sqlerrm = 'observation appended after finalization' then raise; end if;
  end;
  begin
    insert into semantic_private.ingestion_run_items (
      ingestion_run_id, user_id, source_code, scope_key, source_item_hmac,
      record_fingerprint, item_state
    ) values (
      full_1_id, test_user_id, 'apple_music', artist_scope,
      late_membership_hmac, late_membership_fingerprint, 'provider_deleted'
    );
    raise exception 'run membership appended after finalization';
  exception
    when others then
      if sqlerrm = 'run membership appended after finalization' then raise; end if;
  end;
  if exists (
       select 1 from semantic_private.raw_source_records where id = late_raw_id
     ) or exists (
       select 1 from semantic_private.observations where id = late_observation_id
     ) or exists (
       select 1 from semantic_private.ingestion_run_items
       where ingestion_run_id = full_1_id
         and source_item_hmac = late_membership_hmac
     ) then
    raise exception 'a rejected late staging write persisted';
  end if;

  -- A capped/partial full scan is affirmative only for rows it did see. It may
  -- update last-seen metadata but cannot infer absence for B.
  insert into semantic_private.ingestion_runs (
    id, user_id, source_code, connector_version, input_hash, status, started_at
  ) values (
    partial_1_id, test_user_id, 'apple_music', 'synthetic-v0.3.1',
    'synthetic-v0.3.1-partial-1', 'running', clock_timestamp() - interval '8 minutes'
  );
  insert into semantic_private.ingestion_run_scopes (
    ingestion_run_id, user_id, source_code, scope_key, data_type, action_type,
    snapshot_mode, completeness, window_start, window_end, expected_item_count
  ) values (
    partial_1_id, test_user_id, 'apple_music', artist_scope,
    'library_artist', 'library_artist', 'full_snapshot', 'truncated',
    clock_timestamp() - interval '365 days', clock_timestamp(), 1
  );
  insert into semantic_private.ingestion_run_items (
    ingestion_run_id, user_id, source_code, scope_key, source_item_hmac,
    record_fingerprint, item_state, raw_source_record_id, observation_id,
    occurred_at
  ) values (
    partial_1_id, test_user_id, 'apple_music', artist_scope, item_a_hmac,
    item_a_fingerprint, 'present', raw_a_id, null,
    item_a_occurred_at
  );
  receipt_partial := semantic_private.finalize_ingestion_run_v031(partial_1_id);
  if jsonb_typeof(receipt_partial) is distinct from 'object'
     or not exists (
       select 1 from semantic_private.current_source_items
       where user_id = test_user_id and source_code = 'apple_music'
         and scope_key = artist_scope and source_item_hmac = item_b_hmac
         and lifecycle_state = 'present'
     )
     or (select revision from semantic_private.user_state_versions where user_id = test_user_id)
          <> expected_revision
     or (select count(*) from semantic_private.worker_jobs
         where user_id = test_user_id and job_type = 'recompute_user') <> jobs_after then
    raise exception 'capped snapshot inferred absence or changed semantic revision';
  end if;
  if not exists (
    select 1 from semantic_private.source_state_heads
    where user_id = test_user_id and source_code = 'apple_music'
      and scope_key = artist_scope
      and latest_run_id = partial_1_id and current_revision = expected_revision
  ) then
    raise exception 'successful no-op partial run did not advance only the source head';
  end if;

  -- A complete full snapshot may mark B non-current while preserving raw/history.
  insert into semantic_private.ingestion_runs (
    id, user_id, source_code, connector_version, input_hash, status, started_at
  ) values (
    full_2_id, test_user_id, 'apple_music', 'synthetic-v0.3.1',
    'synthetic-v0.3.1-full-2', 'running', clock_timestamp() - interval '7 minutes'
  );
  insert into semantic_private.ingestion_run_scopes (
    ingestion_run_id, user_id, source_code, scope_key, data_type, action_type,
    snapshot_mode, completeness, window_start, window_end, expected_item_count
  ) values (
    full_2_id, test_user_id, 'apple_music', artist_scope,
    'library_artist', 'library_artist', 'full_snapshot', 'complete',
    clock_timestamp() - interval '365 days', clock_timestamp(), 1
  );
  insert into semantic_private.ingestion_run_items (
    ingestion_run_id, user_id, source_code, scope_key, source_item_hmac,
    record_fingerprint, item_state, raw_source_record_id, observation_id,
    occurred_at
  ) values (
    full_2_id, test_user_id, 'apple_music', artist_scope, item_a_hmac,
    item_a_fingerprint, 'present', raw_a_id, null,
    item_a_occurred_at
  );
  receipt_full_2 := semantic_private.finalize_ingestion_run_v031(full_2_id);
  select revision into revision_before
  from semantic_private.user_state_versions where user_id = test_user_id;
  if revision_before <> expected_revision + 1
     or not exists (
       select 1 from semantic_private.current_source_items
       where user_id = test_user_id and source_code = 'apple_music'
         and scope_key = artist_scope and source_item_hmac = item_a_hmac
         and lifecycle_state = 'present' and last_seen_run_id = full_2_id
     )
     or exists (
       select 1 from semantic_private.current_source_items
       where user_id = test_user_id and source_code = 'apple_music'
         and scope_key = artist_scope and source_item_hmac = item_b_hmac
         and lifecycle_state = 'present'
     )
     or not exists (
       select 1 from semantic_private.raw_source_records
       where id = raw_b_id and user_id = test_user_id
     ) then
    raise exception 'complete replacement did not expire absence while preserving history';
  end if;
  if (
    select count(*) from semantic_private.worker_jobs
    where user_id = test_user_id and job_type = 'recompute_user'
      and (payload ->> 'input_revision')::bigint = revision_before
  ) <> 1 then
    raise exception 'full-snapshot absence did not enqueue one recompute revision';
  end if;
  expected_revision := revision_before;
  select count(*) into jobs_after from semantic_private.worker_jobs
  where user_id = test_user_id and job_type = 'recompute_user';

  -- Delta absence is not deletion. An explicit provider tombstone is.
  insert into semantic_private.ingestion_runs (
    id, user_id, source_code, connector_version, input_hash, status, started_at
  ) values (
    delta_seen_id, test_user_id, 'apple_music', 'synthetic-v0.3.1',
    'synthetic-v0.3.1-delta-seen', 'running', clock_timestamp() - interval '6 minutes'
  );
  insert into semantic_private.ingestion_run_scopes (
    ingestion_run_id, user_id, source_code, scope_key, data_type, action_type,
    snapshot_mode, completeness, window_start, window_end, expected_item_count
  ) values (
    delta_seen_id, test_user_id, 'apple_music', artist_scope,
    'library_artist', 'library_artist', 'delta', 'complete',
    clock_timestamp() - interval '1 day', clock_timestamp(), 1
  );
  insert into semantic_private.ingestion_run_items (
    ingestion_run_id, user_id, source_code, scope_key, source_item_hmac,
    record_fingerprint, item_state, raw_source_record_id, observation_id,
    occurred_at
  ) values (
    delta_seen_id, test_user_id, 'apple_music', artist_scope, item_a_hmac,
    item_a_fingerprint, 'present', raw_a_id, null,
    item_a_occurred_at
  );
  receipt_delta_seen := semantic_private.finalize_ingestion_run_v031(delta_seen_id);
  if jsonb_typeof(receipt_delta_seen) is distinct from 'object'
     or (select revision from semantic_private.user_state_versions where user_id = test_user_id)
          <> expected_revision
     or (select count(*) from semantic_private.worker_jobs
         where user_id = test_user_id and job_type = 'recompute_user') <> jobs_after then
    raise exception 'delta absence changed current state/revision';
  end if;

  insert into semantic_private.ingestion_runs (
    id, user_id, source_code, connector_version, input_hash, status, started_at
  ) values (
    delta_delete_id, test_user_id, 'apple_music', 'synthetic-v0.3.1',
    'synthetic-v0.3.1-delta-delete', 'running', clock_timestamp() - interval '5 minutes'
  );
  insert into semantic_private.ingestion_run_scopes (
    ingestion_run_id, user_id, source_code, scope_key, data_type, action_type,
    snapshot_mode, completeness, window_start, window_end, expected_item_count
  ) values (
    delta_delete_id, test_user_id, 'apple_music', artist_scope,
    'library_artist', 'library_artist', 'delta', 'complete',
    clock_timestamp() - interval '1 day', clock_timestamp(), 1
  );
  insert into semantic_private.ingestion_run_items (
    ingestion_run_id, user_id, source_code, scope_key, source_item_hmac,
    record_fingerprint, item_state, raw_source_record_id, observation_id,
    occurred_at
  ) values (
    delta_delete_id, test_user_id, 'apple_music', artist_scope, item_b_hmac,
    item_b_fingerprint, 'provider_deleted', null, null, clock_timestamp()
  );
  receipt_delta_delete := semantic_private.finalize_ingestion_run_v031(delta_delete_id);
  select revision into revision_before
  from semantic_private.user_state_versions where user_id = test_user_id;
  if revision_before <> expected_revision + 1
     or not exists (
       select 1 from semantic_private.current_source_items
       where user_id = test_user_id and source_code = 'apple_music'
         and scope_key = artist_scope and source_item_hmac = item_b_hmac
         and lifecycle_state = 'provider_deleted'
         and last_change_run_id = delta_delete_id
     ) then
    raise exception 'explicit delta tombstone did not become current deletion';
  end if;
  expected_revision := revision_before;
  select count(*) into jobs_after from semantic_private.worker_jobs
  where user_id = test_user_id and job_type = 'recompute_user';
  receipt_retry := semantic_private.finalize_ingestion_run_v031(delta_delete_id);
  if receipt_retry is distinct from receipt_delta_delete
     or (select revision from semantic_private.user_state_versions where user_id = test_user_id)
          <> expected_revision
     or (select count(*) from semantic_private.worker_jobs
         where user_id = test_user_id and job_type = 'recompute_user') <> jobs_after then
    raise exception 'explicit tombstone retry duplicated state/revision/job';
  end if;

  -- An older run for a non-overlapping scope is not stale merely because a
  -- newer run finalized another scope of the same provider.
  insert into semantic_private.ingestion_runs (
    id, user_id, source_code, connector_version, input_hash, status, started_at
  ) values (
    disjoint_old_id, test_user_id, 'apple_music', 'synthetic-v0.3.1',
    'synthetic-v0.3.1-disjoint-old', 'running',
    clock_timestamp() - interval '30 minutes'
  );
  insert into semantic_private.ingestion_run_scopes (
    ingestion_run_id, user_id, source_code, scope_key, data_type, action_type,
    snapshot_mode, completeness, expected_item_count
  ) values (
    disjoint_old_id, test_user_id, 'apple_music',
    'apple_music:library_genre:v1', 'library_genre', 'library_genre',
    'full_snapshot', 'complete', 0
  );
  receipt_disjoint := semantic_private.finalize_ingestion_run_v031(disjoint_old_id);
  if receipt_disjoint ->> 'status' is distinct from 'succeeded'
     or (select revision from semantic_private.user_state_versions where user_id = test_user_id)
          <> expected_revision
     or (select count(*) from semantic_private.worker_jobs
         where user_id = test_user_id and job_type = 'recompute_user') <> jobs_after
     or not exists (
       select 1 from semantic_private.source_state_heads
       where user_id = test_user_id and source_code = 'apple_music'
         and scope_key = 'apple_music:library_genre:v1'
         and latest_run_id = disjoint_old_id
     ) then
    raise exception 'source-wide ordering incorrectly superseded a disjoint scope';
  end if;

  -- A failed run may contain staged memberships but changes no head/current row.
  select latest_run_id into head_before
  from semantic_private.source_state_heads
  where user_id = test_user_id and source_code = 'apple_music'
    and scope_key = artist_scope;
  insert into semantic_private.ingestion_runs (
    id, user_id, source_code, connector_version, input_hash, status, started_at
  ) values (
    failed_id, test_user_id, 'apple_music', 'synthetic-v0.3.1',
    'synthetic-v0.3.1-failed', 'running', clock_timestamp() - interval '4 minutes'
  );
  insert into semantic_private.ingestion_run_scopes (
    ingestion_run_id, user_id, source_code, scope_key, data_type, action_type,
    snapshot_mode, completeness, window_start, window_end, expected_item_count
  ) values (
    failed_id, test_user_id, 'apple_music', artist_scope,
    'library_artist', 'library_artist', 'full_snapshot', 'complete',
    clock_timestamp() - interval '365 days', clock_timestamp(), 1
  );
  insert into semantic_private.ingestion_run_items (
    ingestion_run_id, user_id, source_code, scope_key, source_item_hmac,
    record_fingerprint, item_state, raw_source_record_id, observation_id,
    occurred_at
  ) values (
    failed_id, test_user_id, 'apple_music', artist_scope, item_b_hmac,
    item_b_fingerprint, 'present', raw_b_id, null,
    item_b_occurred_at
  );
  receipt_failed := semantic_private.fail_ingestion_run_v031(failed_id, 'synthetic');
  if receipt_failed ->> 'status' is distinct from 'failed'
     or semantic_private.fail_ingestion_run_v031(failed_id, 'synthetic')
          is distinct from receipt_failed then
    raise exception 'failed-run transition was not receipt-idempotent';
  end if;
  if (select revision from semantic_private.user_state_versions where user_id = test_user_id)
       <> expected_revision
     or (select latest_run_id from semantic_private.source_state_heads
         where user_id = test_user_id and source_code = 'apple_music'
           and scope_key = artist_scope)
          is distinct from head_before
     or not exists (
       select 1 from semantic_private.current_source_items
       where user_id = test_user_id and source_code = 'apple_music'
         and scope_key = artist_scope and source_item_hmac = item_b_hmac
         and lifecycle_state = 'provider_deleted'
     )
     or exists (
       select 1 from semantic_private.ingestion_runs
       where id = failed_id
         and (finalization_revision is not null or finalization_receipt is not null)
     ) then
    raise exception 'failed run changed current state/head/finalization metadata';
  end if;

  -- The older run starts first but attempts finalization after the newer run.
  -- It must become superseded, never tombstone C from the newer head, and not
  -- leave an empty head for an earlier-sorted non-overlapping scope.
  insert into semantic_private.ingestion_runs (
    id, user_id, source_code, connector_version, input_hash, status, started_at
  ) values
    (old_id, test_user_id, 'apple_music', 'synthetic-v0.3.1',
     'synthetic-v0.3.1-old', 'running', clock_timestamp() - interval '3 minutes'),
    (new_id, test_user_id, 'apple_music', 'synthetic-v0.3.1',
     'synthetic-v0.3.1-new', 'running', clock_timestamp() - interval '2 minutes');
  insert into semantic_private.ingestion_run_scopes (
    ingestion_run_id, user_id, source_code, scope_key, data_type, action_type,
    snapshot_mode, completeness, window_start, window_end, expected_item_count
  ) values
    (old_id, test_user_id, 'apple_music', stale_disjoint_scope,
     'legacy_mix', 'legacy_mix', 'full_snapshot', 'complete',
     clock_timestamp() - interval '365 days', clock_timestamp(), 0),
    (old_id, test_user_id, 'apple_music', album_scope,
     'library_album', 'library_album', 'full_snapshot', 'complete',
     clock_timestamp() - interval '365 days', clock_timestamp(), 0),
    (new_id, test_user_id, 'apple_music', album_scope,
     'library_album', 'library_album', 'full_snapshot', 'complete',
     clock_timestamp() - interval '365 days', clock_timestamp(), 1);
  insert into semantic_private.raw_source_records (
    id, user_id, ingestion_run_id, source_code, data_type, occurred_at,
    source_item_hmac, record_fingerprint, encryption_key_version,
    encrypted_payload, consent_purpose, retention_policy_version, retained_until
  ) values (
    raw_c_id, test_user_id, new_id, 'apple_music', 'library_album',
    item_c_occurred_at, item_c_hmac, item_c_fingerprint,
    'synthetic_key_v1', decode(repeat('cc', 16), 'hex'),
    'source_distillation', 'synthetic-retain-v1', now() + interval '30 days'
  );
  insert into semantic_private.ingestion_run_items (
    ingestion_run_id, user_id, source_code, scope_key, source_item_hmac,
    record_fingerprint, item_state, raw_source_record_id, observation_id,
    occurred_at
  ) values (
    new_id, test_user_id, 'apple_music', album_scope, item_c_hmac,
    item_c_fingerprint, 'present', raw_c_id, null,
    item_c_occurred_at
  );
  receipt_new := semantic_private.finalize_ingestion_run_v031(new_id);
  select revision into expected_revision
  from semantic_private.user_state_versions where user_id = test_user_id;
  select count(*) into jobs_after from semantic_private.worker_jobs
  where user_id = test_user_id and job_type = 'recompute_user';
  receipt_old := semantic_private.finalize_ingestion_run_v031(old_id);
  if jsonb_typeof(receipt_old) is distinct from 'object'
     or not exists (
       select 1 from semantic_private.ingestion_runs
       where id = old_id and status = 'superseded'
         and finished_at is not null and finalization_receipt = receipt_old
     )
     or (select revision from semantic_private.user_state_versions where user_id = test_user_id)
          <> expected_revision
     or (select count(*) from semantic_private.worker_jobs
         where user_id = test_user_id and job_type = 'recompute_user') <> jobs_after
     or not exists (
       select 1 from semantic_private.current_source_items
       where user_id = test_user_id and source_code = 'apple_music'
         and scope_key = album_scope and source_item_hmac = item_c_hmac
         and lifecycle_state = 'present' and last_seen_run_id = new_id
     )
     or not exists (
       select 1 from semantic_private.source_state_heads
       where user_id = test_user_id and source_code = 'apple_music'
         and scope_key = album_scope
         and latest_run_id = new_id and current_revision = expected_revision
     )
     or exists (
       select 1 from semantic_private.source_state_heads
       where user_id = test_user_id and source_code = 'apple_music'
         and scope_key = stale_disjoint_scope
     ) then
    raise exception 'out-of-order finalization displaced the newer current head';
  end if;
  receipt_retry := semantic_private.finalize_ingestion_run_v031(old_id);
  if receipt_retry is distinct from receipt_old then
    raise exception 'superseded finalization retry did not return its stored receipt';
  end if;

  -- A staged membership can reuse immutable A across runs without duplicating
  -- its raw evidence object; the run-item relation carries repeated membership.
  if (select count(*) from semantic_private.raw_source_records
      where user_id = test_user_id and source_code = 'apple_music'
        and source_item_hmac = item_a_hmac) <> 1
     or (select count(*) from semantic_private.ingestion_run_items
         where user_id = test_user_id and source_code = 'apple_music'
           and source_item_hmac = item_a_hmac) <> 4 then
    raise exception 'unchanged item was duplicated or lost cross-run membership';
  end if;
end
$current_state_contract$;

-- Inject a deterministic failure at the final run-status write. Everything
-- the finalizer did earlier in the statement must roll back with it.
create or replace function pg_temp.fail_v031_finalization_after_state()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.status = 'running'
     and new.status = 'succeeded'
     and new.input_hash = 'synthetic-v0.3.1-atomic-failure' then
    raise exception 'synthetic finalizer failure after state writes';
  end if;
  return new;
end;
$$;

create trigger ingestion_runs_inject_v031_atomic_failure
before update on semantic_private.ingestion_runs
for each row execute function pg_temp.fail_v031_finalization_after_state();

do $atomic_finalization_contract$
declare
  test_user_id uuid := ontology.stable_uuid('written:test:v0.3.1-current-state-user');
  failure_run_id uuid := ontology.stable_uuid('written:test:v0.3.1-atomic-failure');
  raw_d_id uuid := ontology.stable_uuid('written:test:v0.3.1-raw-d');
  item_d_hmac text := repeat(md5('written:v0.3.1:item-d'), 2);
  item_d_fingerprint text := repeat(md5('written:v0.3.1:fingerprint-d'), 2);
  revision_before bigint;
  jobs_before integer;
  current_before integer;
  head_before uuid;
begin
  select revision into revision_before
  from semantic_private.user_state_versions where user_id = test_user_id;
  select count(*) into jobs_before
  from semantic_private.worker_jobs
  where user_id = test_user_id and job_type = 'recompute_user';
  select count(*) into current_before
  from semantic_private.current_source_items where user_id = test_user_id;
  select latest_run_id into head_before
  from semantic_private.source_state_heads
  where user_id = test_user_id and source_code = 'apple_music'
    and scope_key = 'apple_music:library_playlist:v1';

  insert into semantic_private.ingestion_runs (
    id, user_id, source_code, connector_version, input_hash, status, started_at
  ) values (
    failure_run_id, test_user_id, 'apple_music', 'synthetic-v0.3.1',
    'synthetic-v0.3.1-atomic-failure', 'running',
    clock_timestamp() - interval '1 minute'
  );
  insert into semantic_private.ingestion_run_scopes (
    ingestion_run_id, user_id, source_code, scope_key, data_type, action_type,
    snapshot_mode, completeness, expected_item_count
  ) values (
    failure_run_id, test_user_id, 'apple_music',
    'apple_music:library_playlist:v1', 'library_playlist',
    'library_playlist', 'full_snapshot', 'complete', 1
  );
  insert into semantic_private.raw_source_records (
    id, user_id, ingestion_run_id, source_code, data_type, occurred_at,
    source_item_hmac, record_fingerprint, encryption_key_version,
    encrypted_payload, consent_purpose, retention_policy_version,
    retained_until
  ) values (
    raw_d_id, test_user_id, failure_run_id, 'apple_music',
    'library_playlist', '2026-08-02T03:00:00Z', item_d_hmac,
    item_d_fingerprint, 'synthetic_key_v1',
    decode(repeat('dd', 16), 'hex'), 'source_distillation',
    'synthetic-retain-v1', now() + interval '30 days'
  );
  insert into semantic_private.ingestion_run_items (
    ingestion_run_id, user_id, source_code, scope_key, source_item_hmac,
    record_fingerprint, item_state, raw_source_record_id, occurred_at
  ) values (
    failure_run_id, test_user_id, 'apple_music',
    'apple_music:library_playlist:v1', item_d_hmac, item_d_fingerprint,
    'present', raw_d_id, '2026-08-02T03:00:00Z'
  );

  begin
    perform semantic_private.finalize_ingestion_run_v031(failure_run_id);
    raise exception 'injected finalizer failure did not fire';
  exception
    when raise_exception then
      if sqlerrm <> 'synthetic finalizer failure after state writes' then
        raise;
      end if;
  end;

  if (select revision from semantic_private.user_state_versions where user_id = test_user_id)
       <> revision_before
     or (select count(*) from semantic_private.worker_jobs
         where user_id = test_user_id and job_type = 'recompute_user')
          <> jobs_before
     or (select count(*) from semantic_private.current_source_items
         where user_id = test_user_id) <> current_before
     or (select latest_run_id from semantic_private.source_state_heads
         where user_id = test_user_id and source_code = 'apple_music'
           and scope_key = 'apple_music:library_playlist:v1')
          is distinct from head_before
     or not exists (
       select 1 from semantic_private.ingestion_runs
       where id = failure_run_id and status = 'running'
         and finalization_revision is null and finalization_receipt is null
     )
     or exists (
       select 1 from semantic_private.current_source_items
       where user_id = test_user_id and source_item_hmac = item_d_hmac
     ) then
    raise exception 'finalizer error did not roll back state/run/revision/job atomically';
  end if;
end
$atomic_finalization_contract$;

drop trigger ingestion_runs_inject_v031_atomic_failure
  on semantic_private.ingestion_runs;
drop function pg_temp.fail_v031_finalization_after_state();

do $surface_fact_contract$
declare
  viewer_user_id uuid := ontology.stable_uuid('written:test:v0.3.1-fact-viewer');
  subject_user_id uuid := ontology.stable_uuid('written:test:v0.3.1-fact-subject');
  version_id uuid;
  resolver_id uuid;
  scorer_id uuid;
  ranker_id uuid;
  renderer_id uuid;
  concept_id uuid;
  explicit_concept_id uuid;
  delete_concept_id uuid;
  run_0_id uuid := ontology.stable_uuid('written:test:v0.3.1-fact-run-0');
  run_1_id uuid := ontology.stable_uuid('written:test:v0.3.1-fact-run-1');
  foreign_run_id uuid := ontology.stable_uuid('written:test:v0.3.1-foreign-fact-run');
  inferred_assertion_id uuid := ontology.stable_uuid('written:test:v0.3.1-inferred-assertion');
  viewer_assertion_id uuid := ontology.stable_uuid('written:test:v0.3.1-viewer-assertion');
  foreign_assertion_id uuid := ontology.stable_uuid('written:test:v0.3.1-foreign-assertion');
  delete_assertion_id uuid := ontology.stable_uuid('written:test:v0.3.1-delete-assertion');
  score_0_id uuid := ontology.stable_uuid('written:test:v0.3.1-score-0');
  score_1_id uuid := ontology.stable_uuid('written:test:v0.3.1-score-1');
  foreign_score_id uuid := ontology.stable_uuid('written:test:v0.3.1-foreign-score');
  fact_0_id uuid := ontology.stable_uuid('written:test:v0.3.1-fact-0');
  stale_insert_id uuid := ontology.stable_uuid('written:test:v0.3.1-stale-fact');
  fact_1_id uuid := ontology.stable_uuid('written:test:v0.3.1-fact-1');
  explain_fact_id uuid := ontology.stable_uuid('written:test:v0.3.1-explain-fact');
  delete_fact_id uuid := ontology.stable_uuid('written:test:v0.3.1-delete-fact');
  dyad_0_id uuid := ontology.stable_uuid('written:test:v0.3.1-fact-dyad-0');
  dyad_1_id uuid := ontology.stable_uuid('written:test:v0.3.1-fact-dyad-1');
  matching_dyad_id uuid := ontology.stable_uuid('written:test:v0.3.1-matching-dyad');
  bio_0_id uuid := ontology.stable_uuid('written:test:v0.3.1-bio-0');
  bio_1_id uuid := ontology.stable_uuid('written:test:v0.3.1-bio-1');
  match_authorization_id uuid := ontology.stable_uuid(
    'written:test:v0.3.1-fact-match-authorization'
  );
  fact_match_id uuid := ontology.stable_uuid('written:test:v0.3.1-fact-match');
  finalized boolean;
begin
  select id into version_id
  from ontology.versions where status = 'published';
  select id into resolver_id
  from ontology.model_versions
  where model_key = 'ontology_first_resolver' and version = '0.1.0';
  select id into scorer_id
  from ontology.model_versions
  where model_key = 'missing_aware_late_fusion' and version = '0.1.0';
  select id into ranker_id
  from ontology.model_versions
  where model_key = 'typed_graph_dyad_ranker' and version = '0.2.0';
  select id into renderer_id
  from ontology.model_versions
  where model_key = 'validated_fact_bio_renderer' and version = '0.2.0';
  select id into concept_id
  from ontology.concepts where concept_key = 'affinity:culture:italy';
  select id into explicit_concept_id
  from ontology.concepts where concept_key = 'activity:running';
  select id into delete_concept_id
  from ontology.concepts where concept_key = 'activity:walking';
  if version_id is null or resolver_id is null or scorer_id is null
     or ranker_id is null or renderer_id is null or concept_id is null
     or explicit_concept_id is null or delete_concept_id is null then
    raise exception 'v0.3.1 fact fixtures are missing seeded versions/models/concepts';
  end if;

  insert into auth.users (id, aud, role, created_at, updated_at) values
    (viewer_user_id, 'authenticated', 'authenticated', now(), now()),
    (subject_user_id, 'authenticated', 'authenticated', now(), now());
  insert into semantic_private.user_state_versions (user_id, revision) values
    (viewer_user_id, 0), (subject_user_id, 0);
  insert into semantic_private.match_authorizations (
    id, match_id, participant_a_user_id, participant_b_user_id, source_version
  ) values (
    match_authorization_id, fact_match_id, viewer_user_id, subject_user_id,
    'synthetic-v0.3.1'
  );

  insert into semantic_private.semantic_runs (
    id, user_id, ontology_version_id, resolver_model_id, scorer_model_id,
    input_revision, input_hash, status
  ) values
    (run_0_id, subject_user_id, version_id, resolver_id, scorer_id,
     0, 'synthetic-v0.3.1-fact-revision-0', 'running'),
    (foreign_run_id, viewer_user_id, version_id, resolver_id, scorer_id,
     0, 'synthetic-v0.3.1-foreign-fact-revision-0', 'running');
  insert into semantic_private.user_assertions (
    id, user_id, predicate_key, concept_id, created_ontology_version_id,
    source_semantic_run_id, assertion_origin, machine_state
  ) values
    (inferred_assertion_id, subject_user_id, 'affinity_to', concept_id, version_id,
     run_0_id, 'inferred', 'eligible'),
    (viewer_assertion_id, viewer_user_id, 'affinity_to', explicit_concept_id,
     version_id, null, 'explicit_self_report', 'eligible'),
    (foreign_assertion_id, viewer_user_id, 'affinity_to', concept_id, version_id,
     foreign_run_id, 'inferred', 'eligible'),
    (delete_assertion_id, subject_user_id, 'affinity_to', delete_concept_id,
     version_id, null, 'explicit_self_report', 'eligible');
  insert into semantic_private.assertion_score_versions (
    id, assertion_id, user_id, semantic_run_id, ontology_version_id,
    strength, confidence, breadth, stability, surfacing_score, display_payload
  ) values
    (score_0_id, inferred_assertion_id, subject_user_id, run_0_id, version_id,
     0.82, 0.84, 2, 0.78, 0.80, '{"template_key":"synthetic"}'::jsonb),
    (foreign_score_id, foreign_assertion_id, viewer_user_id, foreign_run_id,
     version_id, 0.76, 0.79, 2, 0.74, 0.75,
     '{"template_key":"synthetic-foreign"}'::jsonb);
  finalized := semantic_private.finalize_semantic_run(run_0_id);
  if finalized is distinct from true then
    raise exception 'revision-zero semantic fixture did not finalize';
  end if;
  finalized := semantic_private.finalize_semantic_run(foreign_run_id);
  if finalized is distinct from true then
    raise exception 'foreign-user semantic fixture did not finalize';
  end if;

  update semantic_private.assertion_surface_permissions
  set can_select = true, can_name = true, can_explain = true,
      permission_source = 'user_choice'
  where assertion_surface_permissions.assertion_id = inferred_assertion_id
    and user_id = subject_user_id and surface = 'bio';

  insert into semantic_private.validated_surface_facts (
    id, user_id, assertion_id, assertion_score_version_id,
    attested_revision, ontology_version_id, surface, predicate_key,
    display_label, evidence_class, confirmation_state, may_name, may_explain,
    validator_model_id, fact_version, fact_payload, state, data_use_purpose
  ) values (
    fact_0_id, subject_user_id, inferred_assertion_id, score_0_id, 0,
    version_id, 'bio', 'affinity_to', 'Italian cultural affinity',
    'ontology_inferred', 'inferred', true, true, ranker_id,
    'synthetic-score-0', '{}'::jsonb, 'validated', 'general_social'
  );
  if not semantic_private.validated_surface_fact_is_current(fact_0_id) then
    raise exception 'exact current score/revision fact was not current';
  end if;

  insert into semantic_private.dyad_runs (
    id, viewer_user_id, subject_user_id, viewer_revision, subject_revision,
    ontology_version_id, ranker_model_id, run_purpose, data_use_purpose,
    input_hash
  ) values (
    dyad_0_id, viewer_user_id, subject_user_id, 0, 0,
    version_id, ranker_id, 'bio', 'general_social',
    'synthetic-v0.3.1-fact-dyad-0'
  );
  update semantic_private.dyad_runs
  set status = 'succeeded', finished_at = now(),
      semantic_proximity = 0.8, comparability = 0.8
  where id = dyad_0_id;
  insert into semantic_private.bio_variants (
    id, dyad_run_id, viewer_user_id, subject_user_id,
    renderer_model_id, variant_version, stable_text, state
  ) values (
    bio_0_id, dyad_0_id, viewer_user_id, subject_user_id,
    renderer_id, 'synthetic-fact-0', 'Likes Italian culture.', 'draft'
  );
  insert into semantic_private.bio_variant_facts (
    bio_variant_id, surface_fact_id, subject_user_id, clause_role, rank
  ) values (bio_0_id, fact_0_id, subject_user_id, 'stable', 0);
  update semantic_private.bio_variants
  set state = 'ready', finalized_at = now() where id = bio_0_id;

  -- Advancing the input revision invalidates the exact score, its fact, and the
  -- dependent dyad/bio. A historical state='validated' bit is not sufficient.
  update semantic_private.user_state_versions set revision = 1
  where user_id = subject_user_id;
  if semantic_private.validated_surface_fact_is_current(fact_0_id)
     or exists (
       select 1 from semantic_private.validated_surface_facts
       where id = fact_0_id and state = 'validated'
     )
     or not exists (
       select 1 from semantic_private.dyad_runs where id = dyad_0_id and status = 'stale'
     )
     or not exists (
       select 1 from semantic_private.bio_variants where id = bio_0_id and state = 'stale'
     ) then
    raise exception 'revision advance left an old score/fact/product current';
  end if;

  begin
    insert into semantic_private.validated_surface_facts (
      id, user_id, assertion_id, assertion_score_version_id,
      attested_revision, ontology_version_id, surface, predicate_key,
      display_label, evidence_class, confirmation_state, may_name, may_explain,
      validator_model_id, fact_version, fact_payload, state, data_use_purpose
    ) values (
      stale_insert_id, subject_user_id, inferred_assertion_id, score_0_id, 0,
      version_id, 'bio', 'affinity_to', 'Stale Italian cultural affinity',
      'ontology_inferred', 'inferred', true, false, ranker_id,
      'synthetic-stale-score', '{}'::jsonb, 'validated', 'general_social'
    );
    raise exception 'non-current score was accepted as a validated fact';
  exception
    when raise_exception then
      if sqlerrm = 'non-current score was accepted as a validated fact' then raise; end if;
  end;

  insert into semantic_private.semantic_runs (
    id, user_id, ontology_version_id, resolver_model_id, scorer_model_id,
    input_revision, input_hash, status
  ) values (
    run_1_id, subject_user_id, version_id, resolver_id, scorer_id,
    1, 'synthetic-v0.3.1-fact-revision-1', 'running'
  );
  update semantic_private.user_assertions
  set source_semantic_run_id = run_1_id
  where id = inferred_assertion_id and user_id = subject_user_id;
  insert into semantic_private.assertion_score_versions (
    id, assertion_id, user_id, semantic_run_id, ontology_version_id,
    strength, confidence, breadth, stability, surfacing_score, display_payload
  ) values (
    score_1_id, inferred_assertion_id, subject_user_id, run_1_id, version_id,
    0.86, 0.88, 2, 0.81, 0.84, '{"template_key":"synthetic"}'::jsonb
  );
  finalized := semantic_private.finalize_semantic_run(run_1_id);
  if finalized is distinct from true then
    raise exception 'revision-one semantic fixture did not finalize';
  end if;

  insert into semantic_private.validated_surface_facts (
    id, user_id, assertion_id, assertion_score_version_id,
    attested_revision, ontology_version_id, surface, predicate_key,
    display_label, evidence_class, confirmation_state, may_name, may_explain,
    validator_model_id, fact_version, fact_payload, state, data_use_purpose
  ) values
    (fact_1_id, subject_user_id, inferred_assertion_id, score_1_id, 1,
     version_id, 'bio', 'affinity_to', 'Italian cultural affinity',
     'ontology_inferred', 'inferred', true, true, ranker_id,
     'synthetic-score-1', '{}'::jsonb, 'validated', 'general_social'),
    (explain_fact_id, subject_user_id, inferred_assertion_id, score_1_id, 1,
     version_id, 'bio', 'affinity_to', 'Italian cultural affinity detail',
     'ontology_inferred', 'inferred', true, true, ranker_id,
     'synthetic-score-1-explain', '{}'::jsonb, 'validated', 'general_social');
  if not semantic_private.validated_surface_fact_is_current(fact_1_id)
     or not semantic_private.validated_surface_fact_is_current(explain_fact_id) then
    raise exception 'new exact-score facts did not become current';
  end if;

  begin
    insert into semantic_private.validated_surface_facts (
      user_id, assertion_id, assertion_score_version_id, attested_revision,
      ontology_version_id, surface, predicate_key, display_label,
      evidence_class, confirmation_state, may_name, may_explain,
      validator_model_id, fact_version, fact_payload, state, data_use_purpose
    ) values (
      subject_user_id, inferred_assertion_id, foreign_score_id, 1,
      version_id, 'bio', 'affinity_to', 'Cross-user inferred score',
      'ontology_inferred', 'inferred', false, false, ranker_id,
      'synthetic-cross-user-score', '{}'::jsonb, 'validated', 'general_social'
    );
    raise exception 'fact accepted another user/assertion score pointer';
  exception
    when raise_exception then
      if sqlerrm = 'fact accepted another user/assertion score pointer' then raise; end if;
  end;

  insert into semantic_private.dyad_runs (
    id, viewer_user_id, subject_user_id, viewer_revision, subject_revision,
    ontology_version_id, ranker_model_id, run_purpose, data_use_purpose,
    input_hash
  ) values (
    dyad_1_id, viewer_user_id, subject_user_id, 0, 1,
    version_id, ranker_id, 'bio', 'general_social',
    'synthetic-v0.3.1-fact-dyad-1'
  );
  update semantic_private.dyad_runs
  set status = 'succeeded', finished_at = now(),
      semantic_proximity = 0.8, comparability = 0.8
  where id = dyad_1_id;
  insert into semantic_private.bio_variants (
    id, dyad_run_id, viewer_user_id, subject_user_id,
    renderer_model_id, variant_version, stable_text, state
  ) values (
    bio_1_id, dyad_1_id, viewer_user_id, subject_user_id,
    renderer_id, 'synthetic-fact-1', 'Likes Italian culture.', 'draft'
  );
  insert into semantic_private.bio_variant_facts (
    bio_variant_id, surface_fact_id, subject_user_id, clause_role, rank
  ) values (bio_1_id, fact_1_id, subject_user_id, 'stable', 0);
  update semantic_private.bio_variants
  set state = 'ready', finalized_at = now() where id = bio_1_id;

  -- Permission lattice narrowing must propagate to materialized facts. Explain
  -- loss need not retire a still-nameable fact; naming/select loss must.
  update semantic_private.assertion_surface_permissions
  set can_explain = false, permission_source = 'user_choice'
  where assertion_surface_permissions.assertion_id = inferred_assertion_id
    and user_id = subject_user_id and surface = 'bio';
  if exists (
    select 1 from semantic_private.validated_surface_facts
    where id in (fact_1_id, explain_fact_id) and may_explain
  ) or not semantic_private.validated_surface_fact_is_current(fact_1_id) then
    raise exception 'bio explanation narrowing did not strip only explanation use';
  end if;

  update semantic_private.assertion_surface_permissions
  set can_name = false, permission_source = 'user_choice'
  where assertion_surface_permissions.assertion_id = inferred_assertion_id
    and user_id = subject_user_id and surface = 'bio';
  if exists (
    select 1 from semantic_private.validated_surface_facts
    where id in (fact_1_id, explain_fact_id)
      and (state = 'validated' or may_name or may_explain)
  ) or semantic_private.validated_surface_fact_is_current(fact_1_id)
     or not exists (
       select 1 from semantic_private.bio_variants where id = bio_1_id and state = 'stale'
     ) then
    raise exception 'bio naming revocation left a fact or ready bio reusable';
  end if;
  begin
    update semantic_private.validated_surface_facts
    set state = 'validated', may_name = true
    where id = fact_1_id;
    raise exception 'retired fact was reactivated past narrowed permission';
  exception
    when raise_exception then
      if sqlerrm = 'retired fact was reactivated past narrowed permission' then raise; end if;
  end;

  -- Matching selection narrowing invalidates every live two-sided product run
  -- for the affected user, not only future pair inserts.
  update semantic_private.assertion_surface_permissions
  set can_select = true, permission_source = 'user_choice'
  where assertion_id = viewer_assertion_id
    and user_id = viewer_user_id and surface = 'matching';
  insert into semantic_private.dyad_runs (
    id, viewer_user_id, subject_user_id, viewer_revision, subject_revision,
    ontology_version_id, ranker_model_id, run_purpose, data_use_purpose,
    input_hash
  ) values (
    matching_dyad_id, viewer_user_id, subject_user_id, 0, 1,
    version_id, ranker_id, 'both', 'general_social',
    'synthetic-v0.3.1-matching-permission-dyad'
  );
  update semantic_private.dyad_runs
  set status = 'succeeded', finished_at = now(),
      semantic_proximity = 0.7, comparability = 0.7
  where id = matching_dyad_id;
  update semantic_private.assertion_surface_permissions
  set can_select = false, permission_source = 'user_choice'
  where assertion_id = viewer_assertion_id
    and user_id = viewer_user_id and surface = 'matching';
  if not exists (
    select 1 from semantic_private.dyad_runs
    where id = matching_dyad_id and status = 'stale'
  ) then
    raise exception 'matching selection revocation left a dyad live';
  end if;

  -- Deleting a permission row is equivalent to all-false; it cannot preserve a
  -- validated fact by bypassing an UPDATE-only trigger.
  update semantic_private.assertion_surface_permissions
  set can_select = true, can_name = true, can_explain = false,
      permission_source = 'user_choice'
  where assertion_id = delete_assertion_id
    and user_id = subject_user_id and surface = 'bio';
  insert into semantic_private.validated_surface_facts (
    id, user_id, assertion_id, assertion_score_version_id,
    attested_revision, ontology_version_id, surface, predicate_key,
    display_label, evidence_class, confirmation_state, may_name, may_explain,
    validator_model_id, fact_version, fact_payload, state, data_use_purpose
  ) values (
    delete_fact_id, subject_user_id, delete_assertion_id, null, 1,
    version_id, 'bio', 'affinity_to', 'Enjoys walking', 'explicit',
    'explicit_self_report', true, false, ranker_id,
    'synthetic-delete-permission', '{}'::jsonb, 'validated', 'general_social'
  );
  if not semantic_private.validated_surface_fact_is_current(delete_fact_id) then
    raise exception 'explicit fact was not current before permission deletion';
  end if;
  delete from semantic_private.assertion_surface_permissions
  where assertion_id = delete_assertion_id
    and user_id = subject_user_id and surface = 'bio';
  if semantic_private.validated_surface_fact_is_current(delete_fact_id)
     or exists (
       select 1 from semantic_private.validated_surface_facts
       where id = delete_fact_id
         and (state = 'validated' or may_name or may_explain)
     ) then
    raise exception 'permission DELETE bypassed fact retirement';
  end if;
end
$surface_fact_contract$;

do $match_revocation_contract$
declare
  participant_a_id uuid := ontology.stable_uuid('written:test:v0.3.1-match-a');
  participant_b_id uuid := ontology.stable_uuid('written:test:v0.3.1-match-b');
  participant_c_id uuid := ontology.stable_uuid('written:test:v0.3.1-match-c');
  version_id uuid;
  ranker_id uuid;
  bio_renderer_id uuid;
  renderer_id uuid;
  concept_a_id uuid;
  concept_b_id uuid;
  bridge_concept_id uuid;
  assertion_a_id uuid := ontology.stable_uuid('written:test:v0.3.1-match-assertion-a');
  assertion_b_id uuid := ontology.stable_uuid('written:test:v0.3.1-match-assertion-b');
  icebreaker_fact_a_id uuid := ontology.stable_uuid('written:test:v0.3.1-match-fact-a');
  icebreaker_fact_b_id uuid := ontology.stable_uuid('written:test:v0.3.1-match-fact-b');
  bio_fact_b_id uuid := ontology.stable_uuid('written:test:v0.3.1-match-bio-fact-b');
  dyad_id uuid := ontology.stable_uuid('written:test:v0.3.1-match-dyad');
  bio_id uuid := ontology.stable_uuid('written:test:v0.3.1-match-bio');
  authorization_id uuid := ontology.stable_uuid('written:test:v0.3.1-match-auth');
  changed_participants_auth_id uuid := ontology.stable_uuid(
    'written:test:v0.3.1-match-auth-changed-participants'
  );
  wrong_epoch_auth_id uuid := ontology.stable_uuid(
    'written:test:v0.3.1-match-auth-wrong-epoch'
  );
  duplicate_pair_auth_id uuid := ontology.stable_uuid(
    'written:test:v0.3.1-match-auth-duplicate-pair'
  );
  renewed_authorization_id uuid := ontology.stable_uuid(
    'written:test:v0.3.1-match-auth-epoch-2'
  );
  product_match_id uuid := ontology.stable_uuid('written:test:v0.3.1-product-match');
  duplicate_pair_match_id uuid := ontology.stable_uuid(
    'written:test:v0.3.1-product-match-duplicate-pair'
  );
  exposed_frame_id uuid := ontology.stable_uuid('written:test:v0.3.1-exposed-frame');
  provisional_frame_id uuid := ontology.stable_uuid('written:test:v0.3.1-provisional-frame');
  first_exposed_at timestamptz;
  second_exposed_at timestamptz;
  first_revoked_at timestamptz;
  revoke_receipt jsonb;
  retry_receipt jsonb;
begin
  select id into version_id
  from ontology.versions where status = 'published';
  select id into ranker_id
  from ontology.model_versions
  where model_key = 'typed_graph_dyad_ranker' and version = '0.2.0';
  select id into renderer_id
  from ontology.model_versions
  where model_key = 'deterministic_icebreaker_renderer' and version = '0.2.0';
  select id into bio_renderer_id
  from ontology.model_versions
  where model_key = 'validated_fact_bio_renderer' and version = '0.2.0';
  select id into concept_a_id
  from ontology.concepts where concept_key = 'activity:running';
  select id into concept_b_id
  from ontology.concepts where concept_key = 'activity:walking';
  select id into bridge_concept_id
  from ontology.concepts where concept_key = 'hub:sports_movement';
  if version_id is null or ranker_id is null or renderer_id is null
     or bio_renderer_id is null
     or concept_a_id is null or concept_b_id is null
     or bridge_concept_id is null then
    raise exception 'v0.3.1 match fixtures are missing seeded versions/models/concepts';
  end if;

  insert into auth.users (id, aud, role, created_at, updated_at) values
    (participant_a_id, 'authenticated', 'authenticated', now(), now()),
    (participant_b_id, 'authenticated', 'authenticated', now(), now()),
    (participant_c_id, 'authenticated', 'authenticated', now(), now());
  insert into semantic_private.user_state_versions (user_id, revision) values
    (participant_a_id, 0), (participant_b_id, 0), (participant_c_id, 0);
  insert into semantic_private.user_assertions (
    id, user_id, predicate_key, concept_id, created_ontology_version_id,
    assertion_origin, machine_state
  ) values
    (assertion_a_id, participant_a_id, 'affinity_to', concept_a_id,
     version_id, 'explicit_self_report', 'eligible'),
    (assertion_b_id, participant_b_id, 'affinity_to', concept_b_id,
     version_id, 'explicit_self_report', 'eligible');

  update semantic_private.assertion_surface_permissions
  set can_select = true, permission_source = 'user_choice'
  where assertion_id in (assertion_a_id, assertion_b_id)
    and surface = 'matching';
  update semantic_private.assertion_surface_permissions
  set can_select = true, can_name = true, can_explain = false,
      permission_source = 'user_choice'
  where assertion_id in (assertion_a_id, assertion_b_id)
    and surface in ('bio', 'icebreaker');

  insert into semantic_private.validated_surface_facts (
    id, user_id, assertion_id, assertion_score_version_id,
    attested_revision, ontology_version_id, surface, predicate_key,
    display_label, evidence_class, confirmation_state, may_name, may_explain,
    validator_model_id, fact_version, fact_payload, state, data_use_purpose
  ) values
    (icebreaker_fact_a_id, participant_a_id, assertion_a_id, null, 0,
     version_id, 'icebreaker', 'affinity_to', 'Enjoys running', 'explicit',
     'explicit_self_report', true, false, ranker_id,
     'synthetic-match-a', '{}'::jsonb, 'validated', 'general_social'),
    (icebreaker_fact_b_id, participant_b_id, assertion_b_id, null, 0,
     version_id, 'icebreaker', 'affinity_to', 'Enjoys walking', 'explicit',
     'explicit_self_report', true, false, ranker_id,
     'synthetic-match-b', '{}'::jsonb, 'validated', 'general_social'),
    (bio_fact_b_id, participant_b_id, assertion_b_id, null, 0,
     version_id, 'bio', 'affinity_to', 'Enjoys walking', 'explicit',
     'explicit_self_report', true, false, ranker_id,
     'synthetic-match-bio-b', '{}'::jsonb, 'validated', 'general_social');
  if not semantic_private.validated_surface_fact_is_current(icebreaker_fact_a_id)
     or not semantic_private.validated_surface_fact_is_current(icebreaker_fact_b_id)
     or not semantic_private.validated_surface_fact_is_current(bio_fact_b_id) then
    raise exception 'explicit match fixture facts did not become current';
  end if;

  insert into semantic_private.match_authorizations (
    id, match_id, participant_a_user_id, participant_b_user_id, source_version
  ) values (
    authorization_id, product_match_id, participant_a_id, participant_b_id,
    'synthetic-v0.3.1'
  );

  -- Epoch identity is exact: the match cannot change participants, skip an
  -- epoch, or coexist with another active match id for the same unordered pair.
  begin
    insert into semantic_private.match_authorizations (
      id, match_id, participant_a_user_id, participant_b_user_id,
      authorization_epoch, source_version
    ) values (
      changed_participants_auth_id, product_match_id,
      participant_a_id, participant_c_id, 2, 'synthetic-v0.3.1'
    );
    raise exception 'authorization epoch changed match participants';
  exception
    when others then
      if sqlerrm = 'authorization epoch changed match participants' then raise; end if;
  end;
  begin
    insert into semantic_private.match_authorizations (
      id, match_id, participant_a_user_id, participant_b_user_id,
      authorization_epoch, source_version
    ) values (
      wrong_epoch_auth_id, product_match_id,
      participant_b_id, participant_a_id, 3, 'synthetic-v0.3.1'
    );
    raise exception 'authorization epoch skipped its predecessor';
  exception
    when others then
      if sqlerrm = 'authorization epoch skipped its predecessor' then raise; end if;
  end;
  begin
    insert into semantic_private.match_authorizations (
      id, match_id, participant_a_user_id, participant_b_user_id,
      source_version
    ) values (
      duplicate_pair_auth_id, duplicate_pair_match_id,
      participant_b_id, participant_a_id, 'synthetic-v0.3.1'
    );
    raise exception 'two active match ids authorized the same unordered pair';
  exception
    when others then
      if sqlerrm = 'two active match ids authorized the same unordered pair' then raise; end if;
  end;

  insert into semantic_private.dyad_runs (
    id, viewer_user_id, subject_user_id, viewer_revision, subject_revision,
    ontology_version_id, ranker_model_id, run_purpose, data_use_purpose,
    input_hash
  ) values (
    dyad_id, participant_a_id, participant_b_id, 0, 0,
    version_id, ranker_id, 'both', 'general_social',
    'synthetic-v0.3.1-match-dyad'
  );
  update semantic_private.dyad_runs
  set status = 'succeeded', finished_at = now(),
      semantic_proximity = 0.75, comparability = 0.80
  where id = dyad_id;

  insert into semantic_private.bio_variants (
    id, dyad_run_id, viewer_user_id, subject_user_id,
    renderer_model_id, variant_version, stable_text, state
  ) values (
    bio_id, dyad_id, participant_a_id, participant_b_id,
    bio_renderer_id, 'synthetic-match-bio', 'Enjoys walking.', 'draft'
  );
  insert into semantic_private.bio_variant_facts (
    bio_variant_id, surface_fact_id, subject_user_id, clause_role, rank
  ) values (bio_id, bio_fact_b_id, participant_b_id, 'stable', 0);
  update semantic_private.bio_variants
  set state = 'ready', finalized_at = now() where id = bio_id;

  insert into semantic_private.icebreaker_frames (
    id, match_authorization_id, dyad_run_id, viewer_user_id,
    subject_user_id, bridge_concept_id, ontology_version_id,
    renderer_model_id, bridge_mode, template_version, frame_payload
  ) values
    (exposed_frame_id, authorization_id, dyad_id, participant_a_id,
     participant_b_id, bridge_concept_id, version_id, renderer_id,
     'shared_thread', 'synthetic-exposed-v0.3.1',
     '{"template_key":"shared_movement","wording_version":"v1","bridge_label":"movement"}'::jsonb),
    (provisional_frame_id, authorization_id, dyad_id, participant_a_id,
     participant_b_id, bridge_concept_id, version_id, renderer_id,
     'shared_thread', 'synthetic-provisional-v0.3.1',
     '{"template_key":"shared_movement","wording_version":"v1","bridge_label":"movement"}'::jsonb);
  insert into semantic_private.icebreaker_frame_facts (
    icebreaker_frame_id, surface_fact_id, fact_user_id, fact_side
  ) values
    (exposed_frame_id, icebreaker_fact_a_id, participant_a_id, 'viewer'),
    (exposed_frame_id, icebreaker_fact_b_id, participant_b_id, 'subject'),
    (provisional_frame_id, icebreaker_fact_a_id, participant_a_id, 'viewer'),
    (provisional_frame_id, icebreaker_fact_b_id, participant_b_id, 'subject');
  update semantic_private.icebreaker_frames
  set state = 'ready', finalized_at = now(),
      rendered_text = 'You both enjoy movement. What keeps it fun?'
  where id = exposed_frame_id;
  update semantic_private.icebreaker_frames
  set state = 'ready', finalized_at = now(),
      rendered_text = 'You both make time for movement. What helps it stick?'
  where id = provisional_frame_id;

  -- Exposure-first wins one serial order. A retry returns the same historical
  -- exposure rather than turning a successful request into an error.
  perform semantic_private.mark_icebreaker_exposed(exposed_frame_id);
  select exposed_at into first_exposed_at
  from semantic_private.icebreaker_frames where id = exposed_frame_id;
  perform semantic_private.mark_icebreaker_exposed(exposed_frame_id);
  select exposed_at into second_exposed_at
  from semantic_private.icebreaker_frames where id = exposed_frame_id;
  if first_exposed_at is null or second_exposed_at is distinct from first_exposed_at then
    raise exception 'first-exposure retry was not exactly-once/idempotent';
  end if;

  revoke_receipt := semantic_private.revoke_match_authorization_v031(
    product_match_id, 'synthetic_user_block'
  );
  if jsonb_typeof(revoke_receipt) is distinct from 'object'
     or not exists (
       select 1 from semantic_private.match_authorizations
       where id = authorization_id and authorization_state = 'revoked'
         and revoked_at is not null
     )
     or not exists (
       select 1 from semantic_private.dyad_runs where id = dyad_id and status = 'stale'
     )
     or not exists (
       select 1 from semantic_private.bio_variants where id = bio_id and state = 'stale'
     )
     or not exists (
       select 1 from semantic_private.icebreaker_frames
       where id = provisional_frame_id and exposed_at is null
         and state in ('stale', 'revoked')
     )
     or not exists (
       select 1 from semantic_private.icebreaker_frames
       where id = exposed_frame_id and exposed_at = first_exposed_at
         and state = 'ready'
     ) then
    raise exception 'match revocation did not invalidate only unexposed/current products';
  end if;
  select revoked_at into first_revoked_at
  from semantic_private.match_authorizations where id = authorization_id;

  -- Revocation-first wins the other serial order: the provisional frame cannot
  -- cross first exposure after the authorization row is terminal.
  begin
    perform semantic_private.mark_icebreaker_exposed(provisional_frame_id);
    raise exception 'revoked match frame was first-exposed';
  exception
    when raise_exception then
      if sqlerrm = 'revoked match frame was first-exposed' then raise; end if;
  end;

  retry_receipt := semantic_private.revoke_match_authorization_v031(
    product_match_id, 'synthetic_user_block'
  );
  if retry_receipt is distinct from revoke_receipt
     or (select revoked_at from semantic_private.match_authorizations
         where id = authorization_id) is distinct from first_revoked_at
     or (select exposed_at from semantic_private.icebreaker_frames
         where id = exposed_frame_id) is distinct from first_exposed_at then
    raise exception 'match revocation retry changed receipt/timestamps/history';
  end if;

  begin
    update semantic_private.match_authorizations
    set authorization_state = 'active', revoked_at = null
    where id = authorization_id;
    raise exception 'terminal match authorization was reactivated in place';
  exception
    when raise_exception then
      if sqlerrm = 'terminal match authorization was reactivated in place' then raise; end if;
  end;

  insert into semantic_private.match_authorizations (
    id, match_id, participant_a_user_id, participant_b_user_id,
    authorization_epoch, source_version
  ) values (
    renewed_authorization_id, product_match_id,
    participant_b_id, participant_a_id, 2, 'synthetic-v0.3.1-renewed'
  );
  if semantic_private.active_match_authorization_id_v031(
       participant_a_id, participant_b_id
     ) is distinct from renewed_authorization_id then
    raise exception 'new terminal-successor authorization epoch was not current';
  end if;
end
$match_revocation_contract$;

rollback;
