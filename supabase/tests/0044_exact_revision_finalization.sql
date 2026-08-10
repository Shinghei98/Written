-- Adapted from the v0.3.1 reference `sql/tests/003_exact_revision_finalization.sql`.
-- Gates application migration 0044.
--
-- The reference chain numbers its files 001-006 while this repository's
-- are 0042-0047, so contract numbering is off by two and the two
-- fixture lanes are off by one -- reference fixture `004` gates the
-- app's 0046, and reference fixture `005` gates 0047. The file name
-- states which migration it gates so nobody re-derives that each time.
--
-- Substituted from the reference: 20 `private.` -> `semantic_private.`
-- and 0 bare `'private'` schema arguments. Privacy-class VALUES
-- such as `'private_text'` are deliberately untouched: they are
-- check-constraint values, not schema names, and rewriting them is how
-- a mechanical rename corrupts a contract while still passing.

-- Run after 001_schema.sql, 002_rls_and_rpc.sql, and 003_seed.sql.
-- This uses a synthetic auth user and rolls every row back.
begin;

do $$
declare
  test_user_id uuid := ontology.stable_uuid('written:test:exact-revision-user');
  version_id uuid;
  resolver_id uuid;
  scorer_id uuid;
  concept_id uuid;
  motif_rule_id uuid;
  motif_evidence_target_id uuid;
  motif_instance_id uuid := ontology.stable_uuid('written:test:motif-instance');
  test_assertion_id uuid := ontology.stable_uuid('written:test:exact-revision-assertion');
  first_run_id uuid := ontology.stable_uuid('written:test:exact-revision-run-0');
  stale_run_id uuid := ontology.stable_uuid('written:test:exact-revision-run-stale');
  score_id uuid := ontology.stable_uuid('written:test:exact-revision-score');
  test_exposure_id uuid;
  suppress_event_id uuid;
  restore_event_id uuid;
  suppress_client_event_id uuid := ontology.stable_uuid('written:test:suppress-event');
  restore_client_event_id uuid := ontology.stable_uuid('written:test:restore-event');
  finalized boolean;
  listed_count integer;
  current_revision bigint;
begin
  insert into auth.users (id, aud, role, created_at, updated_at)
  values (test_user_id, 'authenticated', 'authenticated', now(), now());

  insert into semantic_private.user_state_versions (user_id, revision)
  values (test_user_id, 0);

  select id into version_id from ontology.versions where status = 'published';
  select id into resolver_id
  from ontology.model_versions
  where model_key = 'ontology_first_resolver' and version = '0.1.0';
  select id into scorer_id
  from ontology.model_versions
  where model_key = 'missing_aware_late_fusion' and version = '0.1.0';
  select id into concept_id
  from ontology.concepts where concept_key = 'affinity:culture:italy';
  select id, evidence_target_concept_id
  into motif_rule_id, motif_evidence_target_id
  from ontology.motif_rules
  where rule_key = 'cultural_affinity_convergence:italy'
    and ontology_version_id = version_id;

  insert into semantic_private.semantic_runs (
    id, user_id, ontology_version_id, resolver_model_id, scorer_model_id,
    input_revision, input_hash, status
  ) values (
    first_run_id, test_user_id, version_id, resolver_id, scorer_id,
    0, 'test-input-at-revision-0', 'running'
  );

  insert into semantic_private.user_assertions (
    id, user_id, predicate_key, concept_id, created_ontology_version_id,
    source_semantic_run_id, assertion_origin, machine_state
  ) values (
    test_assertion_id, test_user_id, 'affinity_to', concept_id, version_id,
    first_run_id, 'inferred', 'eligible'
  );

  insert into semantic_private.motif_instances (
    id, semantic_run_id, user_id, ontology_version_id, motif_rule_id,
    evidence_target_concept_id, output_concept_id, strength, confidence,
    breadth, stability, explanation
  ) values (
    motif_instance_id, first_run_id, test_user_id, version_id,
    motif_rule_id, motif_evidence_target_id, concept_id,
    0.75, 0.80, 2, 0.70, '{"test":true}'::jsonb
  );

  insert into semantic_private.assertion_score_versions (
    id, assertion_id, user_id, semantic_run_id, ontology_version_id,
    motif_instance_id,
    strength, confidence, breadth, stability, surfacing_score,
    display_payload
  ) values (
    score_id, test_assertion_id, test_user_id, first_run_id, version_id,
    motif_instance_id,
    0.75, 0.80, 2, 0.70, 0.72, '{"test":true}'::jsonb
  );

  finalized := semantic_private.finalize_semantic_run(first_run_id);
  if finalized is distinct from true then
    raise exception 'exact-revision run did not finalize';
  end if;
  if not exists (
    select 1 from semantic_private.assertion_current_scores as current_score
    where current_score.assertion_id = test_assertion_id
      and current_score.assertion_score_version_id = score_id
      and current_score.semantic_run_id = first_run_id
  ) then
    raise exception 'finalized run did not advance the current-score pointer';
  end if;

  perform set_config('request.jwt.claim.sub', test_user_id::text, true);
  test_exposure_id := api.record_assertion_exposure(
    test_assertion_id, score_id, 'memories-card-v1',
    'Italian cultural affinity', 0, 'memories'
  );
  if not exists (
    select 1 from semantic_private.assertion_exposures as exposure
    where exposure.id = test_exposure_id
      and exposure.assertion_id = test_assertion_id
      and exposure.assertion_score_version_id = score_id
      and exposure.ontology_version_id = version_id
      and exposure.presentation_version = 'memories-card-v1'
      and exposure.displayed_label = 'Italian cultural affinity'
  ) then
    raise exception 'exposure did not preserve the displayed score and presentation';
  end if;

  suppress_event_id := api.suppress_assertion(
    test_assertion_id, suppress_client_event_id, test_exposure_id, 'memories'
  );
  if api.suppress_assertion(
       test_assertion_id, suppress_client_event_id, test_exposure_id, 'memories'
     ) is distinct from suppress_event_id then
    raise exception 'suppression retry was not idempotent';
  end if;
  select revision into current_revision
  from semantic_private.user_state_versions where user_id = test_user_id;
  if current_revision <> 1 or not exists (
    select 1
    from semantic_private.feedback_events as feedback
    join semantic_private.user_suppressions as suppression
      on suppression.source_feedback_event_id = feedback.id
     and suppression.user_id = feedback.user_id
    where feedback.id = suppress_event_id
      and feedback.exposure_id = test_exposure_id
      and feedback.assertion_score_version_id = score_id
      and feedback.presentation_version = 'memories-card-v1'
      and feedback.action = 'suppress'
      and feedback.label_semantics = 'ambiguous_rejection'
      and not (feedback.context ? 'reason')
      and suppression.active
  ) then
    raise exception 'one-tap suppression did not preserve ambiguous exposure fidelity';
  end if;

  select count(*) into listed_count
  from api.list_assertions() as listed
  where listed.assertion_id = test_assertion_id;
  if listed_count <> 0 then
    raise exception 'score from an older input revision remained surfaceable';
  end if;

  restore_event_id := api.restore_assertion(
    test_assertion_id, restore_client_event_id, 'memories'
  );
  if api.restore_assertion(
       test_assertion_id, restore_client_event_id, 'memories'
     ) is distinct from restore_event_id then
    raise exception 'restore retry was not idempotent';
  end if;
  select revision into current_revision
  from semantic_private.user_state_versions where user_id = test_user_id;
  if current_revision <> 2 or not exists (
    select 1 from semantic_private.user_suppressions
    where user_id = test_user_id
      and source_feedback_event_id = suppress_event_id
      and lifted_by_feedback_event_id = restore_event_id
      and not active
  ) then
    raise exception 'restore did not durably lift the suppression';
  end if;

  insert into semantic_private.semantic_runs (
    id, user_id, ontology_version_id, resolver_model_id, scorer_model_id,
    input_revision, input_hash, status
  ) values (
    stale_run_id, test_user_id, version_id, resolver_id, scorer_id,
    0, 'stale-test-input-at-revision-0', 'running'
  );
  finalized := semantic_private.finalize_semantic_run(stale_run_id);
  if finalized is distinct from false or not exists (
    select 1 from semantic_private.semantic_runs
    where id = stale_run_id
      and status = 'stale'
      and error_code = 'input_revision_changed'
      and finished_at is not null
  ) then
    raise exception 'revision-mismatched run was not finalized as stale';
  end if;

  delete from auth.users where id = test_user_id;
  set constraints all immediate;
  if exists (
    select 1 from semantic_private.user_assertions where user_id = test_user_id
  ) or exists (
    select 1 from semantic_private.feedback_events where user_id = test_user_id
  ) or exists (
    select 1 from semantic_private.user_suppressions where user_id = test_user_id
  ) or exists (
    select 1 from semantic_private.semantic_runs where user_id = test_user_id
  ) then
    raise exception 'deferred audit FKs prevented ordered auth-user cascade cleanup';
  end if;
end;
$$;

rollback;
