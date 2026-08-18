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
  shadow_release uuid;
  version uuid;
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

  -- **A deployed release, because 0239 stopped an invocation naming its own
  -- lane.** This file used to insert `model_lane_mode = 'shadow'` with no
  -- manifest at all and then assert that call could create a user mention —
  -- which made the green here a verification of the bypass rather than a
  -- refusal of it. The lane now comes from a manifest a deployment slot points
  -- at, and the caller's value is discarded.
  select id into version from ontology.versions where status = 'published';

  insert into ontology.release_manifests
    (base_ontology_version_id, compiled_contract_sha256, workbook_sha256,
     schema_sha256, release_build_sha256, database_fingerprint_sha256,
     environment, promotion_decision, model_lane_mode,
     tokenizer_runtime_manifest_sha256, extraction_contract_manifest_sha256,
     gateway_image_digest, serving_image_digest, prompt_version, grammar_version)
  values (version, repeat('a', 64), repeat('b', 64), repeat('c', 64),
          repeat('d', 64), repeat('e', 64), 'contract_probe', 'pending',
          'shadow', repeat('1', 64), repeat('2', 64), 'sha256:x', 'sha256:y',
          'qwen_extractor_v5', 'semantic_grammar_v3')
  returning id into shadow_release;

  -- **One release in force.** `0240` refuses a second calling-lane deployment,
  -- because three slots to choose from is a caller choosing its lane one
  -- indirection along. The fixture case below runs under this same release: an
  -- item with no user cannot back a user's mention whatever lane it ran in.
  insert into ontology.deployment_slots
    (slot, ontology_version_id, release_manifest_id)
  values ('shadow', version, shadow_release);

  insert into semantic_private.model_invocations
    (user_id, input_hash, model_id, model_revision, prompt_version,
     grammar_version, output_schema_hash, batch_items, status,
     release_manifest_id)
  values (alice, 'probe2', 'Qwen/Qwen3.5-9B', 'rev', 'qwen_extractor_v5',
          'semantic_grammar_v3', repeat('0', 64), 1, 'succeeded', shadow_release)
  returning id into shadow_call;

  insert into semantic_private.model_invocation_items
    (invocation_id, item_index, user_id, observation_id,
     source_text_evidence_id, logical_extraction_key, outcome, mention_count)
  values (shadow_call, 0, alice, obs, evidence, 'probe:ok', 'succeeded', 1)
  returning id into ok_item;
  insert into semantic_private.model_invocation_items
    (invocation_id, item_index, user_id, observation_id,
     source_text_evidence_id, logical_extraction_key, outcome)
  values (shadow_call, 1, alice, obs, evidence, 'probe:overflow', 'output_overflow')
  returning id into bad_item;
  -- An evaluation item is fixture-only now, so it cannot carry the user and
  -- observation this file used to give it. The refusal it was written to prove
  -- has moved one table earlier and is asserted in 0239's contract; what it can
  -- still show here is that an item with no user cannot back a user's mention.
  insert into semantic_private.model_invocation_items
    (invocation_id, item_index, logical_extraction_key, outcome, mention_count)
  values (shadow_call, 4, 'probe:fixture-two', 'succeeded', 1)
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
  -- A real deletion, payload and all. `0238` added
  -- `source_text_evidence_payload_location_check`, so marking the row deleted
  -- while it still held its text is refused — which is the constraint doing
  -- exactly what it was added for, and this test was written before it existed.
  update semantic_private.source_text_evidence
     set refresh_status = 'deleted', deleted_at = now(), encrypted_text = null
   where id = evidence;
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
