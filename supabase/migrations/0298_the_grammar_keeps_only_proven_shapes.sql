-- 0298 — the cardinal wire again, in the grammar shapes generation is proven on.
--
-- The v10 release passed its gate and then could not speak: the first real
-- calls generated at 0.5–10 tokens/sec — 10 to 50 minutes per prompt —
-- because two constructs in mention_extract_v4 were outside the shapes this
-- stack has ever measured xgrammar 0.2.3 on. `cardinal_scores` was an object
-- of eight OPTIONAL number properties, and `selected_cardinal` /
-- `missing_parent` were nullable through enum-with-null and anyOf. The same
-- class of defect as the pattern leak of 2026-08-19, reintroduced from the
-- other side.
--
-- The reshape keeps every §5.2 answer and changes only the encoding:
-- `selected_cardinal` and `candidate_user_predicate` are pure string enums
-- with an explicit 'none' member (the validator maps it to absence);
-- `cardinal_confidence` replaces the distribution (the runner-up readings
-- live in `alternatives`); the §5.3 proposal travels in a maxItems-1 array
-- (`missing_parent_proposals`) instead of a nullable object. Prompt v11 says
-- the same. The gate cannot catch this class — it attests identity, not
-- speed — so the schema's own description now states the shape rule as a
-- deploy-time obligation.
--
-- Schema, contract, workbook, prompt, both builds and the gateway revision
-- move; request schema, grammar, model, tokenizer and serving image stay.
-- Parent is the v10 release.

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
     'c94c7b5ae46e68304a3e5744cfea273637fe66841adc68a183c2c740b0f0aa1a',
     '8ec2637b2bf91777e8b265dd48267bd968144339be75d5112a43c747b2e998ef',
     'f4a4bc611545149954c861348ea355e93fd5fa76f02e72e0302e1783bb0d465c',
     m.request_schema_sha256,
     '0553a5a97a11919b01dec6347e22b3fdf2f6ba574325351380321dd31eb10f79',
     m.model_id, m.model_revision,
     '7c17442cb60eb90227f57c0848ba038c860d7e5064c3648b77936e42a1d965aa',
     'qwen_extractor_v11', m.grammar_version,
     m.tokenizer_runtime_manifest_sha256,
     '58cc49c2a02b98090485c7bec5ed9472cd27b4e08e8ea57c348982a6db7f9702',
     'sha256:a45fe6379291185a7557dafb244b9d01c34786c225a4b5d16a48cd77d1e0fb6b',
     m.serving_image_digest
    from ontology.release_manifests m
   where m.prompt_version = 'qwen_extractor_v10'
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
   where parent.prompt_version = 'qwen_extractor_v10'
     and child.prompt_version = 'qwen_extractor_v11'
     and child.grammar_version = parent.grammar_version
     and child.model_revision = parent.model_revision
     and child.serving_image_digest = parent.serving_image_digest
     and child.request_schema_sha256 = parent.request_schema_sha256
     and child.schema_sha256 <> parent.schema_sha256
     and child.gateway_revision <> parent.gateway_revision
     and child.gateway_image_digest <> parent.gateway_image_digest
     and child.release_build_sha256 <> parent.release_build_sha256;
  if n <> 1 then
    raise exception '0298: the release does not move exactly what changed';
  end if;
end;
$$;
