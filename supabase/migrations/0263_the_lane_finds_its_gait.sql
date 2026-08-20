-- 0263 — the eighth release: the lane finds its gait.
--
-- Three worker changes, one build. (1) The evidence queue serves the
-- discovery lane first — YouTube is where the unknown nouns live, and a
-- strict FIFO had one account's 524 YouTube rows behind ~1,300 music rows,
-- days away at the measured 15 items/hour. (2) `extract_mentions` loops
-- gateway calls inside the job (up to 20, budget 200 s, per-batch commits,
-- per-batch request ids derived from the evidence rows so collection
-- survives any job identity) instead of one 2-item call per job — the wire
-- maximum is untouched, so no contract artifact moves. (3) `BUILD_REVIEW`
-- ranks continue the epoch instead of restarting at 0 per pass, and
-- model-proposed provisionals — the reason the lane exists — rank first.
--
-- Only release_build_sha256 moves; every other pin carries over from
-- 90efa6aa, which becomes the parent. Same doctrine as 0250/0254/0261: an
-- immutable release pays for a change with a new row.

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
     '1620517b99339df4a192d5c48eb3a0a37a78ec0edb1fc2856f186b2d9e227753',
     'f57f17f19967933434acb212f62a72f4a785e24804e43a7d1cdc37276deb441b',
     'aa30477736d23018421e29b07864710ef00b9d64e2fb07c5b9b0fe1af5f346f4',
     '8874529e8aabe48583e5dd91a03b45611c225d557c6b460b840e1b66e5b00f5f',
     'f6d065fcf5f2ed2d5fc8d827e05976f8fb3e6fccdd5ec2744ea775d49a4c21b2',
     'Qwen/Qwen3.5-9B',
     'c202236235762e1c871ad0ccb60c8ee5ba337b9a',
     '44a2209b7c98fd7d593f30e8188de11239d3729fcb3400d0d31601095c835e70',
     'qwen_extractor_v6', 'semantic_grammar_v4',
     '22b186f14646edf812947346f505b67e17832ebe2b6b6c454628db66184278a9',
     'e7648d068db2165779225bc8010f1ad3c81265adc2151eb7a17e1e0340a92593',
     'sha256:4a4b169477325dcf14c0f6e717102d086e32c24acc3777129b3ee1c757790c00',
     'sha256:57b87e2ea3434d788517bf674bc6e17787a54dca6631e9c940c9ee3fb3e6575a'
    from ontology.release_manifests m
   where m.model_lane_mode = 'shadow'
     and m.release_build_sha256 = '7d55dcc2b1da8c0a2792d51cf0eede97324f03b94746f9f26bf66603024d43d4'
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
  if n <> 4 then
    raise exception '0263: expected 4 shadow manifests as history, found %', n;
  end if;
  select count(*) into n from semantic_private.worker_jobs
   where job_type = 'evaluate_release' and status = 'queued';
  if n < 1 then
    raise exception '0263: no queued evaluate_release job for the new manifest';
  end if;
end;
$$;
