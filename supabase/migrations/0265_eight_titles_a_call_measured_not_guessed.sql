-- 0265 — the ninth release: eight titles a call, measured rather than guessed.
--
-- The wire maximum was two, and two was not a model limit — it fell out of the
-- packing formula, whose per-item reserve was 1280 output tokens against a
-- 4096 ceiling. That reserve was authored before any real call had been made.
--
-- The measurement, from 114 real two-item invocations over twelve hours:
-- mean 307 output tokens, p99 763, worst 787 — about 394 per item at the
-- worst, against a reserve three times that. So the reserve becomes 600 (a
-- shade over 1.5x the worst item observed) and the ceiling 8192, which the
-- formula turns into ten permitted items; eight is taken, keeping headroom on
-- both numbers rather than spending it. Deliberately not the maximum the
-- arithmetic allows: the grammar was validated at two, a larger batch is a
-- larger unit of work to lose to one bad item, and the receipts at eight are
-- what would justify going further.
--
-- Both schemas move (`maxItems`, and `item_index`'s bound with it), so the
-- request and output hashes, the compiled contract, the workbook and both
-- builds all move. Prompt and grammar do not: the question is unchanged, only
-- how many items it is asked about at once. Parent 2720b654.

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
     '85bfc9cf53c7deb42608f0afc489ce239b2b29a659813c6acbecbe407e77f532',
     'ed608d527e68f2b7a3e34c3c5de1e8830cabff9dea1d2bf7b6f272e675ff68b8',
     '8a53529b30c9ae0b7689dc34a1e6cd5379df833b0e492e473db7df78eb42bc40',
     'b48ac69a5f4831db5a92bd4e809e2a8225f2500040d7a18c14063a1e8508f7c9',
     '49feb8affcd580b0cc9479a49f8cbfda8b14bbafe0c2d3cae5a9f1d7de7213d4',
     'Qwen/Qwen3.5-9B',
     'c202236235762e1c871ad0ccb60c8ee5ba337b9a',
     '44a2209b7c98fd7d593f30e8188de11239d3729fcb3400d0d31601095c835e70',
     'qwen_extractor_v6', 'semantic_grammar_v4',
     '22b186f14646edf812947346f505b67e17832ebe2b6b6c454628db66184278a9',
     'd5ec693f56ff26f02a0077fd37b3030b9aca21acce3d53396fca4d46a846abeb',
     'sha256:3fa5f74b71a45562025d83bbd846ab634d04432f829940f043bba1f096c3138a',
     'sha256:57b87e2ea3434d788517bf674bc6e17787a54dca6631e9c940c9ee3fb3e6575a'
    from ontology.release_manifests m
   where m.model_lane_mode = 'shadow'
     and m.release_build_sha256 = 'f6d065fcf5f2ed2d5fc8d827e05976f8fb3e6fccdd5ec2744ea775d49a4c21b2'
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
  if n <> 5 then
    raise exception '0265: expected 5 shadow manifests as history, found %', n;
  end if;
  select count(*) into n from semantic_private.worker_jobs
   where job_type = 'evaluate_release' and status = 'queued';
  if n < 1 then
    raise exception '0265: no queued evaluate_release job for the new manifest';
  end if;
end;
$$;
