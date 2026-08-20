-- 0266 — the tenth release: the poll is sized against measured generation.
--
-- 0265 raised the batch to eight and the first eight-item call deferred, and
-- the next, and the next. The cause is arithmetic nobody had done: 77
-- two-item calls measured mean 8.6 s and worst 19 s — about 4.3 s an item
-- mean, 9.5 s worst — so an eight-item batch is ~34 s mean and ~76 s worst
-- against a stated poll of 25 s. Every call came back as a resume ticket,
-- and the resume path with its backoff is slower than the larger batch was
-- ever going to save. A throughput change that makes the normal path the
-- exception is not a throughput change.
--
-- The lane now states 75 s — the worst batch observed, inside the 90 s boto
-- read timeout that sits above it — and the loop's per-call reserve rises to
-- 85 s so it never starts a call it cannot wait out (a killed worker defers
-- nothing, which is how five expired leases once marked a job dead).
--
-- Worker only: no schema, no prompt, no grammar, no gateway. Only
-- release_build_sha256 moves. Parent 36508863.

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
     m.compiled_contract_sha256, m.workbook_sha256, m.schema_sha256,
     m.request_schema_sha256,
     '27de43637032f60910b62fcf73d49777eafdebde4b136a7c0328486042be3640',
     m.model_id, m.model_revision, m.gateway_revision,
     m.prompt_version, m.grammar_version,
     m.tokenizer_runtime_manifest_sha256, m.extraction_contract_manifest_sha256,
     m.gateway_image_digest, m.serving_image_digest
    from ontology.release_manifests m
   where m.release_build_sha256 = '49feb8affcd580b0cc9479a49f8cbfda8b14bbafe0c2d3cae5a9f1d7de7213d4'
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
  -- **Inherited, not retyped.** Every pin but the build carries over by
  -- select from the parent row, so this release cannot silently disagree
  -- with the artifacts it did not change.
  select count(*) into n from ontology.release_manifests parent
    join ontology.release_manifests child on child.parent_release_id = parent.id
   where parent.release_build_sha256 = '49feb8affcd580b0cc9479a49f8cbfda8b14bbafe0c2d3cae5a9f1d7de7213d4'
     and child.release_build_sha256 = '27de43637032f60910b62fcf73d49777eafdebde4b136a7c0328486042be3640'
     and child.schema_sha256 = parent.schema_sha256
     and child.request_schema_sha256 = parent.request_schema_sha256
     and child.gateway_revision = parent.gateway_revision
     and child.gateway_image_digest = parent.gateway_image_digest;
  if n <> 1 then
    raise exception '0266: the new release did not inherit its parent''s unchanged pins';
  end if;
end;
$$;
