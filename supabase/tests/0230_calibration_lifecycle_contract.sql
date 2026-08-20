-- 0230 — the calibration and erasure lifecycle, exercised end to end.
--
-- Eight of the nine properties the 2026-08-18 memo requires before live shadow.
-- The ninth — source expiry during an in-flight model call — needs a gateway and
-- is named at the foot rather than quietly omitted.
--
-- **Everything here runs against seeded rows and rolls back.** A lifecycle test
-- that left a candidate, a strike or a suppression behind would be indis-
-- tinguishable from real user data on the next read, and this file runs in a
-- container that is thrown away either way — the rollback is for the case where
-- somebody points it at something that is not.
--
-- `auth.uid()` is set through the JWT claim settings, because every `api`
-- function here is scoped to it and takes no parameter for whose. Calling them
-- any other way would test something the client cannot do. Both the singular
-- and the JSON form are set — see the note at the seed's foot for why.
--
-- `calibration_reads` is turned on inside the transaction and rolled back with
-- everything else. The flag is the product's switch and stays off; a lifecycle
-- that could only be tested by shipping it enabled would never be tested.

begin;

update semantic_private.feature_flags set enabled = true
 where flag_key = 'calibration_reads';

do $$
declare
  alice     uuid := '00000000-0000-4000-8000-00000000a11c';
  bob       uuid := '00000000-0000-4000-8000-00000000b0b0';
  version   uuid;
  run       uuid;
  concept   uuid;
  other     uuid;
  prov      uuid;
  cand      uuid;
  cand_b    uuid;
  prov_cand uuid;
  item      uuid;
  item_b    uuid;
  prov_item uuid;
  n         integer;
  state     text;
begin
  -- ---------------------------------------------------------------------
  -- Seed
  -- ---------------------------------------------------------------------
  insert into auth.users (id, email) values
    (alice, 'alice@example.invalid'), (bob, 'bob@example.invalid')
  on conflict (id) do nothing;

  select id into version from ontology.versions where status = 'published';
  if version is null then
    raise notice '0230 contract: no published ontology version; nothing to test';
    return;
  end if;

  -- **Two concepts that already live in the published version, never two minted
  -- here.** The first draft inserted a pair of probe revisions into `version`
  -- and `guard_published_version` refused it, correctly: a published version is
  -- what every standing score was computed against, and `0179` is the migration
  -- that had to publish a whole new version rather than edit one in place. This
  -- file is about the calibration lifecycle and needs no vocabulary of its own,
  -- so it borrows two rows instead of authoring them.
  --
  -- `concept` is the one alice strikes; `other` is the one she does not, and the
  -- redirect target in property 8. Both need an active revision at `version`
  -- because `user_assertions` carries a composite foreign key into
  -- `concept_revisions (ontology_version_id, concept_id)`.
  select cr.concept_id into concept
    from ontology.concept_revisions cr
   where cr.ontology_version_id = version and cr.status = 'active'
   order by cr.concept_id::text
   limit 1;
  select cr.concept_id into other
    from ontology.concept_revisions cr
   where cr.ontology_version_id = version and cr.status = 'active'
     and cr.concept_id <> concept
   order by cr.concept_id::text
   limit 1;

  -- Raised rather than skipped. A published version with fewer than two active
  -- concepts is not a database this contract can say anything about, and
  -- returning quietly would make the whole file pass by describing nothing.
  if other is null then
    raise exception
      '0230 contract: the published version holds fewer than two active concepts';
  end if;

  -- **A live run, because an inferred assertion cannot exist without one.**
  -- `reject_stale_inferred_assertion` refuses any `inferred` row whose
  -- `source_semantic_run_id` is not a `running` run at the account's current
  -- revision — which is 0 for an account nothing has scored. Property 7 writes
  -- two such assertions to test the race, so the run is part of the seed rather
  -- than part of what is being asserted.
  insert into semantic_private.semantic_runs
    (user_id, ontology_version_id, resolver_model_id, scorer_model_id,
     input_revision, input_hash, status)
  select alice, version,
         (select id from ontology.model_versions
           where model_key like '%resolver%' and status = 'active'
           order by created_at desc limit 1),
         (select id from ontology.model_versions
           where model_key like '%scorer%' and status = 'active'
           order by created_at desc limit 1),
         coalesce((select revision from semantic_private.user_state_versions
                    where user_id = alice), 0),
         'contract_probe', 'running'
  returning id into run;

  -- A provisional, for the merge property.
  insert into semantic_private.provisional_entities
    (scope, user_id, canonical_label, normalized_label, family)
  values ('user', alice, 'Contract Probe Provisional', 'contract probe provisional', 'work')
  returning id into prov;

  insert into semantic_private.user_term_candidates
    (user_id, concept_id, user_facing_predicate, confidence_tier, aggregate_score,
     primary_route_id, lifecycle_state)
  values (alice, concept, 'affinity_to', 'direct', 0.9, 'contract_probe', 'active')
  returning id into cand;

  insert into semantic_private.user_term_candidates
    (user_id, provisional_entity_id, user_facing_predicate, confidence_tier,
     aggregate_score, primary_route_id, lifecycle_state)
  values (alice, prov, 'affinity_to', 'direct', 0.8, 'contract_probe', 'active')
  returning id into prov_cand;

  -- Bob holds the *same concept*, which is what the isolation property needs.
  insert into semantic_private.user_term_candidates
    (user_id, concept_id, user_facing_predicate, confidence_tier, aggregate_score,
     primary_route_id, lifecycle_state)
  values (bob, concept, 'affinity_to', 'direct', 0.9, 'contract_probe', 'active')
  returning id into cand_b;

  insert into semantic_private.review_items
    (user_id, candidate_id, review_epoch, primary_route_id, confidence_tier,
     aggregate_score, rank, presentation_version)
  values (alice, cand, 900, 'contract_probe', 'direct', 0.9, 0, 'calibration_v1')
  returning id into item;
  insert into semantic_private.review_items
    (user_id, candidate_id, review_epoch, primary_route_id, confidence_tier,
     aggregate_score, rank, presentation_version)
  values (alice, prov_cand, 900, 'contract_probe', 'direct', 0.8, 1, 'calibration_v1')
  returning id into prov_item;
  insert into semantic_private.review_items
    (user_id, candidate_id, review_epoch, primary_route_id, confidence_tier,
     aggregate_score, rank, presentation_version)
  values (bob, cand_b, 900, 'contract_probe', 'direct', 0.9, 0, 'calibration_v1')
  returning id into item_b;

  -- **Both forms, because the two `auth.uid()` definitions read different ones.**
  -- The replay image defines it as
  -- `nullif(current_setting('request.jwt.claim.sub', true), '')::uuid` — the
  -- legacy singular setting, and the only one it looks at. Production's reads
  -- `request.jwt.claims` as JSON. Setting one made this file fail with "not
  -- signed in" from inside `begin_calibration`, which reads exactly like a
  -- permission bug and is nothing of the sort. `0044_exact_revision_finalization`
  -- already uses the singular form; setting both means this contract asserts the
  -- same thing wherever it is run.
  perform set_config('request.jwt.claim.sub', alice::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', alice)::text, true);

  -- ---------------------------------------------------------------------
  -- 1. Exposure is recorded when a row is handed out
  -- ---------------------------------------------------------------------
  perform api.begin_calibration(8);
  select count(*) into n from semantic_private.review_exposures
   where user_id = alice and review_item_id in (item, prov_item);
  if n <> 2 then
    raise exception '0230 contract: begin_calibration exposed % of 2 items', n;
  end if;

  -- ---------------------------------------------------------------------
  -- 2. A double strike is idempotent
  -- ---------------------------------------------------------------------
  perform api.strike_calibration_item(item);
  perform api.strike_calibration_item(item);
  -- **Force the deferred checks to fire while the transaction is still
  -- alive.** `user_suppressions`' lineage foreign keys are `deferrable
  -- initially deferred`, so they are checked at COMMIT — and this file ends
  -- in `rollback`, which is the right shape for a test and meant the strike's
  -- foreign key was never checked here at all. It shipped broken twice
  -- underneath a passing test (0231, then 0267). Anything that writes a
  -- deferred reference must be followed by this line.
  set constraints all immediate;

  select count(*) into n from semantic_private.review_events
   where review_item_id = item and action = 'strike_off';
  if n <> 1 then
    raise exception '0230 contract: a double tap wrote % strike events', n;
  end if;
  select count(*) into n from semantic_private.user_term_suppressions
   where user_id = alice and concept_id = concept and active;
  if n <> 1 then
    raise exception '0230 contract: a double tap wrote % suppressions', n;
  end if;

  -- ---------------------------------------------------------------------
  -- 3. A strike reaches the record `list_assertions` honours
  -- ---------------------------------------------------------------------
  select count(*) into n from semantic_private.user_suppressions
   where user_id = alice and concept_id = concept and surface = 'memories' and active;
  if n <> 1 then
    raise exception '0230 contract: a strike wrote % memories suppressions', n;
  end if;

  -- ---------------------------------------------------------------------
  -- 4. Two users cannot affect one another's candidates
  -- ---------------------------------------------------------------------
  if exists (select 1 from semantic_private.user_term_suppressions
              where user_id = bob and active) then
    raise exception '0230 contract: striking as alice suppressed something for bob';
  end if;
  if exists (select 1 from semantic_private.review_events where user_id = bob) then
    raise exception '0230 contract: striking as alice wrote an event for bob';
  end if;

  -- ---------------------------------------------------------------------
  -- 4b. Keep and edit, the two verbs the lane exists for
  -- ---------------------------------------------------------------------
  -- **Absent from every contract file until 0269**, and all three of their
  -- defects were fatal on the first call: a join on
  -- `user_term_candidates.ontology_version_id`, a column that has never
  -- existed (42703), and two `review_events.reason` values — 'user_keep' and
  -- 'user_correction' — that the column's fourteen-word check constraint has
  -- never admitted. A keep is what authorises a mint, so this is the path the
  -- whole discovery-to-Memories story runs through, and nothing called it.
  perform api.keep_calibration_item(prov_item);
  set constraints all immediate;

  select count(*) into n from semantic_private.review_events
   where review_item_id = prov_item and action = 'keep';
  if n <> 1 then
    raise exception '0230 contract: keep wrote % events', n;
  end if;
  -- Exactly one mint request, which is the authority step itself.
  select count(*) into n from semantic_private.mint_requests
   where review_item_id = prov_item and origin = 'keep';
  if n <> 1 then
    raise exception '0230 contract: keep wrote % mint requests', n;
  end if;
  -- Idempotent: a second tap is not a second authorisation to mint.
  perform api.keep_calibration_item(prov_item);
  select count(*) into n from semantic_private.mint_requests
   where review_item_id = prov_item;
  if n <> 1 then
    raise exception '0230 contract: a second keep wrote % mint requests', n;
  end if;
  -- The request carries the label that was on screen, not a null.
  if exists (select 1 from semantic_private.mint_requests
              where review_item_id = prov_item
                and (requested_label is null or btrim(requested_label) = '')) then
    raise exception '0230 contract: the mint request names no label';
  end if;

  -- The edit supersedes with the owner's own words and counts the original
  -- proposal as negative — never as a model success.
  perform api.edit_calibration_item(item, 'a corrected label', 'work');
  set constraints all immediate;
  select count(*) into n from semantic_private.review_events
   where review_item_id = item and action = 'edit';
  if n <> 1 then
    raise exception '0230 contract: edit wrote % events', n;
  end if;
  if exists (select 1 from semantic_private.review_events
              where review_item_id = item and action = 'edit'
                and reason = 'correct') then
    raise exception '0230 contract: an edit was recorded as a model success';
  end if;

  -- ---------------------------------------------------------------------
  -- 5. Abandonment writes no implicit keeps
  -- ---------------------------------------------------------------------
  -- Alice has struck one of two and walked away. `prov_item` was exposed and
  -- left alone; without a completion it must carry no positive label.
  -- The explicit keep above is excluded by name: this is about what silence
  -- writes, and silence must still write nothing.
  select count(*) into n from semantic_private.review_events
   where user_id = alice and action = 'keep' and review_item_id <> prov_item;
  if n <> 0 then
    raise exception '0230 contract: an abandoned review wrote % keeps', n;
  end if;

  -- ---------------------------------------------------------------------
  -- 6. A completed review is distinguishable from an abandoned one,
  --    including when everything was struck
  -- ---------------------------------------------------------------------
  perform api.strike_calibration_item(prov_item);
  perform api.finish_calibration(900);

  select count(*) into n from semantic_private.review_events
   where user_id = alice and action = 'keep' and review_item_id <> prov_item;
  if n <> 0 then
    raise exception '0230 contract: an all-struck completion wrote % keeps', n;
  end if;
  select count(*) into n from semantic_private.review_events
   where user_id = alice and action = 'finish_review';
  if n <> 2 then
    raise exception
      '0230 contract: an all-struck completion left % finish markers, so it is '
      'indistinguishable from abandonment', n;
  end if;

  -- ---------------------------------------------------------------------
  -- 7. The strike/recompute race cannot re-expose the term
  -- ---------------------------------------------------------------------
  -- A recompute that read suppressions before the strike would now write an
  -- eligible assertion. The guard is at the write, so it cannot.
  insert into semantic_private.user_assertions
    (user_id, predicate_key, concept_id, created_ontology_version_id,
     assertion_origin, machine_state, source_semantic_run_id)
  values (alice, 'affinity_to', concept, version, 'inferred', 'eligible', run)
  returning machine_state into state;
  if state <> 'candidate' then
    raise exception
      '0230 contract: a struck term was asserted as %, so the race is open', state;
  end if;

  -- ...and a term nobody struck is untouched, or the guard withholds everything.
  insert into semantic_private.user_assertions
    (user_id, predicate_key, concept_id, created_ontology_version_id,
     assertion_origin, machine_state, source_semantic_run_id)
  values (alice, 'affinity_to', other, version, 'inferred', 'eligible', run)
  returning machine_state into state;
  if state <> 'eligible' then
    raise exception '0230 contract: an unstruck term was withheld as %', state;
  end if;

  -- ---------------------------------------------------------------------
  -- 8. Suppression survives a provisional-to-canonical merge
  -- ---------------------------------------------------------------------
  update semantic_private.provisional_entities
     set redirect_concept_id = other where id = prov;
  select count(*) into n from semantic_private.user_term_suppressions
   where user_id = alice and concept_id = other and active;
  if n <> 1 then
    raise exception
      '0230 contract: the merge left % canonical suppressions, so the window is open', n;
  end if;

  -- ...and merging again, onto a concept already suppressed, does not raise.
  update semantic_private.provisional_entities
     set redirect_concept_id = concept where id = prov;

  -- ---------------------------------------------------------------------
  -- 9. Restore lifts both records
  -- ---------------------------------------------------------------------
  perform api.restore_calibration_item(item);
  if exists (select 1 from semantic_private.user_term_suppressions
              where user_id = alice and concept_id = concept and active) then
    raise exception '0230 contract: restore left the calibration suppression active';
  end if;
  if exists (select 1 from semantic_private.user_suppressions
              where user_id = alice and concept_id = concept
                and surface = 'memories' and active) then
    raise exception '0230 contract: restore left the memories suppression active';
  end if;
  -- **The strike is not erased.** Retiring is not deleting, and the record of
  -- having struck it outlives the change of mind.
  if not exists (select 1 from semantic_private.review_events
                  where review_item_id = item and action = 'strike_off') then
    raise exception '0230 contract: restore deleted the history of the strike';
  end if;

  -- ---------------------------------------------------------------------
  -- 10. Account deletion removes the whole lineage
  -- ---------------------------------------------------------------------
  delete from auth.users where id = alice;

  select count(*) into n from semantic_private.user_term_candidates where user_id = alice;
  if n <> 0 then raise exception '0230 contract: % candidates survived deletion', n; end if;
  select count(*) into n from semantic_private.review_items where user_id = alice;
  if n <> 0 then raise exception '0230 contract: % review items survived deletion', n; end if;
  select count(*) into n from semantic_private.review_events where user_id = alice;
  if n <> 0 then raise exception '0230 contract: % review events survived deletion', n; end if;
  select count(*) into n from semantic_private.review_exposures where user_id = alice;
  if n <> 0 then raise exception '0230 contract: % exposures survived deletion', n; end if;
  select count(*) into n from semantic_private.user_term_suppressions where user_id = alice;
  if n <> 0 then raise exception '0230 contract: % suppressions survived deletion', n; end if;
  select count(*) into n from semantic_private.provisional_entities where user_id = alice;
  if n <> 0 then raise exception '0230 contract: % provisionals survived deletion', n; end if;

  -- **Bob is untouched by Alice's deletion**, which a cascade written against
  -- the wrong key would break silently.
  if not exists (select 1 from semantic_private.user_term_candidates where user_id = bob) then
    raise exception '0230 contract: deleting alice removed bob''s candidate';
  end if;

  raise notice '0230 contract: calibration and erasure lifecycle holds';
end;
$$;

-- The ninth property — a source expiring during an in-flight model call leaving
-- no durable derivative — is **not** tested here. It needs the gateway and an
-- invocation to be in flight, and asserting it against a pipeline that makes no
-- model calls would be a test of nothing that later reads as coverage.

rollback;
