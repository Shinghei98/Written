-- 0239 — an evaluation worker cannot claim shadow, and cannot write through an
-- alternate table.
--
-- The counterfactuals `0237` was missing. That file seeded an invocation with
-- `model_lane_mode = 'shadow'` and no manifest at all, then asserted the call
-- could create a user mention — so its green verified the bypass rather than
-- refusing it.
--
-- Everything runs against seeded rows and rolls back.

begin;

do $$
declare
  alice    uuid := '00000000-0000-4000-8000-00000000a11c';
  bob      uuid := '00000000-0000-4000-8000-00000000b0b0';
  version  uuid;
  deployed uuid;
  floating uuid;
  shadowed uuid;
  call_id  uuid;
  eval_call uuid;
  run_id   uuid;
  obs      uuid;
  bob_run  uuid;
  bob_obs  uuid;
  ev       uuid;
  lane     text;
  raised   boolean;
begin
  insert into auth.users (id, email) values
    (alice, 'alice@example.invalid'), (bob, 'bob@example.invalid')
  on conflict (id) do nothing;
  select id into version from ontology.versions where status = 'published';

  -- An evaluation release, deployed. A shadow release, deployed. And one that
  -- no slot points at.
  insert into ontology.release_manifests
    (base_ontology_version_id, compiled_contract_sha256, workbook_sha256,
     schema_sha256, release_build_sha256, database_fingerprint_sha256,
     environment, promotion_decision, model_lane_mode,
     tokenizer_runtime_manifest_sha256, extraction_contract_manifest_sha256,
     gateway_image_digest, serving_image_digest, prompt_version, grammar_version)
  values (version, repeat('a', 64), repeat('b', 64), repeat('c', 64),
          repeat('d', 64), repeat('e', 64), 'probe', 'pending', 'evaluation',
          repeat('1', 64), repeat('2', 64), 'sha256:x', 'sha256:y',
          'qwen_extractor_v5', 'semantic_grammar_v3')
  returning id into deployed;
  insert into ontology.release_manifests
    (base_ontology_version_id, compiled_contract_sha256, workbook_sha256,
     schema_sha256, release_build_sha256, database_fingerprint_sha256,
     environment, promotion_decision, model_lane_mode,
     tokenizer_runtime_manifest_sha256, extraction_contract_manifest_sha256,
     gateway_image_digest, serving_image_digest, prompt_version, grammar_version)
  values (version, repeat('9', 64), repeat('b', 64), repeat('c', 64),
          repeat('d', 64), repeat('e', 64), 'probe', 'pending', 'shadow',
          repeat('1', 64), repeat('2', 64), 'sha256:x', 'sha256:y',
          'qwen_extractor_v5', 'semantic_grammar_v3')
  returning id into shadowed;
  insert into ontology.release_manifests
    (base_ontology_version_id, compiled_contract_sha256, workbook_sha256,
     schema_sha256, release_build_sha256, database_fingerprint_sha256,
     environment, promotion_decision, model_lane_mode)
  values (version, repeat('f', 64), repeat('b', 64), repeat('c', 64),
          repeat('d', 64), repeat('e', 64), 'probe', 'pending', 'off')
  returning id into floating;

  insert into ontology.deployment_slots (slot, ontology_version_id, release_manifest_id)
  values ('canary', version, deployed), ('shadow', version, shadowed);

  -- ---------------------------------------------------------------------
  -- 1. A manifest nobody deployed authorizes nothing
  -- ---------------------------------------------------------------------
  raised := false;
  begin
    insert into semantic_private.model_invocations
      (input_hash, model_id, model_revision, prompt_version, grammar_version,
       output_schema_hash, batch_items, status, release_manifest_id)
    values ('p', 'm', 'r', 'qwen_extractor_v5', 'semantic_grammar_v3',
            repeat('0', 64), 1, 'succeeded', floating);
  exception when others then raised := true;
  end;
  if not raised then
    raise exception '0239 contract: an undeployed manifest authorized a call';
  end if;

  -- ---------------------------------------------------------------------
  -- 2. A caller-supplied lane is discarded
  -- ---------------------------------------------------------------------
  -- The forged claim: an evaluation deployment, a caller asking for shadow.
  insert into semantic_private.model_invocations
    (input_hash, model_id, model_revision, prompt_version, grammar_version,
     output_schema_hash, batch_items, status, release_manifest_id,
     model_lane_mode)
  values ('p2', 'm', 'r', 'qwen_extractor_v5', 'semantic_grammar_v3',
          repeat('0', 64), 1, 'succeeded', deployed, 'shadow')
  returning id, model_lane_mode into eval_call, lane;
  if lane <> 'evaluation' then
    raise exception
      '0239 contract: a call claimed lane % against an evaluation deployment', lane;
  end if;

  -- And it cannot be edited afterwards either.
  raised := false;
  begin
    update semantic_private.model_invocations
       set model_lane_mode = 'shadow' where id = eval_call;
  exception when others then raised := true;
  end;
  if not raised then
    raise exception '0239 contract: a call changed the lane it ran in';
  end if;

  -- ---------------------------------------------------------------------
  -- 3. Evaluation is fixture-only
  -- ---------------------------------------------------------------------
  raised := false;
  begin
    insert into semantic_private.model_invocations
      (user_id, input_hash, model_id, model_revision, prompt_version,
       grammar_version, output_schema_hash, batch_items, status,
       release_manifest_id)
    values (alice, 'p3', 'm', 'r', 'qwen_extractor_v5', 'semantic_grammar_v3',
            repeat('0', 64), 1, 'succeeded', deployed);
  exception when others then raised := true;
  end;
  if not raised then
    raise exception '0239 contract: an evaluation invocation named a user';
  end if;

  raised := false;
  begin
    insert into semantic_private.model_invocation_items
      (invocation_id, item_index, user_id, logical_extraction_key, outcome)
    values (eval_call, 0, alice, 'probe:eval-user', 'timeout');
  exception when others then raised := true;
  end;
  if not raised then
    raise exception '0239 contract: an evaluation item named a user';
  end if;

  -- ---------------------------------------------------------------------
  -- 4. A user-backed success must name live evidence
  -- ---------------------------------------------------------------------
  insert into semantic_private.ingestion_runs
    (user_id, source_code, connector_version, input_hash, status)
  values (alice, 'apple_music', 'probe', 'probe_0239', 'running')
  returning id into run_id;
  insert into semantic_private.observations
    (user_id, ingestion_run_id, source_code, data_type, observation_kind,
     action_type, source_item_hmac, record_fingerprint, payload_schema_version,
     normalized_payload, privacy_class)
  values (alice, run_id, 'apple_music', 'library_song', 'catalog_entity',
          'library_song', repeat(md5('0239-a'), 2), repeat(md5('0239-b'), 2),
          'synthetic-v0.3.1', '{}'::jsonb, 'public_catalog')
  returning id into obs;
  insert into semantic_private.source_text_evidence
    (user_id, observation_id, encrypted_text, encryption_key_version,
     retention_class, expires_at)
  values (alice, obs, '\x01'::bytea, 'k-v1', 'provider_catalog_text',
          now() + interval '30 days')
  returning id into ev;

  insert into semantic_private.model_invocations
    (user_id, input_hash, model_id, model_revision, prompt_version,
     grammar_version, output_schema_hash, batch_items, status,
     release_manifest_id)
  values (alice, 'p4', 'm', 'r', 'qwen_extractor_v5', 'semantic_grammar_v3',
          repeat('0', 64), 1, 'succeeded', shadowed)
  returning id into call_id;

  raised := false;
  begin
    insert into semantic_private.model_invocation_items
      (invocation_id, item_index, user_id, observation_id,
       logical_extraction_key, outcome, mention_count)
    values (call_id, 0, alice, obs, 'probe:no-evidence', 'succeeded', 1);
  exception when others then raised := true;
  end;
  if not raised then
    raise exception
      '0239 contract: a user-backed success named no source text, so the staleness check was skipped';
  end if;

  -- Live evidence is accepted, so the refusals are about the evidence rather
  -- than about the shape.
  insert into semantic_private.model_invocation_items
    (invocation_id, item_index, user_id, observation_id,
     source_text_evidence_id, logical_extraction_key, outcome, mention_count)
  values (call_id, 1, alice, obs, ev, 'probe:live', 'succeeded', 1);

  -- Redacted evidence is not.
  update semantic_private.source_text_evidence
     set refresh_status = 'deleted', deleted_at = now(), encrypted_text = null
   where id = ev;
  raised := false;
  begin
    insert into semantic_private.model_invocation_items
      (invocation_id, item_index, user_id, observation_id,
       source_text_evidence_id, logical_extraction_key, outcome, mention_count)
    values (call_id, 2, alice, obs, ev, 'probe:redacted', 'succeeded', 1);
  exception when others then raised := true;
  end;
  if not raised then
    raise exception '0239 contract: a success committed against redacted text';
  end if;

  -- ---------------------------------------------------------------------
  -- 5. An item cannot point at another account's observation
  -- ---------------------------------------------------------------------
  insert into semantic_private.ingestion_runs
    (user_id, source_code, connector_version, input_hash, status)
  values (bob, 'apple_music', 'probe', 'probe_0239_bob', 'running')
  returning id into bob_run;
  insert into semantic_private.observations
    (user_id, ingestion_run_id, source_code, data_type, observation_kind,
     action_type, source_item_hmac, record_fingerprint, payload_schema_version,
     normalized_payload, privacy_class)
  values (bob, bob_run, 'apple_music', 'library_song', 'catalog_entity',
          'library_song', repeat(md5('0239-c'), 2), repeat(md5('0239-d'), 2),
          'synthetic-v0.3.1', '{}'::jsonb, 'public_catalog')
  returning id into bob_obs;

  raised := false;
  begin
    insert into semantic_private.model_invocation_items
      (invocation_id, item_index, user_id, observation_id,
       logical_extraction_key, outcome)
    values (call_id, 3, alice, bob_obs, 'probe:cross-user', 'timeout');
  exception when foreign_key_violation then raised := true;
  end;
  if not raised then
    raise exception
      '0239 contract: an item named another account''s observation';
  end if;

  raise notice '0239 contract: the lane is derived and the scope is closed';
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. The lane that calls a model cannot write semantics
-- ---------------------------------------------------------------------------
--
-- Privilege rather than lineage. The mention guard governs what may *descend*
-- from a call; it has nothing to say to a role that can write the descendant
-- without the ancestor, which `semantic_worker` can and always could. The answer
-- is a second identity, the way ingestion already has one.

do $$
declare
  target text;
  writable text[] := '{}';
begin
  foreach target in array array[
    'observation_mentions', 'mention_resolutions', 'provisional_entities',
    'user_term_candidates', 'candidate_support_links', 'review_items',
    'user_term_suppressions', 'user_suppressions', 'user_assertions',
    'observations', 'raw_source_records'
  ] loop
    if has_table_privilege('semantic_model_worker',
                           format('semantic_private.%I', target), 'INSERT')
       or has_table_privilege('semantic_model_worker',
                              format('semantic_private.%I', target), 'UPDATE') then
      writable := writable || target;
    end if;
  end loop;
  if array_length(writable, 1) is not null then
    raise exception
      '0239 contract: the model lane can write %; the mention guard is decoration',
      writable;
  end if;

  -- It can still do its own job, or the separation is just a broken worker.
  if not has_table_privilege('semantic_model_worker',
                             'semantic_private.model_invocations', 'INSERT')
     or not has_table_privilege('semantic_model_worker',
                                'semantic_private.model_invocation_items', 'INSERT') then
    raise exception '0239 contract: the model lane cannot record its own calls';
  end if;

  -- And the deterministic lane cannot record a model call, which is what keeps
  -- the two from being one role wearing two names.
  if has_table_privilege('semantic_worker',
                         'semantic_private.model_invocations', 'INSERT') then
    raise exception '0239 contract: semantic_worker can still record a model call';
  end if;
end;
$$;

rollback;
