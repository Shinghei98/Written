-- 0238 — retained provider text is redacted by forgetting, and the state cannot
-- disagree with the payload.
--
-- Everything runs against seeded rows and rolls back.

begin;

do $$
declare
  alice   uuid := '00000000-0000-4000-8000-00000000a11c';
  run_id  uuid;
  obs     uuid;
  ev      uuid;
  raised  boolean;
  receipt jsonb;
  n       integer;
begin
  insert into auth.users (id, email) values (alice, 'alice@example.invalid')
  on conflict (id) do nothing;
  perform set_config('request.jwt.claim.sub', alice::text, true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', alice)::text, true);

  insert into semantic_private.ingestion_runs
    (user_id, source_code, connector_version, input_hash, status)
  values (alice, 'apple_music', 'contract-probe', 'probe_0238', 'running')
  returning id into run_id;

  insert into semantic_private.observations
    (user_id, ingestion_run_id, source_code, data_type, observation_kind,
     action_type, source_item_hmac, record_fingerprint,
     payload_schema_version, normalized_payload, privacy_class)
  values (alice, run_id, 'apple_music', 'library_song', 'catalog_entity',
          'library_song', repeat(md5('0238-obs'), 2), repeat(md5('0238-fp'), 2),
          'synthetic-v0.3.1', '{}'::jsonb, 'public_catalog')
  returning id into obs;

  insert into semantic_private.source_text_evidence
    (user_id, observation_id, encrypted_text, encryption_key_version,
     retention_class, expires_at)
  values (alice, obs, '\xdeadbeef'::bytea, 'probe-key-v1',
          'provider_catalog_text', now() + interval '30 days')
  returning id into ev;

  -- ---------------------------------------------------------------------
  -- 1. The state and the payload cannot disagree
  -- ---------------------------------------------------------------------
  raised := false;
  begin
    update semantic_private.source_text_evidence
       set refresh_status = 'deleted', deleted_at = now() where id = ev;
  exception when check_violation then raised := true;
  end;
  if not raised then
    raise exception
      '0238 contract: a row was marked deleted while still holding its text';
  end if;

  raised := false;
  begin
    update semantic_private.source_text_evidence
       set encrypted_text = null where id = ev;
  exception when check_violation then raised := true;
  end;
  if not raised then
    raise exception
      '0238 contract: the text was dropped while the row still claimed to hold it';
  end if;

  -- ---------------------------------------------------------------------
  -- 2. Forgetting redacts it
  -- ---------------------------------------------------------------------
  select api.forget_distillation() into receipt;
  if (receipt ->> 'source_text_redacted')::integer <> 1 then
    raise exception '0238 contract: the receipt reported % redactions, expected 1',
      receipt ->> 'source_text_redacted';
  end if;

  select count(*) into n from semantic_private.source_text_evidence
   where id = ev and refresh_status = 'deleted' and encrypted_text is null;
  if n <> 1 then
    raise exception
      '0238 contract: retained provider text survived the erasure';
  end if;

  -- The row keeps its identity, because lineage references it and the vault
  -- does not delete rows.
  select count(*) into n from semantic_private.source_text_evidence where id = ev;
  if n <> 1 then
    raise exception '0238 contract: the erasure deleted the row instead of its content';
  end if;

  -- ---------------------------------------------------------------------
  -- 3. A second forgetting is a no-op rather than a second bump
  -- ---------------------------------------------------------------------
  select api.forget_distillation() into receipt;
  if (receipt ->> 'source_text_redacted')::integer <> 0 then
    raise exception '0238 contract: a second erasure redacted % more rows',
      receipt ->> 'source_text_redacted';
  end if;

  -- ---------------------------------------------------------------------
  -- 4. Account deletion takes the row entirely
  -- ---------------------------------------------------------------------
  delete from auth.users where id = alice;
  select count(*) into n from semantic_private.source_text_evidence where user_id = alice;
  if n <> 0 then
    raise exception '0238 contract: % source text rows survived the account', n;
  end if;

  raise notice '0238 contract: forgetting reaches the retained text';
end;
$$;

rollback;
