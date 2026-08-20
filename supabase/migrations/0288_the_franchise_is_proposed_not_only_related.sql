-- 0288 — the franchise is proposed, not only related.
--
-- `0287` gave the model the ability to infer and it used it correctly but
-- partially. Probed with a title reading 路飛 vs 凱多 名場面 it returned both
-- characters with English names and, on each, the relation
-- `part_of_franchise → One Piece`. Exactly the predicate the owner asked for —
-- and One Piece existed only as the right-hand side of a relation. It was
-- never proposed as a term, so it minted no provisional, became no candidate,
-- and could never reach the review card. **The one thing the owner asked to
-- see — the franchise rather than the character — was the one thing the lane
-- could not offer.**
--
-- Two repairs, one release:
--
--   * `qwen_extractor_v8` tells the model to emit the franchise, group or
--     artist **as its own inferred mention and not only as a relation object**.
--     Re-probed: 路飛 (extracted, en Luffy), 凱多 (extracted, en Kaido) and
--     **One Piece (inferred, franchise)** — the shape this whole release exists
--     to produce.
--   * The worker writes the object of every relation into the dictionary too,
--     with the family the predicate implies rather than a guess. The owner's
--     rule that every term enters the internal table is unqualified, and this
--     is the case it was written for: a franchise should be known the first
--     time any character of it is seen, whether or not the model also named it
--     in its own right. A predicate whose object family is unknown contributes
--     nothing — a gap to notice rather than a term to invent.
--
-- The schema, grammar and gateway sources are untouched, so `schema_sha256`
-- and `gateway_revision` are inherited by select. The gateway image is rebuilt
-- regardless, because it serves the prompt out of its own bundled contract:
-- a prompt change with an unchanged gateway revision is exactly the case where
-- forgetting the image would leave the old instructions running under a
-- manifest claiming the new ones. Parent a594d8bb.

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
     '5877a5400ca5ad7fea29471003e72e2f01cba562cafc22f730e36203ca7bfd92',
     '977a39581eb5c3119b254908aff6ce928405961eae1a044927a0234350da680c',
     m.schema_sha256, m.request_schema_sha256,
     '4f07d20cbea81d5e882b642e574a18cb0037ec12d260bc37a0e29ceb4636496a',
     m.model_id, m.model_revision, m.gateway_revision,
     'qwen_extractor_v8', m.grammar_version,
     m.tokenizer_runtime_manifest_sha256,
     'c0457d692b69aea874eb3a6cf785538bd296210ddca47aefef0bf08b3623bdde',
     'sha256:b05e57137c0ecdba56ecb16fb7394f1397c4db702c25452b940dc4b7c2ca3013',
     m.serving_image_digest
    from ontology.release_manifests m
   where m.release_build_sha256 = '94153c375f9985a1d339634c92eb11d80eacead274fe74abe30cd3bf3d367719'
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
   where parent.release_build_sha256 = '94153c375f9985a1d339634c92eb11d80eacead274fe74abe30cd3bf3d367719'
     and child.prompt_version = 'qwen_extractor_v8'
     and child.schema_sha256 = parent.schema_sha256
     and child.grammar_version = parent.grammar_version
     and child.gateway_revision = parent.gateway_revision
     -- And the image did move, which is the pin most easily forgotten when the
     -- revision hash does not.
     and child.gateway_image_digest <> parent.gateway_image_digest;
  if n <> 1 then
    raise exception '0288: the release did not inherit exactly what it left alone';
  end if;
end;
$$;
