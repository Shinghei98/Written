-- 0253 — the fifth release: shadow. A mention may belong to somebody, and
-- still asserts nothing.
--
-- The fourth release proved the whole lane on fixtures: grammar bound,
-- envelope enforced, offsets repaired, one clean receipt. Evaluation grants
-- one turn per (user, release), so that receipt was everything the mode could
-- ever say — waiting longer added nothing. The owner's decision of 2026-08-20
-- moves the mode to `shadow`: mentions, resolutions and candidates may carry
-- a real `user_id`. What does NOT move is the surface: everything shadow
-- writes stays in `semantic_private`, terminates at review, and is invisible
-- to `api.list_assertions` — the two mode-pinning tests that forced this
-- decision now pin the next one.
--
-- Arming scope is every account, current and future (owner instruction,
-- 2026-08-20, superseding the corrective memo's two-account allowlist). The
-- licensing wall is untouched and structural:
-- `semantic_private.model_input_source_codes()` still names only Apple
-- Music, the device library, and Podcasts.
--
-- Only the mode changed, so prompt, grammar, schema, tokenizer and both
-- image digests carry over from dd31c771; the compiled contract and workbook
-- hashes move because the mode is a workbook fact the contract compiles in.
-- gateway_revision is unchanged — no gateway source moved — so this
-- manifest is distinguished from its parent by mode and contract hash.
--
-- As with 0249—0252: registered and queued for evaluation here; the slot
-- repoint happens out of band after the gate report passes, and its inverse
-- (back to dd31c771) is prepared alongside it.

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
  select m.id, published_version, 'production', 'shadow',
     '4a6f0b9f2a0a5306e42b819e57d242a856b9721cc9486dc5444d312dba12bf30',
     '17f7f2d733417eb2a164a5724096cf9984f5054185e3cab520e84e1d92c12f55',
     'aa30477736d23018421e29b07864710ef00b9d64e2fb07c5b9b0fe1af5f346f4',
     '74f2b0a46676c2bcc09758854b0604f1f52fefa9d969021604d377ff8fa1e02d',
     '1123dd4ca3bef8eab9bdfaa3641b28b0631d7c057ca320a4a64fe51b8d5d3c9e',
     'Qwen/Qwen3.5-9B',
     'c202236235762e1c871ad0ccb60c8ee5ba337b9a',
     '5a2fbc2f11bd89eea11f135df3a5d3b71bef74f52c9cb4e4caff11f91c85e0b3',
     'qwen_extractor_v6', 'semantic_grammar_v4',
     '22b186f14646edf812947346f505b67e17832ebe2b6b6c454628db66184278a9',
     '76675b83fe520a7bcf5a85354836129af8ae81f2e894eea67225569e78ee3338',
     'sha256:4c28ec9cc6b27e145148b6ad8d6b49f336dd6354120a75d455024174af32ba7d',
     'sha256:57b87e2ea3434d788517bf674bc6e17787a54dca6631e9c940c9ee3fb3e6575a'
    from ontology.release_manifests m
   where m.model_lane_mode = 'evaluation'
     and m.gateway_revision = '5a2fbc2f11bd89eea11f135df3a5d3b71bef74f52c9cb4e4caff11f91c85e0b3'
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
   where model_lane_mode = 'shadow';
  if n <> 1 then
    raise exception '0253: expected exactly 1 shadow manifest, found %', n;
  end if;
  select count(*) into n from ontology.release_manifests
   where model_lane_mode = 'evaluation';
  if n <> 4 then
    raise exception '0253: expected 4 evaluation manifests as history, found %', n;
  end if;
  select count(*) into n from semantic_private.worker_jobs
   where job_type = 'evaluate_release' and status = 'queued';
  if n < 1 then
    raise exception '0253: no queued evaluate_release job for the shadow manifest';
  end if;
end;
$$;
