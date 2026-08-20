-- 0281 — the discovery lane stops losing seven extractions in ten.
--
-- Measured on the live lane, by outcome and source:
--
--   youtube      offset_invalid 382   succeeded 158   (71% refused)
--   apple_music  offset_invalid  46   succeeded 205   (18% refused)
--
-- The owner reported it as "typos, en masse". There are none: all 275
-- music mentions are exact substrings of their source title, and the two he
-- named turned out to be a genuine stylisation and a capital I in a font whose
-- I and l are the same stroke. The real defect was one layer down and far
-- worse — **the lane whose entire purpose is open-vocabulary discovery was
-- discarding 71% of what it found.**
--
-- `repair_offsets` recomputed a span only where the surface occurred **exactly
-- once**, on the reasoning that choosing between two occurrences would be
-- inventing a span. That reasoning does not hold: every occurrence of a
-- repeated surface holds the identical string, so the mention text is the same
-- whichever is chosen and only the provenance span moves. Meanwhile a long
-- video title repeats its own words constantly — which is exactly why YouTube
-- paid four times the music rate for a guard protecting nothing.
--
-- The repair now chooses the occurrence nearest the model's stated start,
-- using its claim as the hint it is. **A surface absent from the source is
-- still refused**, unchanged: that is hallucination rather than arithmetic,
-- and it is the case the condition existed for.
--
-- Gateway sources move, so this is a full release: contract, workbook,
-- gateway revision, both images, both builds. Prompt and grammar do not — the
-- model is asked the same question and more of its answers now survive.

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
     '0c98bd19361a72a27f6909b0e7960fd02c580c5194a4cd485df0a1da9ecfaae7',
     '1dee07a6972b54cc3c4ee8521581be7815bb9ee8cb1856254a8699f6e8d57510',
     m.schema_sha256, m.request_schema_sha256,
     '6bcb2a920ed58ced07adbfa2709429ed725d91f2894f222f98519664d3e761d6',
     m.model_id, m.model_revision,
     '288c38060a00731270ba16334b6966e3a6a288e92f6d17c90d4bc28a519c6f3e',
     m.prompt_version, m.grammar_version,
     m.tokenizer_runtime_manifest_sha256,
     '89c9addb5011dc8a8ad0852fac62464bca09aafae5d689e8e3e43b5eb91a44e4',
     'sha256:49899edcd4abcf076fb9be3455e38e255d0ba5468432b34792a14d3b625a3cbe',
     m.serving_image_digest
    from ontology.release_manifests m
   where m.release_build_sha256 = '27de43637032f60910b62fcf73d49777eafdebde4b136a7c0328486042be3640'
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
  -- Inherited, not retyped: the schema, prompt, grammar, tokenizer and serving
  -- image carry over by select, so this release cannot silently disagree with
  -- the artifacts it did not change.
  select count(*) into n
    from ontology.release_manifests parent
    join ontology.release_manifests child on child.parent_release_id = parent.id
   where parent.release_build_sha256 = '27de43637032f60910b62fcf73d49777eafdebde4b136a7c0328486042be3640'
     and child.gateway_revision = '288c38060a00731270ba16334b6966e3a6a288e92f6d17c90d4bc28a519c6f3e'
     and child.schema_sha256 = parent.schema_sha256
     and child.prompt_version = parent.prompt_version
     and child.grammar_version = parent.grammar_version;
  if n <> 1 then
    raise exception '0281: the new release did not inherit its parent''s unchanged pins';
  end if;
end;
$$;
