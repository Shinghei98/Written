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
  evaluation_release uuid;
  shadow_release uuid;
  floating uuid;
  call_id  uuid;
  eval_call uuid;
  run_id   uuid;
  obs      uuid;
  other_obs uuid;
  bob_run  uuid;
  bob_obs  uuid;
  ev       uuid;
  other_ev uuid;
  lane     text;
  named    uuid;
  raised   boolean;
begin
  insert into auth.users (id, email) values
    (alice, 'alice@example.invalid'), (bob, 'bob@example.invalid')
  on conflict (id) do nothing;
  select id into version from ontology.versions where status = 'published';

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
  returning id into evaluation_release;
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
  returning id into shadow_release;
  insert into ontology.release_manifests
    (base_ontology_version_id, compiled_contract_sha256, workbook_sha256,
     schema_sha256, release_build_sha256, database_fingerprint_sha256,
     environment, promotion_decision, model_lane_mode)
  values (version, repeat('f', 64), repeat('b', 64), repeat('c', 64),
          repeat('d', 64), repeat('e', 64), 'probe', 'pending', 'off')
  returning id into floating;

  -- ---------------------------------------------------------------------
  -- 1. With nothing deployed, nothing authorizes a call
  -- ---------------------------------------------------------------------
  raised := false;
  begin
    insert into semantic_private.model_invocations
      (input_hash, model_id, model_revision, prompt_version, grammar_version,
       output_schema_hash, batch_items, status, release_manifest_id)
    values ('p0', 'm', 'r', 'qwen_extractor_v5', 'semantic_grammar_v3',
            repeat('0', 64), 1, 'succeeded', shadow_release);
  exception when others then raised := true;
  end;
  if not raised then
    raise exception
      '0239 contract: a call was authorized with no calling-lane deployment';
  end if;

  -- ---------------------------------------------------------------------
  -- 2. Only one calling release may be in force
  -- ---------------------------------------------------------------------
  insert into ontology.deployment_slots (slot, ontology_version_id, release_manifest_id)
  values ('canary', version, evaluation_release);

  raised := false;
  begin
    insert into ontology.deployment_slots (slot, ontology_version_id, release_manifest_id)
    values ('shadow', version, shadow_release);
  exception when others then raised := true;
  end;
  if not raised then
    raise exception
      '0239 contract: two calling releases were deployed, so a caller picks its lane';
  end if;

  -- ---------------------------------------------------------------------
  -- 3. The caller's release and lane are both discarded
  -- ---------------------------------------------------------------------
  -- The forged claim: an evaluation deployment, a caller naming the shadow
  -- release and asking for shadow. `0239` refused an unbound manifest and still
  -- let the caller choose among bound ones; the database chooses now.
  insert into semantic_private.model_invocations
    (input_hash, model_id, model_revision, prompt_version, grammar_version,
     output_schema_hash, batch_items, status, release_manifest_id,
     model_lane_mode)
  values ('p2', 'm', 'r', 'qwen_extractor_v5', 'semantic_grammar_v3',
          repeat('0', 64), 1, 'succeeded', shadow_release, 'shadow')
  returning id, model_lane_mode, release_manifest_id
       into eval_call, lane, named;
  if lane <> 'evaluation' then
    raise exception '0239 contract: a call ran as % under an evaluation deployment', lane;
  end if;
  if named <> evaluation_release then
    raise exception '0239 contract: a call chose its own release';
  end if;

  -- A release nobody deployed is likewise ignored rather than honoured.
  insert into semantic_private.model_invocations
    (input_hash, model_id, model_revision, prompt_version, grammar_version,
     output_schema_hash, batch_items, status, release_manifest_id)
  values ('p2b', 'm', 'r', 'qwen_extractor_v5', 'semantic_grammar_v3',
          repeat('0', 64), 1, 'succeeded', floating)
  returning release_manifest_id into named;
  if named <> evaluation_release then
    raise exception '0239 contract: an undeployed release was honoured';
  end if;

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
  -- 4. Evaluation is fixture-only
  -- ---------------------------------------------------------------------
  raised := false;
  begin
    insert into semantic_private.model_invocations
      (user_id, input_hash, model_id, model_revision, prompt_version,
       grammar_version, output_schema_hash, batch_items, status,
       release_manifest_id)
    values (alice, 'p3', 'm', 'r', 'qwen_extractor_v5', 'semantic_grammar_v3',
            repeat('0', 64), 1, 'succeeded', evaluation_release);
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

  -- A fixture item is what that lane may record.
  insert into semantic_private.model_invocation_items
    (invocation_id, item_index, logical_extraction_key, outcome)
  values (eval_call, 1, 'probe:fixture', 'succeeded');

  -- ---------------------------------------------------------------------
  -- 5. Shadow: the lineage triple, and the evidence's own observation
  -- ---------------------------------------------------------------------
  update ontology.deployment_slots
     set release_manifest_id = shadow_release where slot = 'canary';

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
  insert into semantic_private.observations
    (user_id, ingestion_run_id, source_code, data_type, observation_kind,
     action_type, source_item_hmac, record_fingerprint, payload_schema_version,
     normalized_payload, privacy_class)
  values (alice, run_id, 'apple_music', 'library_song', 'catalog_entity',
          'library_song', repeat(md5('0239-e'), 2), repeat(md5('0239-f'), 2),
          'synthetic-v0.3.1', '{}'::jsonb, 'public_catalog')
  returning id into other_obs;
  insert into semantic_private.source_text_evidence
    (user_id, observation_id, encrypted_text, encryption_key_version,
     retention_class, expires_at)
  values (alice, obs, '\x01'::bytea, 'k-v1', 'provider_catalog_text',
          now() + interval '30 days')
  returning id into ev;
  insert into semantic_private.source_text_evidence
    (user_id, observation_id, encrypted_text, encryption_key_version,
     retention_class, expires_at)
  values (alice, other_obs, '\x02'::bytea, 'k-v1', 'provider_catalog_text',
          now() + interval '30 days')
  returning id into other_ev;

  insert into semantic_private.model_invocations
    (user_id, input_hash, model_id, model_revision, prompt_version,
     grammar_version, output_schema_hash, batch_items, status,
     release_manifest_id)
  values (alice, 'p4', 'm', 'r', 'qwen_extractor_v5', 'semantic_grammar_v3',
          repeat('0', 64), 1, 'succeeded', shadow_release)
  returning id into call_id;

  -- Two thirds of the lineage is refused, on a failure as much as a success.
  raised := false;
  begin
    insert into semantic_private.model_invocation_items
      (invocation_id, item_index, user_id, observation_id,
       logical_extraction_key, outcome)
    values (call_id, 0, alice, obs, 'probe:two-thirds', 'timeout');
  exception when check_violation then raised := true;
  end;
  if not raised then
    raise exception
      '0239 contract: a failure carried two thirds of its lineage, so an erasure could not find it';
  end if;

  -- **Evidence from a different observation of the same account.** Two separate
  -- foreign keys each held their own end and never tied them together.
  raised := false;
  begin
    insert into semantic_private.model_invocation_items
      (invocation_id, item_index, user_id, observation_id,
       source_text_evidence_id, logical_extraction_key, outcome, mention_count)
    values (call_id, 1, alice, obs, other_ev, 'probe:wrong-evidence',
            'succeeded', 1);
  exception when foreign_key_violation then raised := true;
  end;
  if not raised then
    raise exception
      '0239 contract: evidence from another observation was accepted for this one';
  end if;

  -- The matching triple is accepted, so the refusals are about the relationship
  -- rather than about the shape.
  insert into semantic_private.model_invocation_items
    (invocation_id, item_index, user_id, observation_id,
     source_text_evidence_id, logical_extraction_key, outcome, mention_count)
  values (call_id, 2, alice, obs, ev, 'probe:live', 'succeeded', 1);

  -- Redacted evidence stops a success.
  update semantic_private.source_text_evidence
     set refresh_status = 'deleted', deleted_at = now(), encrypted_text = null
   where id = ev;
  raised := false;
  begin
    insert into semantic_private.model_invocation_items
      (invocation_id, item_index, user_id, observation_id,
       source_text_evidence_id, logical_extraction_key, outcome, mention_count)
    values (call_id, 3, alice, obs, ev, 'probe:redacted', 'succeeded', 1);
  exception when others then raised := true;
  end;
  if not raised then
    raise exception '0239 contract: a success committed against redacted text';
  end if;

  -- ...and does not stop the failure that records it, or `source_stale` would
  -- be unrecordable.
  insert into semantic_private.model_invocation_items
    (invocation_id, item_index, user_id, observation_id,
     source_text_evidence_id, logical_extraction_key, outcome)
  values (call_id, 4, alice, obs, ev, 'probe:stale', 'source_stale');

  -- ---------------------------------------------------------------------
  -- 6. An item cannot point at another account's observation
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
       source_text_evidence_id, logical_extraction_key, outcome)
    values (call_id, 5, alice, bob_obs, other_ev, 'probe:cross-user', 'timeout');
  exception when foreign_key_violation then raised := true;
  end;
  if not raised then
    raise exception
      '0239 contract: an item named another account''s observation';
  end if;

  raise notice '0239 contract: the database picks the release and the lineage holds';
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

-- **What the role is, not only what it is granted.** It carries `bypassrls`, so
-- a path to it is a path past every policy in the schema — and a role reachable
-- by `set role` from the deterministic worker is not a second identity, it is
-- the first one wearing another name. Grants alone would not have caught that.

do $$
declare
  r record;
  client text;
begin
  if pg_has_role('semantic_worker', 'semantic_model_worker', 'MEMBER') then
    raise exception
      '0239 contract: semantic_worker can set role to semantic_model_worker';
  end if;
  if pg_has_role('semantic_model_worker', 'semantic_worker', 'MEMBER') then
    raise exception
      '0239 contract: semantic_model_worker can set role to semantic_worker';
  end if;
  if pg_has_role('semantic_model_worker', 'semantic_ingestor', 'MEMBER')
     or pg_has_role('semantic_ingestor', 'semantic_model_worker', 'MEMBER') then
    raise exception
      '0239 contract: the model and ingestion identities can reach each other';
  end if;

  foreach client in array array['anon', 'authenticated', 'service_role'] loop
    if exists (select 1 from pg_roles where rolname = client)
       and pg_has_role(client, 'semantic_model_worker', 'MEMBER') then
      raise exception '0239 contract: % can set role to semantic_model_worker', client;
    end if;
  end loop;

  select rolcanlogin, rolinherit, rolsuper, rolcreaterole, rolcreatedb,
         rolbypassrls
    into r from pg_roles where rolname = 'semantic_model_worker';
  if r is null then
    raise exception '0239 contract: semantic_model_worker does not exist';
  end if;
  if r.rolcanlogin then
    raise exception '0239 contract: semantic_model_worker can log in directly';
  end if;
  if r.rolinherit then
    raise exception '0239 contract: semantic_model_worker inherits privileges';
  end if;
  if r.rolsuper or r.rolcreaterole or r.rolcreatedb then
    raise exception
      '0239 contract: semantic_model_worker holds an administrative attribute';
  end if;
  if not r.rolbypassrls then
    raise exception
      '0239 contract: semantic_model_worker lost bypassrls, so its refusals now come from RLS rather than its grants';
  end if;
end;
$$;

rollback;
