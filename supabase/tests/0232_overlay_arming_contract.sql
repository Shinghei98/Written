-- 0232 — the armer asks the job's question, and stops asking once it is answered.
--
-- Seeds the exact shape production was in: a candidate whose support link was
-- written against a resolution row that a later judgement superseded. Before
-- `0232` that made `build_candidate_overlay` armable forever — 209 armings for
-- one account, 214 no-op jobs — because the armer compared
-- `candidate_support_links.mention_resolution_id` against the *current* row's id
-- while the job's own anti-join is keyed on (candidate, observation, route).
--
-- The old predicate is inlined below and asserted to still be true on this data.
-- That is what makes this a regression test rather than a description: the row
-- state that used to arm is present, the discarded question still answers "yes",
-- and the shipped one answers "no".
--
-- Everything runs against seeded rows and rolls back.

begin;

do $$
declare
  alice     uuid := '00000000-0000-4000-8000-00000000a11c';
  version   uuid;
  concept   uuid;
  other     uuid;
  run_id    uuid;
  obs       uuid;
  mention   uuid;
  res_old   uuid;
  cand      uuid;
  n         integer;
  old_says  boolean;
begin
  -- ---------------------------------------------------------------------
  -- Seed
  -- ---------------------------------------------------------------------
  insert into auth.users (id, email) values (alice, 'alice@example.invalid')
  on conflict (id) do nothing;

  select id into version from ontology.versions where status = 'published';
  if version is null then
    raise exception '0232 contract: no published ontology version';
  end if;

  -- Two concepts that already live in the published version. A published
  -- version is immutable — `guard_published_version` is right to refuse a probe
  -- revision — and this contract needs no vocabulary of its own.
  select cr.concept_id into concept
    from ontology.concept_revisions cr
   where cr.ontology_version_id = version and cr.status = 'active'
   order by cr.concept_id::text limit 1;
  select cr.concept_id into other
    from ontology.concept_revisions cr
   where cr.ontology_version_id = version and cr.status = 'active'
     and cr.concept_id <> concept
   order by cr.concept_id::text limit 1;
  if other is null then
    raise exception '0232 contract: fewer than two active concepts to work with';
  end if;

  -- **Left `running`, deliberately.** `guard_new_run_running` refuses a run that
  -- starts in any other state, and `guard_observation_ingestion_run` refuses an
  -- observation whose run has already closed — evidence is written by ingestion
  -- while the run is open, which is the schema deciding who may write it.
  insert into semantic_private.ingestion_runs
    (user_id, source_code, connector_version, input_hash, status)
  values (alice, 'apple_music', 'contract-probe', 'contract_probe', 'running')
  returning id into run_id;

  -- **No `content_lineage_hmac`.** It is the calendar lane's join handle, and
  -- `private_observation_projection_is_valid_v03` refuses a public-catalog row
  -- carrying one. A library artist is the plainest public observation there is.
  insert into semantic_private.observations
    (user_id, ingestion_run_id, source_code, data_type, observation_kind,
     action_type, source_item_hmac, record_fingerprint,
     payload_schema_version, normalized_payload, privacy_class)
  values (alice, run_id, 'apple_music', 'library_artist', 'catalog_entity',
          'library_artist', repeat(md5('0232-obs-hmac'), 2),
          repeat(md5('0232-obs-fingerprint'), 2),
          'synthetic-v0.3.1', '{}'::jsonb, 'public_catalog')
  returning id into obs;

  insert into semantic_private.observation_mentions
    (observation_id, user_id, mention_text, normalized_text, mention_role,
     source_field, extraction_method, type_hint, confidence,
     safe_for_global_mining, safe_for_external_resolution, evidence_weight)
  -- **`mention_role` is the projection's own word, not the model's.** `0207`
  -- refuses any of the fifteen semantic roles on a `projection_field` mention:
  -- the legacy lane names the field it read and may not borrow a role it does
  -- not mean. Production's values here are `work`, `album`, `creator`,
  -- `composer`, `genre`, `source_work`.
  values (obs, alice, 'Contract Probe', 'contract probe', 'creator',
          'primary_performer', 'projection_field', 'creator', 1.0,
          false, false, 1.0)
  returning id into mention;

  -- The verdict the support link was written against.
  insert into semantic_private.mention_resolutions
    (user_id, mention_id, resolution, ontology_version_id, concept_id,
     route_id, resolver_version, confidence, evaluated_ontology_version_id,
     created_at)
  values (alice, mention, 'resolved_existing', version, concept,
          'exact_label', 'exact-0.1.0', 1.0, version, now() - interval '2 minutes')
  returning id into res_old;

  insert into semantic_private.user_term_candidates
    (user_id, concept_id, user_facing_predicate, confidence_tier,
     aggregate_score, primary_route_id, lifecycle_state)
  values (alice, concept, 'affinity_to', 'secondary', 0.14, 'exact_label', 'active')
  returning id into cand;

  insert into semantic_private.candidate_support_links
    (user_id, candidate_id, observation_id, mention_resolution_id, route_id,
     evidence_family_key, contribution)
  values (alice, cand, obs, res_old, 'exact_label', 'creator', 1.0);

  -- ---------------------------------------------------------------------
  -- 1. A converged account arms nothing
  -- ---------------------------------------------------------------------
  delete from semantic_private.worker_jobs where user_id = alice;
  perform semantic_private.arm_candidate_overlay(alice);
  select count(*) into n from semantic_private.worker_jobs
   where user_id = alice and job_type = 'build_candidate_overlay';
  if n <> 0 then
    raise exception
      '0232 contract: a converged account armed % build_candidate_overlay jobs', n;
  end if;

  -- ---------------------------------------------------------------------
  -- 2. A superseded verdict is not new work — the livelock
  -- ---------------------------------------------------------------------
  -- In production the superseding row came from a new ontology publish; here it
  -- comes from a new resolver version, which moves `current_mention_resolutions`
  -- the same way and needs no second published version to arrange. Either way
  -- the current row's id is no longer the one the support link recorded, which
  -- is the whole of the defect.
  insert into semantic_private.mention_resolutions
    (user_id, mention_id, resolution, ontology_version_id, concept_id,
     route_id, resolver_version, confidence, evaluated_ontology_version_id,
     created_at)
  values (alice, mention, 'resolved_existing', version, concept,
          'exact_label', 'exact-0.2.0', 1.0, version, now());

  -- The discarded question, asked of this data. It must still say yes, or this
  -- file has stopped reproducing the bug it exists for.
  select exists (
    select 1 from semantic_private.current_mention_resolutions r
     where r.user_id = alice and r.resolution = 'resolved_existing'
       and not exists (
         select 1 from semantic_private.candidate_support_links l
          where l.mention_resolution_id = r.id))
    into old_says;
  if not old_says then
    raise exception
      '0232 contract: the superseded-row state was not reproduced, so nothing here is tested';
  end if;

  delete from semantic_private.worker_jobs where user_id = alice;
  perform semantic_private.arm_candidate_overlay(alice);
  select count(*) into n from semantic_private.worker_jobs
   where user_id = alice and job_type = 'build_candidate_overlay';
  if n <> 0 then
    raise exception
      '0232 contract: a superseded verdict armed % jobs; the livelock is open', n;
  end if;

  -- ---------------------------------------------------------------------
  -- 3. A verdict that moved to another concept *is* new work
  -- ---------------------------------------------------------------------
  -- Under-arming is the failure that leaves evidence unreachable, so the
  -- predicate has to stay true for a concept with no candidate under it.
  insert into semantic_private.mention_resolutions
    (user_id, mention_id, resolution, ontology_version_id, concept_id,
     route_id, resolver_version, confidence, evaluated_ontology_version_id,
     created_at)
  values (alice, mention, 'resolved_existing', version, other,
          'exact_label', 'exact-0.3.0', 1.0, version, now() + interval '1 minute');

  delete from semantic_private.worker_jobs where user_id = alice;
  perform semantic_private.arm_candidate_overlay(alice);
  select count(*) into n from semantic_private.worker_jobs
   where user_id = alice and job_type = 'build_candidate_overlay';
  if n <> 1 then
    raise exception
      '0232 contract: a newly resolved concept armed % jobs, expected 1', n;
  end if;

  -- ---------------------------------------------------------------------
  -- 4. And once that concept has its evidence, it goes quiet again
  -- ---------------------------------------------------------------------
  insert into semantic_private.user_term_candidates
    (user_id, concept_id, user_facing_predicate, confidence_tier,
     aggregate_score, primary_route_id, lifecycle_state)
  values (alice, other, 'affinity_to', 'secondary', 0.14, 'exact_label', 'active')
  returning id into cand;
  insert into semantic_private.candidate_support_links
    (user_id, candidate_id, observation_id, mention_resolution_id, route_id,
     evidence_family_key, contribution)
  select alice, cand, obs, r.id, 'exact_label', 'creator', 1.0
    from semantic_private.current_mention_resolutions r
   where r.user_id = alice and r.mention_id = mention;

  delete from semantic_private.worker_jobs where user_id = alice;
  perform semantic_private.arm_candidate_overlay(alice);
  select count(*) into n from semantic_private.worker_jobs
   where user_id = alice and job_type = 'build_candidate_overlay';
  if n <> 0 then
    raise exception
      '0232 contract: still arming % jobs after the evidence was written', n;
  end if;

  raise notice '0232 contract: overlay arming converges';
end;
$$;

rollback;
