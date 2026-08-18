-- 0235 — a gate report is an event, and events are not overwritten.
--
-- `evaluate_release` used a blind `update ... set gate_report`, so every re-run
-- destroyed the previous verdict and *"did this release ever pass, and when did
-- it stop"* had no answer. The migration asserts the column privilege is gone
-- and that a calling lane must name what it calls; this asserts the behaviour
-- that replaces it.
--
-- Everything runs against seeded rows and rolls back.

begin;

do $$
declare
  release_id uuid;
  first_id   uuid;
  raised     boolean;
  n          integer;
begin
  insert into ontology.release_manifests
    (base_ontology_version_id, compiled_contract_sha256, workbook_sha256,
     schema_sha256, release_build_sha256, database_fingerprint_sha256,
     environment, promotion_decision, model_lane_mode)
  select v.id, repeat('a', 64), repeat('b', 64), repeat('c', 64),
         repeat('d', 64), repeat('e', 64), 'contract_probe', 'pending', 'off'
    from ontology.versions v where v.status = 'published' limit 1
  returning id into release_id;

  -- ---------------------------------------------------------------------
  -- 1. Two verdicts on one manifest coexist
  -- ---------------------------------------------------------------------
  insert into ontology.release_gate_reports
    (release_manifest_id, evaluation_revision, environment, report)
  values (release_id, 'release-eval-0.2.0', 'contract_probe',
          '{"all_required_tests_passed": false}'::jsonb)
  returning id into first_id;

  insert into ontology.release_gate_reports
    (release_manifest_id, evaluation_revision, environment, report)
  values (release_id, 'release-eval-0.2.0', 'contract_probe',
          '{"all_required_tests_passed": true}'::jsonb);

  select count(*) into n from ontology.release_gate_reports
   where release_manifest_id = release_id;
  if n <> 2 then
    raise exception '0235 contract: a second verdict left % reports, expected 2', n;
  end if;

  -- ---------------------------------------------------------------------
  -- 2. A verdict cannot be rewritten after the fact
  -- ---------------------------------------------------------------------
  raised := false;
  begin
    update ontology.release_gate_reports
       set report = '{"all_required_tests_passed": true}'::jsonb
     where id = first_id;
  exception when others then raised := true;
  end;
  if not raised then
    raise exception '0235 contract: a gate report was rewritten';
  end if;

  raised := false;
  begin
    delete from ontology.release_gate_reports where id = first_id;
  exception when others then raised := true;
  end;
  if not raised then
    raise exception '0235 contract: a gate report was deleted';
  end if;

  -- ---------------------------------------------------------------------
  -- 3. A calling lane must name what it calls
  -- ---------------------------------------------------------------------
  -- The `off` manifest above is legitimate with no gateway: there is nothing
  -- deployed to name. One that claims a model ran must say which one.
  raised := false;
  begin
    update ontology.release_manifests
       set model_lane_mode = 'evaluation' where id = release_id;
  exception when check_violation then raised := true;
  end;
  if not raised then
    raise exception
      '0235 contract: a manifest became evaluation while naming no gateway';
  end if;

  -- ...and naming them all is accepted, so the refusal is about the identities
  -- rather than about the mode.
  update ontology.release_manifests
     set model_lane_mode = 'evaluation',
         tokenizer_runtime_manifest_sha256 = repeat('1', 64),
         extraction_contract_manifest_sha256 = repeat('2', 64),
         gateway_image_digest = 'sha256:' || repeat('3', 64),
         serving_image_digest = 'sha256:' || repeat('4', 64),
         prompt_version = 'qwen_extractor_v5',
         grammar_version = 'semantic_grammar_v3'
   where id = release_id;

  -- ---------------------------------------------------------------------
  -- 4. A release carrying verdicts cannot be deleted
  -- ---------------------------------------------------------------------
  -- Erasing the judged thing must not erase the judgement. Nothing here is user
  -- data, so no account deletion is owed and `restrict` costs nothing.
  raised := false;
  begin
    delete from ontology.release_manifests where id = release_id;
  exception when foreign_key_violation then raised := true;
  end;
  if not raised then
    raise exception '0235 contract: a release with verdicts was deleted';
  end if;

  raise notice '0235 contract: gate reports append and manifests name their lane';
end;
$$;

rollback;
