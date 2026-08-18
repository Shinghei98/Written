-- 0237 — no model mention without a successful, in-lane invocation item.
--
-- The mention is the choke point: every model-derived row descends from one, so
-- a rule the ancestor cannot break is a rule about all of them. Nothing writes
-- these yet, which is why each property is asserted before a gateway can.
--
-- Everything runs against seeded rows and rolls back.

begin;

do $$
declare
  alice     uuid := '00000000-0000-4000-8000-00000000a11c';
  run_id    uuid;
  obs       uuid;
  evidence  uuid;
  eval_call uuid;
  shadow_call uuid;
  ok_item   uuid;
  bad_item  uuid;
  eval_item uuid;
  fixture   uuid;
  stale_item uuid;
  raised    boolean;
begin
  insert into auth.users (id, email) values (alice, 'alice@example.invalid')
  on conflict (id) do nothing;

  insert into semantic_private.ingestion_runs
    (user_id, source_code, connector_version, input_hash, status)
  values (alice, 'apple_music', 'contract-probe', 'probe_0237', 'running')
  returning id into run_id;

  insert into semantic_private.observations
    (user_id, ingestion_run_id, source_code, data_type, observation_kind,
     action_type, source_item_hmac, record_fingerprint,
     payload_schema_version, normalized_payload, privacy_class)
  values (alice, run_id, 'apple_music', 'library_song', 'catalog_entity',
          'library_song', repeat(md5('0237-obs'), 2), repeat(md5('0237-fp'), 2),
          'synthetic-v0.3.1', '{}'::jsonb, 'public_catalog')
  returning id into obs;

  insert into semantic_private.source_text_evidence
    (user_id, observation_id, encrypted_text, encryption_key_version,
     retention_class, expires_at, refresh_status)
  values (alice, obs, '\x00'::bytea, 'probe-key-v1', 'provider_catalog_text',
          now() + interval '30 days', 'current')
  returning id into evidence;

  insert into semantic_private.model_invocations
    (user_id, input_hash, model_id, model_revision, prompt_version,
     grammar_version, output_schema_hash, batch_items, status, model_lane_mode)
  values (alice, 'probe', 'Qwen/Qwen3.5-9B', 'rev', 'qwen_extractor_v5',
          'semantic_grammar_v3', repeat('0', 64), 1, 'succeeded', 'evaluation')
  returning id into eval_call;

  insert into semantic_private.model_invocations
    (user_id, input_hash, model_id, model_revision, prompt_version,
     grammar_version, output_schema_hash, batch_items, status, model_lane_mode)
  values (alice, 'probe2', 'Qwen/Qwen3.5-9B', 'rev', 'qwen_extractor_v5',
          'semantic_grammar_v3', repeat('0', 64), 1, 'succeeded', 'shadow')
  returning id into shadow_call;

  insert into semantic_private.model_invocation_items
    (invocation_id, item_index, user_id, observation_id, logical_extraction_key,
     outcome, mention_count)
  values (shadow_call, 0, alice, obs, 'probe:ok', 'succeeded', 1)
  returning id into ok_item;
  insert into semantic_private.model_invocation_items
    (invocation_id, item_index, user_id, observation_id, logical_extraction_key,
     outcome)
  values (shadow_call, 1, alice, obs, 'probe:overflow', 'output_overflow')
  returning id into bad_item;
  insert into semantic_private.model_invocation_items
    (invocation_id, item_index, user_id, observation_id, logical_extraction_key,
     outcome, mention_count)
  values (eval_call, 0, alice, obs, 'probe:eval', 'succeeded', 1)
  returning id into eval_item;
  -- A fixture belongs to nobody.
  insert into semantic_private.model_invocation_items
    (invocation_id, item_index, logical_extraction_key, outcome, mention_count)
  values (shadow_call, 2, 'probe:fixture', 'succeeded', 1)
  returning id into fixture;
  insert into semantic_private.model_invocation_items
    (invocation_id, item_index, user_id, observation_id,
     source_text_evidence_id, logical_extraction_key, outcome, mention_count)
  values (shadow_call, 3, alice, obs, evidence, 'probe:stale', 'succeeded', 1)
  returning id into stale_item;

  -- ---------------------------------------------------------------------
  -- 1. The deterministic lanes are untouched, and may not borrow lineage
  -- ---------------------------------------------------------------------
  insert into semantic_private.observation_mentions
    (observation_id, user_id, mention_text, normalized_text, mention_role,
     source_field, extraction_method, type_hint, confidence,
     safe_for_global_mining, safe_for_external_resolution, evidence_weight)
  values (obs, alice, 'Deterministic', 'deterministic', 'work', 'title',
          'projection_field', 'work', 1.0, false, false, 1.0);

  raised := false;
  begin
    insert into semantic_private.observation_mentions
      (observation_id, user_id, mention_text, normalized_text, mention_role,
       source_field, extraction_method, type_hint, confidence,
       safe_for_global_mining, safe_for_external_resolution, evidence_weight,
       model_invocation_item_id)
    values (obs, alice, 'Borrowed', 'borrowed', 'album', 'title',
            'projection_field', 'work', 1.0, false, false, 1.0, ok_item);
  exception when others then raised := true;
  end;
  if not raised then
    raise exception '0237 contract: a projection mention claimed model lineage';
  end if;

  -- ---------------------------------------------------------------------
  -- 2..6. What a model mention may descend from
  -- ---------------------------------------------------------------------
  raised := false;
  begin
    insert into semantic_private.observation_mentions
      (observation_id, user_id, mention_text, normalized_text, mention_role,
       source_field, extraction_method, type_hint, confidence,
       safe_for_global_mining, safe_for_external_resolution, evidence_weight)
    values (obs, alice, 'Orphan', 'orphan', 'primary_subject', 'title',
            'model_proposed', 'work', 1.0, false, false, 1.0);
  exception when others then raised := true;
  end;
  if not raised then
    raise exception '0237 contract: a model mention named no invocation item';
  end if;

  raised := false;
  begin
    insert into semantic_private.observation_mentions
      (observation_id, user_id, mention_text, normalized_text, mention_role,
       source_field, extraction_method, type_hint, confidence,
       safe_for_global_mining, safe_for_external_resolution, evidence_weight,
       model_invocation_item_id)
    values (obs, alice, 'Overflowed', 'overflowed', 'primary_subject', 'title',
            'model_proposed', 'work', 1.0, false, false, 1.0, bad_item);
  exception when others then raised := true;
  end;
  if not raised then
    raise exception '0237 contract: a model mention descended from an overflow';
  end if;

  raised := false;
  begin
    insert into semantic_private.observation_mentions
      (observation_id, user_id, mention_text, normalized_text, mention_role,
       source_field, extraction_method, type_hint, confidence,
       safe_for_global_mining, safe_for_external_resolution, evidence_weight,
       model_invocation_item_id)
    values (obs, alice, 'Evaluated', 'evaluated', 'primary_subject', 'title',
            'model_proposed', 'work', 1.0, false, false, 1.0, eval_item);
  exception when others then raised := true;
  end;
  if not raised then
    raise exception
      '0237 contract: an evaluation invocation created a user mention';
  end if;

  -- A fixture item has no user, so the composite key has no row to point at —
  -- refused before the trigger looks.
  raised := false;
  begin
    insert into semantic_private.observation_mentions
      (observation_id, user_id, mention_text, normalized_text, mention_role,
       source_field, extraction_method, type_hint, confidence,
       safe_for_global_mining, safe_for_external_resolution, evidence_weight,
       model_invocation_item_id)
    values (obs, alice, 'Fixture', 'fixture', 'primary_subject', 'title',
            'model_proposed', 'work', 1.0, false, false, 1.0, fixture);
  exception when others then raised := true;
  end;
  if not raised then
    raise exception '0237 contract: a fixture item backed a user mention';
  end if;

  -- ---------------------------------------------------------------------
  -- 7. A shadow item that succeeded is accepted
  -- ---------------------------------------------------------------------
  -- The refusals above are about lineage rather than about the shape, which
  -- only an accepted case can show.
  insert into semantic_private.observation_mentions
    (observation_id, user_id, mention_text, normalized_text, mention_role,
     source_field, extraction_method, type_hint, confidence,
     safe_for_global_mining, safe_for_external_resolution, evidence_weight,
     model_invocation_item_id)
  values (obs, alice, 'Accepted', 'accepted', 'primary_subject', 'title',
          'model_proposed', 'work', 1.0, false, false, 1.0, ok_item);

  -- ---------------------------------------------------------------------
  -- 8. Deleted source text stops the commit
  -- ---------------------------------------------------------------------
  update semantic_private.source_text_evidence
     set refresh_status = 'deleted', deleted_at = now() where id = evidence;
  raised := false;
  begin
    insert into semantic_private.observation_mentions
      (observation_id, user_id, mention_text, normalized_text, mention_role,
       source_field, extraction_method, type_hint, confidence,
       safe_for_global_mining, safe_for_external_resolution, evidence_weight,
       model_invocation_item_id)
    values (obs, alice, 'Stale', 'stale', 'primary_subject', 'title',
            'model_proposed', 'work', 1.0, false, false, 1.0, stale_item);
  exception when others then raised := true;
  end;
  if not raised then
    raise exception
      '0237 contract: a mention committed against deleted source text';
  end if;

  raise notice '0237 contract: the mode boundary holds at the write';
end;
$$;

rollback;
