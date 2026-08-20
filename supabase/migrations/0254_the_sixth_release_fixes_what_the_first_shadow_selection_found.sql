-- 0254 — the sixth release: the first shadow selection found the column the
-- fixture path could never touch.
--
-- The shadow slot went live at 03:20Z and the 03:25Z armer tick armed the
-- first user-attributed job. Its handler raised UndefinedColumn:
-- `SELECT_EVIDENCE_ITEMS` ordered by `e.created_at`, and
-- `source_text_evidence`'s column is `fetched_at`. The fixture path —
-- everything the evaluation phase ever exercised — never executes that
-- query, so the wrong name shipped dark through four releases. This
-- codebase's recurring defect, in its purest form: a path that ships
-- unexercised is a path that fails on first use.
--
-- One line moved in overlay.py (order by e.fetched_at, e.id), so only
-- release_build_sha256 changes; every other pin carries over from the shadow
-- manifest 940da3e5, which becomes the parent. Same doctrine as 0250: an
-- immutable release pays for a fix with a new row, and the failed release
-- stays as history beside its two handler_error attempts.

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
     'a346ad084ef2e3363eb40f77da3f31e033f11a90beda4589a610820a5f68fc9d',
     'Qwen/Qwen3.5-9B',
     'c202236235762e1c871ad0ccb60c8ee5ba337b9a',
     '5a2fbc2f11bd89eea11f135df3a5d3b71bef74f52c9cb4e4caff11f91c85e0b3',
     'qwen_extractor_v6', 'semantic_grammar_v4',
     '22b186f14646edf812947346f505b67e17832ebe2b6b6c454628db66184278a9',
     '76675b83fe520a7bcf5a85354836129af8ae81f2e894eea67225569e78ee3338',
     'sha256:4c28ec9cc6b27e145148b6ad8d6b49f336dd6354120a75d455024174af32ba7d',
     'sha256:57b87e2ea3434d788517bf674bc6e17787a54dca6631e9c940c9ee3fb3e6575a'
    from ontology.release_manifests m
   where m.model_lane_mode = 'shadow'
     and m.release_build_sha256 = '1123dd4ca3bef8eab9bdfaa3641b28b0631d7c057ca320a4a64fe51b8d5d3c9e'
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
  if n <> 2 then
    raise exception '0254: expected 2 shadow manifests (940da3e5 and its fix), found %', n;
  end if;
  select count(*) into n from semantic_private.worker_jobs
   where job_type = 'evaluate_release' and status = 'queued';
  if n < 1 then
    raise exception '0254: no queued evaluate_release job for the fix manifest';
  end if;
end;
$$;
