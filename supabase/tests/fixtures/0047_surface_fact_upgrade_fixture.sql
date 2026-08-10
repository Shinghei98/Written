-- Adapted from the v0.3.1 reference `sql/tests/fixtures/005_surface_fact_upgrade_fixture.sql`.
-- Gates application migration 0047.
--
-- The reference chain numbers its files 001-006 while this repository's
-- are 0042-0047, so contract numbering is off by two and the two
-- fixture lanes are off by one -- reference fixture `004` gates the
-- app's 0046, and reference fixture `005` gates 0047. The file name
-- states which migration it gates so nobody re-derives that each time.
--
-- Substituted from the reference: 22 `private.` -> `semantic_private.`
-- and 0 bare `'private'` schema arguments. Privacy-class VALUES
-- such as `'private_text'` are deliberately untouched: they are
-- check-constraint values, not schema names, and rewriting them is how
-- a mechanical rename corrupts a contract while still passing.

-- Run after 005_private_ingestion_and_fitness.sql and before 006. This fixture
-- persists a valid pre-006 inferred fact, a ready bio, and an unexposed ready
-- icebreaker. None of these legacy facts records the exact score/revision that
-- was attested because those columns do not exist until 006.

do $surface_fact_upgrade_fixture$
declare
  viewer_user_id uuid := ontology.stable_uuid(
    'written:test:v0.3.1-surface-upgrade-viewer'
  );
  subject_user_id uuid := ontology.stable_uuid(
    'written:test:v0.3.1-surface-upgrade-subject'
  );
  fixture_run_id uuid := ontology.stable_uuid(
    'written:test:v0.3.1-surface-upgrade-run'
  );
  subject_assertion_id uuid := ontology.stable_uuid(
    'written:test:v0.3.1-surface-upgrade-subject-assertion'
  );
  viewer_assertion_id uuid := ontology.stable_uuid(
    'written:test:v0.3.1-surface-upgrade-viewer-assertion'
  );
  score_id uuid := ontology.stable_uuid(
    'written:test:v0.3.1-surface-upgrade-score'
  );
  bio_fact_id uuid := ontology.stable_uuid(
    'written:test:v0.3.1-surface-upgrade-bio-fact'
  );
  subject_icebreaker_fact_id uuid := ontology.stable_uuid(
    'written:test:v0.3.1-surface-upgrade-subject-icebreaker-fact'
  );
  viewer_icebreaker_fact_id uuid := ontology.stable_uuid(
    'written:test:v0.3.1-surface-upgrade-viewer-icebreaker-fact'
  );
  dyad_id uuid := ontology.stable_uuid(
    'written:test:v0.3.1-surface-upgrade-dyad'
  );
  bio_id uuid := ontology.stable_uuid(
    'written:test:v0.3.1-surface-upgrade-bio'
  );
  authorization_id uuid := ontology.stable_uuid(
    'written:test:v0.3.1-surface-upgrade-authorization'
  );
  match_id uuid := ontology.stable_uuid(
    'written:test:v0.3.1-surface-upgrade-match'
  );
  frame_id uuid := ontology.stable_uuid(
    'written:test:v0.3.1-surface-upgrade-frame'
  );
  version_id uuid;
  resolver_id uuid;
  scorer_id uuid;
  ranker_id uuid;
  bio_renderer_id uuid;
  icebreaker_renderer_id uuid;
  subject_concept_id uuid;
  viewer_concept_id uuid;
  bridge_concept_id uuid;
  finalized boolean;
begin
  select id into version_id
  from ontology.versions where status = 'published';
  select id into resolver_id
  from ontology.model_versions
  where model_key = 'ontology_first_resolver' and version = '0.1.0';
  select id into scorer_id
  from ontology.model_versions
  where model_key = 'missing_aware_late_fusion' and version = '0.1.0';
  select id into ranker_id
  from ontology.model_versions
  where model_key = 'typed_graph_dyad_ranker' and version = '0.2.0';
  select id into bio_renderer_id
  from ontology.model_versions
  where model_key = 'validated_fact_bio_renderer' and version = '0.2.0';
  select id into icebreaker_renderer_id
  from ontology.model_versions
  where model_key = 'deterministic_icebreaker_renderer' and version = '0.2.0';
  select id into subject_concept_id
  from ontology.concepts where concept_key = 'affinity:culture:italy';
  select id into viewer_concept_id
  from ontology.concepts where concept_key = 'activity:running';
  select id into bridge_concept_id
  from ontology.concepts where concept_key = 'hub:sports_movement';
  if version_id is null or resolver_id is null or scorer_id is null
     or ranker_id is null or bio_renderer_id is null
     or icebreaker_renderer_id is null or subject_concept_id is null
     or viewer_concept_id is null or bridge_concept_id is null then
    raise exception 'surface-fact upgrade fixture seed catalog is incomplete';
  end if;

  insert into auth.users (id, aud, role, created_at, updated_at) values
    (viewer_user_id, 'authenticated', 'authenticated', now(), now()),
    (subject_user_id, 'authenticated', 'authenticated', now(), now());
  insert into semantic_private.user_state_versions (user_id, revision) values
    (viewer_user_id, 0), (subject_user_id, 0);

  insert into semantic_private.semantic_runs (
    id, user_id, ontology_version_id, resolver_model_id, scorer_model_id,
    input_revision, input_hash, status
  ) values (
    fixture_run_id, subject_user_id, version_id, resolver_id, scorer_id,
    0, 'synthetic-v0.3.1-surface-upgrade', 'running'
  );
  insert into semantic_private.user_assertions (
    id, user_id, predicate_key, concept_id, created_ontology_version_id,
    source_semantic_run_id, assertion_origin, machine_state
  ) values
    (subject_assertion_id, subject_user_id, 'affinity_to', subject_concept_id,
     version_id, fixture_run_id, 'inferred', 'eligible'),
    (viewer_assertion_id, viewer_user_id, 'affinity_to', viewer_concept_id,
     version_id, null, 'explicit_self_report', 'eligible');
  insert into semantic_private.assertion_score_versions (
    id, assertion_id, user_id, semantic_run_id, ontology_version_id,
    strength, confidence, breadth, stability, surfacing_score, display_payload
  ) values (
    score_id, subject_assertion_id, subject_user_id, fixture_run_id, version_id,
    0.83, 0.86, 2, 0.79, 0.82,
    '{"template_key":"synthetic_surface_upgrade"}'::jsonb
  );
  finalized := semantic_private.finalize_semantic_run(fixture_run_id);
  if finalized is distinct from true or not exists (
    select 1 from semantic_private.assertion_current_scores as current_score
    where current_score.assertion_id = subject_assertion_id
      and current_score.user_id = subject_user_id
      and current_score.assertion_score_version_id = score_id
      and current_score.semantic_run_id = fixture_run_id
  ) then
    raise exception 'surface-fact upgrade fixture score did not become current';
  end if;

  update semantic_private.assertion_surface_permissions
  set can_select = true, can_name = true, can_explain = true,
      permission_source = 'user_choice'
  where assertion_id = subject_assertion_id
    and user_id = subject_user_id and surface = 'bio';
  update semantic_private.assertion_surface_permissions
  set can_select = true, can_name = true, can_explain = false,
      permission_source = 'user_choice'
  where assertion_id = subject_assertion_id
    and user_id = subject_user_id and surface = 'icebreaker';
  update semantic_private.assertion_surface_permissions
  set can_select = true, can_name = true, can_explain = false,
      permission_source = 'user_choice'
  where assertion_id = viewer_assertion_id
    and user_id = viewer_user_id and surface = 'icebreaker';

  insert into semantic_private.validated_surface_facts (
    id, user_id, assertion_id, ontology_version_id, surface, predicate_key,
    display_label, evidence_class, confirmation_state, may_name, may_explain,
    validator_model_id, fact_version, fact_payload, state, data_use_purpose
  ) values
    (bio_fact_id, subject_user_id, subject_assertion_id, version_id, 'bio',
     'affinity_to', 'Italian cultural affinity', 'ontology_inferred', 'inferred',
     true, true, ranker_id, 'synthetic-upgrade-bio-v005', '{}'::jsonb,
     'validated', 'general_social'),
    (subject_icebreaker_fact_id, subject_user_id, subject_assertion_id,
     version_id, 'icebreaker', 'affinity_to', 'Enjoys Italian culture',
     'ontology_inferred', 'inferred', true, false, ranker_id,
     'synthetic-upgrade-subject-icebreaker-v005', '{}'::jsonb,
     'validated', 'general_social'),
    (viewer_icebreaker_fact_id, viewer_user_id, viewer_assertion_id,
     version_id, 'icebreaker', 'affinity_to', 'Enjoys running', 'explicit',
     'explicit_self_report', true, false, ranker_id,
     'synthetic-upgrade-viewer-icebreaker-v005', '{}'::jsonb,
     'validated', 'general_social');

  insert into semantic_private.match_authorizations (
    id, match_id, participant_a_user_id, participant_b_user_id, source_version
  ) values (
    authorization_id, match_id, viewer_user_id, subject_user_id,
    'synthetic-pre-006'
  );
  insert into semantic_private.dyad_runs (
    id, viewer_user_id, subject_user_id, viewer_revision, subject_revision,
    ontology_version_id, ranker_model_id, run_purpose, data_use_purpose,
    input_hash
  ) values (
    dyad_id, viewer_user_id, subject_user_id, 0, 0, version_id, ranker_id,
    'both', 'general_social', 'synthetic-v0.3.1-surface-upgrade-dyad'
  );
  update semantic_private.dyad_runs
  set status = 'succeeded', finished_at = now(),
      semantic_proximity = 0.74, comparability = 0.78
  where id = dyad_id;

  insert into semantic_private.bio_variants (
    id, dyad_run_id, viewer_user_id, subject_user_id,
    renderer_model_id, variant_version, stable_text, state
  ) values (
    bio_id, dyad_id, viewer_user_id, subject_user_id, bio_renderer_id,
    'synthetic-upgrade-v005', 'Likes Italian culture.', 'draft'
  );
  insert into semantic_private.bio_variant_facts (
    bio_variant_id, surface_fact_id, subject_user_id, clause_role, rank
  ) values (bio_id, bio_fact_id, subject_user_id, 'stable', 0);
  update semantic_private.bio_variants
  set state = 'ready', finalized_at = now() where id = bio_id;

  insert into semantic_private.icebreaker_frames (
    id, match_authorization_id, dyad_run_id, viewer_user_id,
    subject_user_id, bridge_concept_id, ontology_version_id,
    renderer_model_id, bridge_mode, template_version, frame_payload
  ) values (
    frame_id, authorization_id, dyad_id, viewer_user_id, subject_user_id,
    bridge_concept_id, version_id, icebreaker_renderer_id, 'shared_thread',
    'synthetic-upgrade-v005',
    '{"template_key":"shared_movement","wording_version":"v1","bridge_label":"movement"}'::jsonb
  );
  insert into semantic_private.icebreaker_frame_facts (
    icebreaker_frame_id, surface_fact_id, fact_user_id, fact_side
  ) values
    (frame_id, viewer_icebreaker_fact_id, viewer_user_id, 'viewer'),
    (frame_id, subject_icebreaker_fact_id, subject_user_id, 'subject');
  update semantic_private.icebreaker_frames
  set state = 'ready', finalized_at = now(),
      rendered_text = 'You both follow interesting threads. What comes to mind?'
  where id = frame_id;

  if not semantic_private.dyad_run_is_current(dyad_id)
     or not exists (
       select 1 from semantic_private.bio_variants where id = bio_id and state = 'ready'
     ) or not exists (
       select 1 from semantic_private.icebreaker_frames
       where id = frame_id and state = 'ready' and exposed_at is null
     ) then
    raise exception 'surface-fact upgrade fixture did not persist ready products';
  end if;
end
$surface_fact_upgrade_fixture$;
