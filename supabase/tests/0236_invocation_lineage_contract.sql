-- 0236 — an invocation item is append-only, attributable, and cannot carry
-- mentions it did not earn.
--
-- Nothing writes these rows yet, which is why the properties are asserted now:
-- every one of them is latent while the table is empty and load-bearing the
-- moment a gateway fills it.
--
-- Everything runs against seeded rows and rolls back.

begin;

do $$
declare
  alice   uuid := '00000000-0000-4000-8000-00000000a11c';
  call_id uuid;
  first   uuid;
  version uuid;
  release uuid;
  run_id  uuid;
  obs     uuid;
  ev      uuid;
  raised  boolean;
  n       integer;
  columns text;
begin
  insert into auth.users (id, email) values (alice, 'alice@example.invalid')
  on conflict (id) do nothing;

  -- **A deployed shadow release.** `0239` derives the lane from a manifest a
  -- deployment slot points at, so an invocation can no longer state its own —
  -- and an evaluation lane could not carry the user-scoped items this file is
  -- about, because evaluation is fixture-only.
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
  returning id into release;
  insert into ontology.deployment_slots (slot, ontology_version_id, release_manifest_id)
  values ('shadow', version, release);

  -- A user-backed success must name live source text, so the fixture needs one.
  insert into semantic_private.ingestion_runs
    (user_id, source_code, connector_version, input_hash, status)
  values (alice, 'apple_music', 'contract-probe', 'probe_0236', 'running')
  returning id into run_id;
  insert into semantic_private.observations
    (user_id, ingestion_run_id, source_code, data_type, observation_kind,
     action_type, source_item_hmac, record_fingerprint,
     payload_schema_version, normalized_payload, privacy_class)
  values (alice, run_id, 'apple_music', 'library_song', 'catalog_entity',
          'library_song', repeat(md5('0236-obs'), 2), repeat(md5('0236-fp'), 2),
          'synthetic-v0.3.1', '{}'::jsonb, 'public_catalog')
  returning id into obs;
  insert into semantic_private.source_text_evidence
    (user_id, observation_id, encrypted_text, encryption_key_version,
     retention_class, expires_at)
  values (alice, obs, '\x01'::bytea, 'probe-key-v1', 'provider_catalog_text',
          now() + interval '30 days')
  returning id into ev;

  insert into semantic_private.model_invocations
    (user_id, input_hash, model_id, model_revision, prompt_version,
     grammar_version, output_schema_hash, batch_items,
     release_manifest_id)
  values (alice, 'probe-input', 'Qwen/Qwen3.5-9B', 'probe-rev',
          'qwen_extractor_v5', 'semantic_grammar_v3', repeat('0', 64), 1,
          release)
  returning id into call_id;

  -- ---------------------------------------------------------------------
  -- 1. Only a succeeded item may carry mentions
  -- ---------------------------------------------------------------------
  -- The storage half of the rule the wire validator already enforces: a
  -- structural failure is not evidence about a person, and neither is an
  -- abstention.
  raised := false;
  begin
    insert into semantic_private.model_invocation_items
      (invocation_id, item_index, user_id, observation_id,
       source_text_evidence_id, logical_extraction_key, outcome, mention_count)
    values (call_id, 0, alice, obs, ev, 'probe:timeout', 'timeout', 2);
  exception when check_violation then raised := true;
  end;
  if not raised then
    raise exception '0236 contract: a timed-out item carried mentions';
  end if;

  raised := false;
  begin
    insert into semantic_private.model_invocation_items
      (invocation_id, item_index, user_id, observation_id,
       source_text_evidence_id, logical_extraction_key, outcome, mention_count)
    values (call_id, 0, alice, obs, ev, 'probe:abstained', 'semantic_abstention', 1);
  exception when check_violation then raised := true;
  end;
  if not raised then
    raise exception '0236 contract: an abstention carried mentions';
  end if;

  insert into semantic_private.model_invocation_items
    (invocation_id, item_index, user_id, observation_id,
     source_text_evidence_id, logical_extraction_key, outcome,
     mention_count, fingerprint_key_version, input_fingerprint)
  values (call_id, 0, alice, obs, ev, 'probe:work', 'succeeded', 3,
          'lineage-v1', '\x0102'::bytea)
  returning id into first;

  -- ---------------------------------------------------------------------
  -- 2. A fingerprint names the key that made it
  -- ---------------------------------------------------------------------
  -- An unsalted digest of a low-entropy title is a cross-account correlation
  -- handle. A keyed one that cannot say which key is the same thing with a
  -- longer name.
  raised := false;
  begin
    insert into semantic_private.model_invocation_items
      (invocation_id, item_index, user_id, observation_id,
       source_text_evidence_id, logical_extraction_key, outcome,
       input_fingerprint)
    values (call_id, 1, alice, obs, ev, 'probe:unkeyed', 'schema_invalid',
            '\x03'::bytea);
  exception when check_violation then raised := true;
  end;
  if not raised then
    raise exception '0236 contract: a fingerprint was stored with no key version';
  end if;

  -- ---------------------------------------------------------------------
  -- 3. One standing success per logical extraction
  -- ---------------------------------------------------------------------
  raised := false;
  begin
    insert into semantic_private.model_invocation_items
      (invocation_id, item_index, user_id, observation_id,
       source_text_evidence_id, logical_extraction_key, outcome)
    values (call_id, 2, alice, obs, ev, 'probe:work', 'succeeded');
  exception when unique_violation then raised := true;
  end;
  if not raised then
    raise exception '0236 contract: the same work succeeded twice';
  end if;

  -- A failed attempt at the same work is not a duplicate; it is what a retry
  -- ancestry is made of.
  insert into semantic_private.model_invocation_items
    (invocation_id, item_index, user_id, observation_id,
     source_text_evidence_id, logical_extraction_key, outcome,
     attempt, parent_item_id)
  values (call_id, 3, alice, obs, ev, 'probe:work', 'output_overflow', 2, first);

  -- ---------------------------------------------------------------------
  -- 4. A retry is a later attempt
  -- ---------------------------------------------------------------------
  raised := false;
  begin
    insert into semantic_private.model_invocation_items
      (invocation_id, item_index, user_id, observation_id,
       source_text_evidence_id, logical_extraction_key, outcome,
       attempt, parent_item_id)
    values (call_id, 4, alice, obs, ev, 'probe:first-attempt', 'timeout', 1, first);
  exception when check_violation then raised := true;
  end;
  if not raised then
    raise exception '0236 contract: a first attempt claimed a parent';
  end if;

  -- ---------------------------------------------------------------------
  -- 5. Lineage is all three or none
  -- ---------------------------------------------------------------------
  -- `0240` replaced "an observation-scoped item names a user" with the whole
  -- relationship: user, observation and evidence together, on failures as well
  -- as successes, because a timeout on somebody's title is still a row about
  -- their data and an erasure that walks evidence has to find it.
  raised := false;
  begin
    insert into semantic_private.model_invocation_items
      (invocation_id, item_index, user_id, observation_id,
       logical_extraction_key, outcome)
    values (call_id, 5, alice, obs, 'probe:two-thirds', 'timeout');
  exception when check_violation then raised := true;
  end;
  if not raised then
    raise exception '0236 contract: an item carried two thirds of its lineage';
  end if;

  -- ---------------------------------------------------------------------
  -- 6. Append-only
  -- ---------------------------------------------------------------------
  raised := false;
  begin
    update semantic_private.model_invocation_items
       set outcome = 'timeout' where id = first;
  exception when others then raised := true;
  end;
  if not raised then
    raise exception '0236 contract: an outcome was rewritten after the fact';
  end if;

  raised := false;
  begin
    delete from semantic_private.model_invocation_items where id = first;
  exception when others then raised := true;
  end;
  if not raised then
    raise exception '0236 contract: an invocation item was deleted';
  end if;

  -- ---------------------------------------------------------------------
  -- 7. No column here may hold provider text
  -- ---------------------------------------------------------------------
  -- The allowlist lives in the contract rather than the migration, because a
  -- later column is a decision somebody should have to make here — and an
  -- allowlist frozen inside an applied migration could never be updated.
  select string_agg(column_name, ', ' order by column_name) into columns
    from information_schema.columns
   where table_schema = 'semantic_private'
     and table_name = 'model_invocation_items'
     and column_name not in (
       'id', 'invocation_id', 'item_index', 'user_id', 'observation_id',
       'source_text_evidence_id', 'source_revision', 'logical_extraction_key',
       'attempt', 'parent_item_id', 'outcome', 'mention_count',
       'estimated_output_tokens', 'actual_output_tokens', 'input_fingerprint',
       'output_fingerprint', 'fingerprint_key_version', 'created_at');
  if columns is not null then
    raise exception
      '0236 contract: unreviewed columns on model_invocation_items: %. No column '
      'here may hold a prompt, title, description, response body or provider '
      'error message; if the new one cannot, add it to this allowlist.', columns;
  end if;

  -- ---------------------------------------------------------------------
  -- 8. Account deletion takes the lineage
  -- ---------------------------------------------------------------------
  -- The append-only guard permits the cascade once the owner is gone, which is
  -- 0204's shape: refuse while the owner exists, permit once they do not.
  delete from auth.users where id = alice;
  select count(*) into n from semantic_private.model_invocation_items
   where user_id = alice;
  if n <> 0 then
    raise exception '0236 contract: % invocation items survived the account', n;
  end if;

  raise notice '0236 contract: invocation lineage is append-only and attributable';
end;
$$;

rollback;
