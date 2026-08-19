-- 0250 — the second release manifest: the first invocation found a real bug,
-- and an immutable release pays for its fix with a new row.
--
-- The first armed invocation under ea3c6b7f failed both fixture items with
-- `provider_error` in 855 ms. Root cause, proven by interrogating the deployed
-- image: the gateway relied on the Lambda base image's boto3, whose botocore
-- (1.42.97) predates the inline `Body` parameter on `InvokeEndpointAsync` — so
-- the one call the transport makes failed client-side validation before any
-- network was touched. The gateway now pins boto3==1.43.74, the version proven
-- to carry the parameter, and its retry loop stops collapsing a classified
-- error name into the string "RuntimeError".
--
-- requirements.txt is part of the gateway's hashed identity, so this is a new
-- gateway_revision, a new contract, and therefore a new release manifest —
-- the same lane, the same mode, the same measured serving identities, four
-- gateway-side values moved. ea3c6b7f stays as history beside its gate report
-- and its one all-failed invocation, which is exactly what append-only is for.
--
-- As with 0249: registered and queued for evaluation here; deployed (the slot
-- repoint) out of band after its gate report passes.

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
     '5905775601faca4ed790e11ac9f61ea15929a05b9344416a96b585188976554b',
     '21a0f8e25db697e6d0c8ff5abb5b03d2582303b938b71a58a8b23051a8aa34fc',
     '0cdf52b572f7d89d72447c5bc2e5aa67aaec3047cbfbcbf10dcb0df7fdc5de38',
     '74f2b0a46676c2bcc09758854b0604f1f52fefa9d969021604d377ff8fa1e02d',
     '4ab17208dfb0ca92d0d16a2d0fe6613c96f0a355e381de29520cd0903a9d724b',
     'Qwen/Qwen3.5-9B',
     'c202236235762e1c871ad0ccb60c8ee5ba337b9a',
     'f1d8725929490b7e4d1720a2bc28047e0351202eb90e548efda12668c678d531',
     'qwen_extractor_v5', 'semantic_grammar_v3',
     '22b186f14646edf812947346f505b67e17832ebe2b6b6c454628db66184278a9',
     'bbd64c4e16e14a125c656259fb94d399051fc50538c5c85d077e38195e294a20',
     'sha256:f1fbb64cd0b3e5706f37ed926150653750756f76735382c39e953de46e1559f0',
     'sha256:57b87e2ea3434d788517bf674bc6e17787a54dca6631e9c940c9ee3fb3e6575a'
    from ontology.release_manifests m
   where m.model_lane_mode = 'evaluation'
     and m.gateway_revision = 'a8d422ceb020993c2ebe001e0ff64c694884993fb3859600b8b0c95a53ca0edc'
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
  -- Two evaluation manifests now exist as history; the lane in force is
  -- whatever the slot names, which this migration deliberately does not touch.
  select count(*) into n from ontology.release_manifests
   where model_lane_mode = 'evaluation';
  if n <> 2 then
    raise exception '0250: expected 2 evaluation manifests as history, found %', n;
  end if;
  select count(*) into n from semantic_private.worker_jobs
   where job_type = 'evaluate_release' and status = 'queued';
  if n < 1 then
    raise exception '0250: no queued evaluate_release job for the new manifest';
  end if;
end;
$$;
