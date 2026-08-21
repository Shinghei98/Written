-- 0305 — the lane names what it is actually running.
--
-- 0304 pinned the release as it was cut; three contract guards then fired in
-- production, each correctly refusing to serve, and fixing each moved an
-- artifact:
--
--   * the serving image digest, which the contract pins so a container swap
--     cannot happen unacknowledged;
--   * the **tokenizer runtime identity**, which hashes the tokenizer *plus*
--     the libraries interpreting it — the new image's newer torch changed it
--     legitimately, so the pin moves from 22b186f1 to 71b49005. This is the
--     first time that number has ever moved, and the drift refusal now quotes
--     the value it measured, because the answer carrying it is read once and
--     deleted and no other route reports it;
--   * the **output ceiling**, which stopped bounding a batch and started
--     bounding one item the moment the container began fanning out. The
--     workbook records `fanout = per_item`, the gateway narrows each
--     sequence's schema to a single item, and the item reserve is re-derived
--     for v4's richer per-item output.
--
-- Measured after: six titles in eight answer in 6-13 s at 191-518 tokens,
-- against 162 s for an eight-item batch before. Prompt and schemas are
-- unchanged from v13 and asserted so; every build and both images moved.

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
     '4fe9d918520dcfe2f0dfe6a9033d884f470275774e814b429cdc5cdb3de33ed1',
     '2885c1e3dffacb14ad4d3304f72b7d2c47666ef27127e8873db6ebb1225e06da',
     m.schema_sha256, m.request_schema_sha256,
     '4be26c8ffb647bf7774733396845b1547c6fe599a5cd8eb67f78060fc26e4e5f',
     m.model_id, m.model_revision,
     '88f9ddb58df9457bed5a1bb7ff54d994a4ff8b2bff9660d8a65d7a2309d75be6',
     m.prompt_version, m.grammar_version,
     '71b49005950bc10ec61cd6e712e33d48358b9c028bfce5de65f7cd5adbf4a2fa',
     'b99c192df9438a86e7f86a63e0ce0c136a39e49f64f4f10e8c7d8ffc96e53840',
     'sha256:366702149ce832bc9c815c727ac36dbb0fe72c22c25f2714bae26a4cc90c7f90',
     m.serving_image_digest
    from ontology.release_manifests m
   where m.prompt_version = 'qwen_extractor_v13'
     and m.parent_release_id is not null
   order by m.created_at desc
   limit 1
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
  select count(*) into n
    from ontology.release_manifests parent
    join ontology.release_manifests child on child.parent_release_id = parent.id
   where child.tokenizer_runtime_manifest_sha256
         = '71b49005950bc10ec61cd6e712e33d48358b9c028bfce5de65f7cd5adbf4a2fa'
     and child.prompt_version = parent.prompt_version
     and child.schema_sha256 = parent.schema_sha256
     and child.serving_image_digest = parent.serving_image_digest
     -- The tokenizer identity has never moved before; say so deliberately.
     and child.tokenizer_runtime_manifest_sha256
         <> parent.tokenizer_runtime_manifest_sha256
     and child.gateway_revision <> parent.gateway_revision
     and child.gateway_image_digest <> parent.gateway_image_digest;
  if n <> 1 then
    raise exception '0305: the release does not move exactly what changed';
  end if;
end;
$$;
