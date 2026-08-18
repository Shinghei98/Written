-- 0241 — a call and its items are one write, and an unanswered item is an
-- outcome rather than an absence.
--
-- Everything runs against seeded rows and rolls back.

begin;

do $$
declare
  alice   uuid := '00000000-0000-4000-8000-00000000a11c';
  version uuid;
  release uuid;
  run_id  uuid;
  obs     uuid;
  ev      uuid;
  call_id uuid;
  raised  boolean;
  summary record;
  n       integer;
begin
  insert into auth.users (id, email) values (alice, 'alice@example.invalid')
  on conflict (id) do nothing;
  select id into version from ontology.versions where status = 'published';

  insert into ontology.release_manifests
    (base_ontology_version_id, compiled_contract_sha256, workbook_sha256,
     schema_sha256, release_build_sha256, database_fingerprint_sha256,
     environment, promotion_decision, model_lane_mode,
     tokenizer_runtime_manifest_sha256, extraction_contract_manifest_sha256,
     gateway_image_digest, serving_image_digest, prompt_version, grammar_version)
  values (version, repeat('a', 64), repeat('b', 64), repeat('c', 64),
          repeat('d', 64), repeat('e', 64), 'probe', 'pending', 'shadow',
          repeat('1', 64), repeat('2', 64), 'sha256:x', 'sha256:y',
          'qwen_extractor_v5', 'semantic_grammar_v3')
  returning id into release;
  insert into ontology.deployment_slots (slot, ontology_version_id, release_manifest_id)
  values ('shadow', version, release);

  insert into semantic_private.ingestion_runs
    (user_id, source_code, connector_version, input_hash, status)
  values (alice, 'apple_music', 'probe', 'probe_0241', 'running')
  returning id into run_id;
  insert into semantic_private.observations
    (user_id, ingestion_run_id, source_code, data_type, observation_kind,
     action_type, source_item_hmac, record_fingerprint, payload_schema_version,
     normalized_payload, privacy_class)
  values (alice, run_id, 'apple_music', 'library_song', 'catalog_entity',
          'library_song', repeat(md5('0241-a'), 2), repeat(md5('0241-b'), 2),
          'synthetic-v0.3.1', '{}'::jsonb, 'public_catalog')
  returning id into obs;
  insert into semantic_private.source_text_evidence
    (user_id, observation_id, encrypted_text, encryption_key_version,
     retention_class, expires_at)
  values (alice, obs, '\x01'::bytea, 'k-v1', 'provider_catalog_text',
          now() + interval '30 days')
  returning id into ev;

  -- ---------------------------------------------------------------------
  -- 1. An unanswered item is an outcome, not a missing row
  -- ---------------------------------------------------------------------
  -- A gap is indistinguishable from a crash mid-write. Two rows for a
  -- three-item request is refused; three rows, one saying missing_item, is the
  -- shape that carries the fact.
  raised := false;
  begin
    perform semantic_private.record_model_invocation(
      3,
      jsonb_build_array(
        jsonb_build_object('logical_extraction_key', 'k1', 'outcome', 'timeout'),
        jsonb_build_object('logical_extraction_key', 'k2', 'outcome', 'timeout')),
      'in', 'm', 'r', 'qwen_extractor_v5', 'semantic_grammar_v3', repeat('0', 64));
  exception when others then raised := true;
  end;
  if not raised then
    raise exception
      '0241 contract: a three-item request was recorded with two rows and a gap';
  end if;

  select semantic_private.record_model_invocation(
    3,
    jsonb_build_array(
      jsonb_build_object(
        'logical_extraction_key', 'k1', 'outcome', 'succeeded',
        'mention_count', 2, 'user_id', alice, 'observation_id', obs,
        'source_text_evidence_id', ev),
      jsonb_build_object('logical_extraction_key', 'k2', 'outcome', 'missing_item'),
      jsonb_build_object('logical_extraction_key', 'k3', 'outcome', 'output_overflow')),
    'in', 'm', 'r', 'qwen_extractor_v5', 'semantic_grammar_v3', repeat('0', 64),
    alice)
  into call_id;

  -- ---------------------------------------------------------------------
  -- 2. batch_items and item_index are derived, not supplied
  -- ---------------------------------------------------------------------
  select batch_items into n from semantic_private.model_invocations
   where id = call_id;
  if n <> 3 then
    raise exception '0241 contract: batch_items is %, expected the array length 3', n;
  end if;

  select count(*) into n from semantic_private.model_invocation_items
   where invocation_id = call_id and item_index between 0 and 2;
  if n <> 3 then
    raise exception '0241 contract: the indices are not 0..2';
  end if;

  select count(*) into n from semantic_private.model_invocation_items
   where invocation_id = call_id and outcome = 'missing_item';
  if n <> 1 then
    raise exception '0241 contract: missing_item was not recorded as an outcome';
  end if;

  -- ---------------------------------------------------------------------
  -- 3. The summary is derived from the items
  -- ---------------------------------------------------------------------
  select * into summary from semantic_private.model_invocation_summary
   where invocation_id = call_id;
  if summary.items_recorded <> 3 or summary.succeeded <> 1
     or summary.failed <> 2 or summary.mentions <> 2 then
    raise exception
      '0241 contract: the summary reads % recorded, % succeeded, % failed, % mentions',
      summary.items_recorded, summary.succeeded, summary.failed, summary.mentions;
  end if;
  if summary.derived_status <> 'partial' then
    raise exception '0241 contract: a partly successful call reads %',
      summary.derived_status;
  end if;
  if summary.model_lane_mode <> 'shadow' then
    raise exception '0241 contract: the recorded lane is %', summary.model_lane_mode;
  end if;

  -- ---------------------------------------------------------------------
  -- 4. A request for nothing is refused
  -- ---------------------------------------------------------------------
  raised := false;
  begin
    perform semantic_private.record_model_invocation(
      0, '[]'::jsonb, 'in', 'm', 'r', 'qwen_extractor_v5',
      'semantic_grammar_v3', repeat('0', 64));
  exception when others then raised := true;
  end;
  if not raised then
    raise exception '0241 contract: a call recorded no items at all';
  end if;

  -- ---------------------------------------------------------------------
  -- 5. The dropped column stays dropped
  -- ---------------------------------------------------------------------
  select count(*) into n from information_schema.columns
   where table_schema = 'semantic_private' and table_name = 'model_invocations'
     and column_name = 'status';
  if n <> 0 then
    raise exception
      '0241 contract: model_invocations.status is back, so a summary can disagree with its items again';
  end if;

  raise notice '0241 contract: one call, one write, and the status is derived';
end;
$$;

rollback;
