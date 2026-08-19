-- 0251 — the third release: a waking endpoint no longer trips the breaker, and
-- an unsubmitted call no longer spends a key.
--
-- The second release's one armed invocation found the breaker arithmetic:
-- threshold 5, a ~12-minute wake from zero, a ~2-minute retry cadence — every
-- cold start opened it, and the attempt after cool-off recorded `circuit_open`
-- items as a final invocation, consuming the armer idempotency key that work
-- gets once per release. Three fixes (in-flight deferral is not breaker
-- failure; circuit_open with nothing submitted is LaneUnavailable; evaluation
-- defers on unavailability), gateway_revision moved, and an immutable release
-- pays with a new row. 00efa906 stays as history beside its passed gate report
-- and its one wedged invocation.
--
-- As with 0249 and 0250: registered and queued for evaluation here; the slot
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
     'ce14a0c38a5b640a4e9d87dfadef5550c727b659bcc1c757d53fbc8555bec851',
     'b48ad56124e858cce72d2eb9e48f3ba3a33b5c9de6b858bce1ba676280319588',
     '0cdf52b572f7d89d72447c5bc2e5aa67aaec3047cbfbcbf10dcb0df7fdc5de38',
     '74f2b0a46676c2bcc09758854b0604f1f52fefa9d969021604d377ff8fa1e02d',
     '44cd9646179f9407716699e18248e8b67f1385be66393dced0ac9712e5cc025f',
     'Qwen/Qwen3.5-9B',
     'c202236235762e1c871ad0ccb60c8ee5ba337b9a',
     '9860fa403940179e5189eabe7da6c0431cf16cc19d4d020f9527e538bc4ca1f8',
     'qwen_extractor_v5', 'semantic_grammar_v3',
     '22b186f14646edf812947346f505b67e17832ebe2b6b6c454628db66184278a9',
     'de6f5f5fe7eb2f9263d0978a37aa1a14017943b33ab82c2b09734880b7398151',
     'sha256:13bf6d945bbfc0d0121b065c1fcf8437f7c975217e7a291b992a6dced86678fa',
     'sha256:57b87e2ea3434d788517bf674bc6e17787a54dca6631e9c940c9ee3fb3e6575a'
    from ontology.release_manifests m
   where m.model_lane_mode = 'evaluation'
     and m.gateway_revision = 'f1d8725929490b7e4d1720a2bc28047e0351202eb90e548efda12668c678d531'
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
  if n <> 3 then
    raise exception '0251: expected 3 evaluation manifests as history, found %', n;
  end if;
  select count(*) into n from semantic_private.worker_jobs
   where job_type = 'evaluate_release' and status = 'queued';
  if n < 1 then
    raise exception '0251: no queued evaluate_release job for the new manifest';
  end if;
end;
$$;
