-- 0304 — the release in which the GPU stops decoding one giant answer.
--
-- **The throughput defect was never the model.** A batch was one prompt:
-- `generate([prompt])` on an eight-item document is a single sequence, one
-- enormous structured JSON decoded token by token while every other slot on
-- the GPU sits idle. The endpoint's own log measured 162 s for an eight-item
-- batch — and 162 s sat just under the caller's 180 s patience, so roughly
-- every other answer was abandoned seconds before it landed, read by the
-- gateway, deleted as retention requires, and re-run for ever. Five hours of
-- GPU produced six usable batches. Both halves are fixed: the serving
-- container fans a batch into one prompt per item and lets the engine
-- continuously batch them behind a cached prefix, and callers now wait past
-- the gateway's own ceiling rather than racing it.
--
-- **The serving image moves for the first time in this whole sequence**, and
-- it carries a second change worth naming: `serve.py` filters its engine
-- arguments against `EngineArgs` itself and reports anything dropped in the
-- runtime block. The image build gates exactly one argument by name because
-- that one was paid for; adding `enable_prefix_caching` beside it put a
-- second unguarded keyword in the same position, and a wrong keyword is a
-- `TypeError` on a GPU this account takes hours to reacquire.
--
-- **Prompt v13** states the labelling rule the owner gave: english and
-- original labels are for every family, not only people, and the original is
-- the entity's own language rather than the script a surface happened to use
-- — so 路人超能100 reads `Mob Psycho 100 (モブサイコ100)`. A Mob Psycho few-shot
-- carries it. Schemas are untouched and asserted so; the gateway revision is
-- untouched too, since the rule lives in the compiled contract the image
-- bundles. Parent is the v12 release.

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
     'a7900a2155226de1693a413bca78f4c4707814091adbf71716c53a175c77412c',
     'ed9f2757d95e87632a7467f2d3390b747ca8b984ebe1fe5192b46f14589dcfcf',
     m.schema_sha256, m.request_schema_sha256,
     '2715e36169fc9a36561e202179f1306f5646698bc21dc42e26605487f494232e',
     m.model_id, m.model_revision, m.gateway_revision,
     'qwen_extractor_v13', m.grammar_version,
     m.tokenizer_runtime_manifest_sha256,
     '2a4ca665949c9c972b6e432ada87fb9bf3d4dede686d2fd49438493b2a82f35b',
     'sha256:71e5511bef89c1c3f3d0229e86a68c562091cd683331a8fac27f9cdd8cff6564',
     'sha256:8c44509162f08aeed07c780acd42ec3bc01056eec49bff1576fbd6f9ab832225'
    from ontology.release_manifests m
   where m.prompt_version = 'qwen_extractor_v12'
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
   where parent.prompt_version = 'qwen_extractor_v12'
     and child.prompt_version = 'qwen_extractor_v13'
     -- Untouched, and each one a thing this release deliberately did not move.
     and child.schema_sha256 = parent.schema_sha256
     and child.request_schema_sha256 = parent.request_schema_sha256
     and child.grammar_version = parent.grammar_version
     and child.gateway_revision = parent.gateway_revision
     and child.model_revision = parent.model_revision
     and child.tokenizer_runtime_manifest_sha256
         = parent.tokenizer_runtime_manifest_sha256
     -- Moved, and the serving image is the one that has never moved before.
     and child.serving_image_digest <> parent.serving_image_digest
     and child.gateway_image_digest <> parent.gateway_image_digest
     and child.release_build_sha256 <> parent.release_build_sha256
     and child.compiled_contract_sha256 <> parent.compiled_contract_sha256;
  if n <> 1 then
    raise exception '0304: the release does not move exactly what changed';
  end if;
end;
$$;
