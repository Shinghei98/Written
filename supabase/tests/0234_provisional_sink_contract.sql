-- 0234 — a typed exact miss becomes one private candidate and nothing more.
--
-- Stage 1A's plumbing fixture. It calls the lane's real functions rather than
-- restating their statements, which is the reason `0234` put them in SQL: a
-- contract file can seed rows, call a function and read the result back, and
-- cannot reach a string constant in a Lambda bundle.
--
-- The required zeros are the point. A sink that mints an identity is only safe
-- if nothing downstream of it moves.
--
-- Everything runs against seeded rows and rolls back.

begin;

do $$
declare
  alice      uuid := '00000000-0000-4000-8000-00000000a11c';
  bob        uuid := '00000000-0000-4000-8000-00000000b0b0';
  version    uuid;
  run_id     uuid;
  obs        uuid;
  obs_two    uuid;
  m_work     uuid;
  m_creator  uuid;
  m_second   uuid;
  revisions  bigint;
  assertions bigint;
  result     record;
  n          integer;
begin
  insert into auth.users (id, email) values
    (alice, 'alice@example.invalid'), (bob, 'bob@example.invalid')
  on conflict (id) do nothing;

  select id into version from ontology.versions where status = 'published';
  if version is null then
    raise exception '0234 contract: no published ontology version';
  end if;
  select count(*) into revisions from ontology.concept_revisions;
  select count(*) into assertions from semantic_private.user_assertions;

  -- ---------------------------------------------------------------------
  -- Seed: two mentions on one observation, one allowlisted and one not
  -- ---------------------------------------------------------------------
  insert into semantic_private.ingestion_runs
    (user_id, source_code, connector_version, input_hash, status)
  values (alice, 'apple_music', 'contract-probe', 'contract_probe_0234', 'running')
  returning id into run_id;

  insert into semantic_private.observations
    (user_id, ingestion_run_id, source_code, data_type, observation_kind,
     action_type, source_item_hmac, record_fingerprint,
     payload_schema_version, normalized_payload, privacy_class)
  values (alice, run_id, 'apple_music', 'library_song', 'catalog_entity',
          'library_song', repeat(md5('0234-obs-a'), 2),
          repeat(md5('0234-fp-a'), 2), 'synthetic-v0.3.1', '{}'::jsonb,
          'public_catalog')
  returning id into obs;

  insert into semantic_private.observations
    (user_id, ingestion_run_id, source_code, data_type, observation_kind,
     action_type, source_item_hmac, record_fingerprint,
     payload_schema_version, normalized_payload, privacy_class)
  values (alice, run_id, 'apple_music', 'library_song', 'catalog_entity',
          'library_song', repeat(md5('0234-obs-b'), 2),
          repeat(md5('0234-fp-b'), 2), 'synthetic-v0.3.1', '{}'::jsonb,
          'public_catalog')
  returning id into obs_two;

  -- `work` is allowlisted. `creator` is not, and the refusal is what keeps a
  -- performer credit from claiming a form it does not know.
  insert into semantic_private.observation_mentions
    (observation_id, user_id, mention_text, normalized_text, mention_role,
     source_field, extraction_method, type_hint, confidence,
     safe_for_global_mining, safe_for_external_resolution, evidence_weight)
  values (obs, alice, 'Nothing In This Ontology', 'nothing in this ontology',
          'work', 'title', 'projection_field', 'work', 1.0, false, false, 1.0)
  returning id into m_work;

  insert into semantic_private.observation_mentions
    (observation_id, user_id, mention_text, normalized_text, mention_role,
     source_field, extraction_method, type_hint, confidence,
     safe_for_global_mining, safe_for_external_resolution, evidence_weight)
  values (obs, alice, 'Some Performer', 'some performer', 'creator',
          'primary_performer', 'projection_field', 'creator', 1.0,
          false, false, 1.0)
  returning id into m_creator;

  -- A second observation naming the same work. One identity, two pieces of
  -- evidence — the dedup the fixture is here to show.
  insert into semantic_private.observation_mentions
    (observation_id, user_id, mention_text, normalized_text, mention_role,
     source_field, extraction_method, type_hint, confidence,
     safe_for_global_mining, safe_for_external_resolution, evidence_weight)
  values (obs_two, alice, 'NOTHING IN THIS ONTOLOGY', 'nothing in this ontology',
          'work', 'title', 'projection_field', 'work', 1.0, false, false, 1.0)
  returning id into m_second;

  insert into semantic_private.mention_resolutions
    (user_id, mention_id, resolution, route_id, resolver_version, confidence,
     evaluated_ontology_version_id)
  select alice, id, 'unresolved', 'exact_label', 'exact-0.1.0', 0.0, version
    from (values (m_work), (m_creator), (m_second)) as s(id);

  -- ---------------------------------------------------------------------
  -- 1. The lane mints one identity for the allowlisted role and none for the other
  -- ---------------------------------------------------------------------
  select * into result
    from semantic_private.provision_exact_misses(alice, version);
  if result.minted <> 1 then
    raise exception '0234 contract: minted % identities, expected 1', result.minted;
  end if;
  if result.provisioned <> 2 then
    raise exception
      '0234 contract: wrote % provisional verdicts, expected 2 (one per mention)',
      result.provisioned;
  end if;

  select count(*) into n from semantic_private.provisional_entities
   where user_id = alice and normalized_label = 'some performer';
  if n <> 0 then
    raise exception
      '0234 contract: a creator projection minted an identity it cannot type truthfully';
  end if;

  -- ---------------------------------------------------------------------
  -- 2. The exact verdict is preserved, not replaced
  -- ---------------------------------------------------------------------
  select count(*) into n from semantic_private.current_mention_resolutions
   where user_id = alice and mention_id = m_work
     and route_id = 'exact_label' and resolution = 'unresolved';
  if n <> 1 then
    raise exception '0234 contract: the exact verdict did not survive the fallback';
  end if;
  select count(*) into n from semantic_private.current_mention_resolutions
   where user_id = alice and mention_id = m_work
     and route_id = 'projection_personal_v1'
     and resolution = 'personal_provisional';
  if n <> 1 then
    raise exception '0234 contract: the fallback verdict is not current';
  end if;

  -- ---------------------------------------------------------------------
  -- 3. The armer can see the new stage's work, and stops once it is done
  -- ---------------------------------------------------------------------
  -- `0232` is the migration that had to teach this stage a work test matching
  -- what its statement writes. The provisional branch is new, so it gets the
  -- same question asked of it in both directions rather than assumed.
  delete from semantic_private.worker_jobs where user_id = alice;
  perform semantic_private.arm_candidate_overlay(alice);
  select count(*) into n from semantic_private.worker_jobs
   where user_id = alice and job_type = 'build_candidate_overlay';
  if n <> 1 then
    raise exception
      '0234 contract: a provisional with no candidate armed % builders, expected 1', n;
  end if;

  -- ---------------------------------------------------------------------
  -- 4. One candidate, and one support row per observation
  -- ---------------------------------------------------------------------
  select * into result
    from semantic_private.build_provisional_candidates(alice, 'affinity_to', 500);
  if result.candidates <> 1 then
    raise exception '0234 contract: built % candidates, expected 1', result.candidates;
  end if;
  if result.links <> 2 then
    raise exception
      '0234 contract: linked % support rows, expected 2 (one per observation)',
      result.links;
  end if;

  delete from semantic_private.worker_jobs where user_id = alice;
  perform semantic_private.arm_candidate_overlay(alice);
  select count(*) into n from semantic_private.worker_jobs
   where user_id = alice and job_type = 'build_candidate_overlay';
  if n <> 0 then
    raise exception
      '0234 contract: still arming % builders after the evidence was written', n;
  end if;

  -- ---------------------------------------------------------------------
  -- 5. A full rerun is free
  -- ---------------------------------------------------------------------
  select * into result
    from semantic_private.provision_exact_misses(alice, version);
  if result.minted <> 0 or result.provisioned <> 0 then
    raise exception
      '0234 contract: a rerun minted % identities and % verdicts',
      result.minted, result.provisioned;
  end if;
  select * into result
    from semantic_private.build_provisional_candidates(alice, 'affinity_to', 500);
  if result.candidates <> 0 or result.links <> 0 then
    raise exception
      '0234 contract: a rerun built % candidates and % links',
      result.candidates, result.links;
  end if;

  -- ---------------------------------------------------------------------
  -- 6. The required zeros
  -- ---------------------------------------------------------------------
  select count(*) into n from semantic_private.user_assertions;
  if n <> assertions then
    raise exception '0234 contract: the sink wrote % user assertions', n - assertions;
  end if;
  select count(*) into n from ontology.concept_revisions;
  if n <> revisions then
    raise exception '0234 contract: the sink wrote % concept revisions', n - revisions;
  end if;
  select count(*) into n from semantic_private.model_invocations;
  if n <> 0 then
    raise exception '0234 contract: % model invocations, and no model exists', n;
  end if;

  -- ---------------------------------------------------------------------
  -- 7. Two users cannot reach one another's identities
  -- ---------------------------------------------------------------------
  select * into result
    from semantic_private.provision_exact_misses(bob, version);
  if result.minted <> 0 or result.provisioned <> 0 then
    raise exception
      '0234 contract: running the lane for bob touched % identities', result.minted;
  end if;
  select count(*) into n from semantic_private.provisional_entities
   where user_id = bob;
  if n <> 0 then
    raise exception '0234 contract: bob holds % provisional identities', n;
  end if;

  -- ---------------------------------------------------------------------
  -- 8. Account deletion takes the whole lineage
  -- ---------------------------------------------------------------------
  delete from auth.users where id = alice;

  select count(*) into n from semantic_private.provisional_entities where user_id = alice;
  if n <> 0 then
    raise exception '0234 contract: % provisional identities survived deletion', n;
  end if;
  select count(*) into n from semantic_private.user_term_candidates where user_id = alice;
  if n <> 0 then
    raise exception '0234 contract: % candidates survived deletion', n;
  end if;
  select count(*) into n from semantic_private.candidate_support_links where user_id = alice;
  if n <> 0 then
    raise exception '0234 contract: % support links survived deletion', n;
  end if;

  raise notice '0234 contract: the provisional sink is safe, idempotent and reversible';
end;
$$;

rollback;
