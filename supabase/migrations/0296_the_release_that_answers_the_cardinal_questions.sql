-- 0296 — the release that answers the cardinal questions.
--
-- Cardinal specification §5.2, on the wire. `mention_extract_v4` makes every
-- mention say which of the eight immutable roots it believes it is
-- (cardinal_scores, selected_cardinal), which supplied parent it fits under
-- (parent_candidate_id — echoed from the request's candidate set, refused
-- when invented), a §5.3 missing-parent proposal when no supplied parent
-- fits, the user predicate the evidence would ground, and ranked alternatives
-- so the model does not pick the most famous reading to dodge provisional
-- state. `mention_extract_request_v2` is the other half: the worker sends the
-- forty most load-bearing published parents (axes excluded) for the model to
-- echo. Storage landed in 0295; this is the wire, the prompt
-- (`qwen_extractor_v10`) and both builds.
--
-- Everything moves except the grammar, the model and the serving image — and
-- unlike 0288/0290, `gateway_revision` moves too, because the gateway itself
-- learned to carry the candidate set and thread the echo check. Parent is the
-- v9 release.

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
     'b610fd6417aad18d3b39abd98cbcd860c0d9966541c7216fee647dcfebc39971',
     '5e8aff90e761e48e589096bcbbba293e8596859d445f8daa5327941d70cbb9d1',
     'bdf555243370ac9f23e1e4b1d5a1f3d718863458874e36453958d914108a7f11',
     'f774eb0e4d32b547d27d60748bc97f3949a5c5e1b8356b7535ef85e5717d9f0e',
     '4939954a55425aca0e0ac9b3a48ae9a1bb8ec0f35d295ea2aeb0471e94496304',
     m.model_id, m.model_revision,
     'ef2e201b9adbcdb16d8102187c97f241e025bb95f8d302d4ac70020f48d5bbc4',
     'qwen_extractor_v10', m.grammar_version,
     m.tokenizer_runtime_manifest_sha256,
     '4b0edc8ab96abbf517311f241bba443469e3366ca25fafaca14c4fd908df3aaa',
     'sha256:dd6f3f41069ebd55074a732294ae2596f9b2d6c2b1214210af9d910655a0a6a5',
     m.serving_image_digest
    from ontology.release_manifests m
   where m.prompt_version = 'qwen_extractor_v9'
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
   where parent.prompt_version = 'qwen_extractor_v9'
     and child.prompt_version = 'qwen_extractor_v10'
     and child.grammar_version = parent.grammar_version
     and child.model_revision = parent.model_revision
     and child.serving_image_digest = parent.serving_image_digest
     and child.tokenizer_runtime_manifest_sha256
         = parent.tokenizer_runtime_manifest_sha256
     -- And every artifact this release touched really moved — the gateway
     -- revision included, which 0288 and 0290 could legitimately inherit and
     -- this release cannot: the echo check lives in the gateway.
     and child.schema_sha256 <> parent.schema_sha256
     and child.request_schema_sha256 <> parent.request_schema_sha256
     and child.gateway_revision <> parent.gateway_revision
     and child.gateway_image_digest <> parent.gateway_image_digest
     and child.release_build_sha256 <> parent.release_build_sha256;
  if n <> 1 then
    raise exception '0296: the release does not move exactly what changed';
  end if;
end;
$$;
