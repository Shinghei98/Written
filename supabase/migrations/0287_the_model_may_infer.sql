-- 0287 — the release in which the model may say what it knows.
--
-- The wire format could not express an inferred term: every mention required
-- `source_field`, `start` and `end`, and the validator held `surface` to equal
-- the source slice unconditionally. "One Piece" from a title reading 路飛 was
-- refused before any table saw it — which was right while the lane extracted,
-- and wrong the moment the product became dictionary building, where users
-- validate and the weight decides what survives.
--
-- **`mention_extract_v3`**, a new file rather than an edit: an inferred
-- mention carries no offsets, so a v2 validator cannot read one, and calling
-- it v2 would make the version string a lie. It adds `mention_inferred`
-- (discriminated by `source_field: "inferred"`, the mechanism `mention_tag`
-- already used), `english_label` and `original_label` on every variant, and
-- restores `relation_hypothesis` — deleted from v1 as unread — so a term can
-- arrive with its predicate attached. The twelve proposable predicates were
-- already in the workbook and the grammar sheet; `part_of_franchise` is
-- "Luffy is a character in One Piece" and nothing new was invented.
--
-- **What did not move.** Every guard on an extracted mention: bounds,
-- code-point offsets, `surface == source[start:end]`, the NFC comparison,
-- duplicate spans. Inference is permitted; *claiming to have read* something
-- that was not there is still refused, because those are different lies and
-- the dictionary cannot tell them apart afterwards.
--
-- Prompt `qwen_extractor_v7` states the rule conditionally rather than flatly,
-- and adds the owner's granularity rules to the model rather than filtering
-- them afterwards: the singer not the track, the composer for classical, the
-- franchise not the character or the installment, English beside the original.
--
-- Schema, grammar, prompt, contract, workbook, gateway revision, both images
-- and both builds all move. Parent 3e92dac7.

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
     '91d96f7a36a18807584948be33a62c393c9459ae52f2bbd3c6432609d15a0e26',
     '7ba4187cc66cca8f18aab6b54772a114f91bfcdc44802e4e3eccc25f9ef6978f',
     '42d0e77fc56a10cf2ec5ac731ceea5497736459153cd2e38921c3b52c73cf93a',
     m.request_schema_sha256,
     '94153c375f9985a1d339634c92eb11d80eacead274fe74abe30cd3bf3d367719',
     m.model_id, m.model_revision,
     'f19fdb3e5432333ab72306cd1bf71df8399df6200e089e17c2cab43d34d6e5c1',
     'qwen_extractor_v7', 'semantic_grammar_v5',
     m.tokenizer_runtime_manifest_sha256,
     '05e763428c2ca380356a72d87498edd49f582d15126dc84a061f144cc897930f',
     'sha256:b00aa1b55320519830e2da0d1de8c2b8dca2b7e9240331cb47362ece36d6b1ba',
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
  select count(*) into n
    from ontology.release_manifests parent
    join ontology.release_manifests child on child.parent_release_id = parent.id
   where parent.release_build_sha256 = '27de43637032f60910b62fcf73d49777eafdebde4b136a7c0328486042be3640'
     and child.prompt_version = 'qwen_extractor_v7'
     and child.grammar_version = 'semantic_grammar_v5'
     -- The request schema, the tokenizer and the serving image are inherited
     -- by select rather than retyped: this release did not touch them and
     -- cannot silently disagree about them.
     and child.request_schema_sha256 = parent.request_schema_sha256
     and child.serving_image_digest = parent.serving_image_digest;
  if n <> 1 then
    raise exception '0287: the release did not inherit its parent''s unchanged pins';
  end if;
end;
$$;
