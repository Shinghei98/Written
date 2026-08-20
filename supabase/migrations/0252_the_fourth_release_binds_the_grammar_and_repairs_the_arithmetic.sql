-- 0252 — the fourth release: the grammar finally binds, and offsets the model
-- miscounted are repaired rather than refused.
--
-- The third release's endpoint answered, and measuring it found the grammar
-- had never bound: xgrammar 0.2.3's token matcher leaks on
-- `pattern`-constrained strings — correct at the string level, permissive at
-- the mask — so extractions emitted enum-illegal families and ran to the
-- token cap while abstentions looked bound (they never exercise the mention
-- definitions). Three artifact changes, one behavior change:
--
--   * the schema drops its two string patterns (their guards moved to
--     `mention_extract_v2.py`, the layer for what the schema cannot safely
--     express) and re-expresses its if/then conditionals as anyOf variants
--     xgrammar can compile — language-identical over 530 adversarial
--     documents, zero loosenings uncovered by the second layer;
--   * the prompt's aboutness_example stops teaching the v1 mention shape it
--     had shown since the schema went v2 (prompt qwen_extractor_v6, grammar
--     semantic_grammar_v4);
--   * `repair_offsets` recomputes a span only where the emitted surface
--     occurs exactly once in the cited field — the entity was correctly
--     identified and only the arithmetic was off; absent or ambiguous stays a
--     refusal, so the repair can never invent a span, and every repair is
--     counted in the gateway's answer (owner decision, 2026-08-19).
--
-- `mention_extract_v2.py` joined GATEWAY_SOURCES — the repair changed which
-- answers survive without touching gateway.py — so gateway_revision moves for
-- the validator as well as the gateway from here on.
--
-- Acceptance before this row existed: 21/21 direct invocations of the live
-- endpoint green (schema pass, validator pass, finish stop), including a
-- deliberately repetitive title whose correct outcome is abstention.
-- 0e0bf8fc stays as history beside its passed gate report and its one
-- provider_error invocation from the capacity drought.
--
-- As with 0249—0251: registered and queued for evaluation here; the slot
-- repoint happens out of band after the gate report passes.

do $$
declare
  published_version uuid;
  manifest uuid;
begin
  select id into strict published_version
    from ontology.versions where status = 'published';

  insert into ontology.release_manifests
    (parent_release_id, base_ontology_version_id, environment, model_lane_mode,
     compiled_contract_sha256, workbook_sha256, schema_sha256,
     request_schema_sha256, release_build_sha256,
     model_id, model_revision, gateway_revision,
     prompt_version, grammar_version,
     tokenizer_runtime_manifest_sha256, extraction_contract_manifest_sha256,
     gateway_image_digest, serving_image_digest)
  select m.id, published_version, 'production', 'evaluation',
     'eb26d9744ed54165a88db4ae4b3b54829d5803365f2e6f7978ac26a1f1b0c9bc',
     '09924b8bbdc7f42cc2db66c37bb40567bed21e6bb16a430de62e9b1abb1c44d4',
     'aa30477736d23018421e29b07864710ef00b9d64e2fb07c5b9b0fe1af5f346f4',
     '74f2b0a46676c2bcc09758854b0604f1f52fefa9d969021604d377ff8fa1e02d',
     'b73026f244646a447a383f6cca6b4010e0305f593feaddb91daec9cc2e468cf0',
     'Qwen/Qwen3.5-9B',
     'c202236235762e1c871ad0ccb60c8ee5ba337b9a',
     '5a2fbc2f11bd89eea11f135df3a5d3b71bef74f52c9cb4e4caff11f91c85e0b3',
     'qwen_extractor_v6', 'semantic_grammar_v4',
     '22b186f14646edf812947346f505b67e17832ebe2b6b6c454628db66184278a9',
     '7c44ba5905f4ae29728144b391f4eb9800c3cb837633676a57503f687f30b7a0',
     'sha256:e5859f420826f7bd3bbd28b9a6625efe2cd8c3b18ef46d7ddd312c37a365e9e1',
     'sha256:57b87e2ea3434d788517bf674bc6e17787a54dca6631e9c940c9ee3fb3e6575a'
    from ontology.release_manifests m
   where m.model_lane_mode = 'evaluation'
     and m.gateway_revision = '9860fa403940179e5189eabe7da6c0431cf16cc19d4d020f9527e538bc4ca1f8'
  returning id into manifest;

  insert into semantic_private.worker_jobs
    (job_type, user_id, payload, idempotency_key, available_at)
  values
    ('evaluate_release', null,
     jsonb_build_object('release_manifest_id', manifest),
     'evaluate_release:' || manifest::text, now())
  on conflict (idempotency_key) do nothing;
end;
$$;

do $$
declare
  n integer;
begin
  select count(*) into n from ontology.release_manifests
   where model_lane_mode = 'evaluation';
  if n <> 4 then
    raise exception '0252: expected 4 evaluation manifests as history, found %', n;
  end if;
  select count(*) into n from semantic_private.worker_jobs
   where job_type = 'evaluate_release' and status = 'queued';
  if n < 1 then
    raise exception '0252: no queued evaluate_release job for the new manifest';
  end if;
end;
$$;
