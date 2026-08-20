-- 0290 — the release in which a song may name its film.
--
-- The Cardinal specification's cross-media premise, and the owner's own
-- examples: My Heart Will Go On should nominate Titanic; Oath Sign should
-- nominate the Fate franchise, anime, and Japanese pop culture — and a Fate
-- inferred from music must converge with a Fate discovered on YouTube. The
-- machinery for the inference shipped in 0287/0288; what the model lacked was
-- the *context*: it saw only the title, so it could not name the artist
-- instead of the track, let alone the film behind the song.
--
-- Three moves, one release:
--   * The request carries the music lane's **stated** context — performer,
--     composer, album, read off the observation where Apple states them. The
--     evidence row keeps holding only the title; context rides in the request
--     and is never retained beyond it.
--   * The output schema's extracted variant may cite the new fields, so a
--     mention of the performer is an extraction with a span, not an inference.
--   * Prompt v9 says the quiet part: performer, composer and album are stated
--     context; infer the film, franchise or culture a song belongs to when
--     you know it; an inferred franchise from music converges with the same
--     term from any lane — which the dictionary's (label, family) key makes
--     true by construction.
--
-- Convergence needs no new mechanism: `presumed_terms` is global and keyed on
-- the normalized label and family, so Fate from Oath Sign and Fate from a
-- YouTube subscription meet in one row, and 0285's weight sums their users.
--
-- Request and output schemas, contract, workbook and both builds move;
-- grammar and gateway revision stay, and the gateway image moves anyway
-- because it serves the prompt from its bundled contract (0288's lesson,
-- asserted again below). Parent fe6e9dc2.

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
     '974ab6202d9ec5dfd1f75110ee77472ca8490ce7e033570930f152e08ffae3a9',
     '083b8f85e4dc954b11515963be1eb8eb886ea984603e067785d6e22d2c34e1e2',
     'e8f27f56107430b0d8777532362bbe4de667c606aed3f34e97d13402d4ee0001',
     '049b8804c4471ea99e2533bc8959677309d1e01535999ccfcfd0017c5c512bf9',
     '7141a7b270c4be7997db95fd95835569de984f53b7986125fa8aca557a569cbf',
     m.model_id, m.model_revision, m.gateway_revision,
     'qwen_extractor_v9', m.grammar_version,
     m.tokenizer_runtime_manifest_sha256,
     'f4af99ac70eadd45b63d721f80ca0344ff4f24dc2b384afbdcc1dcaa16c7cfb7',
     'sha256:2c148f369de706c6e430c72eccc0433e8b97e83540995b3f610f280603034e19',
     m.serving_image_digest
    from ontology.release_manifests m
   where m.prompt_version = 'qwen_extractor_v8'
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
   where parent.prompt_version = 'qwen_extractor_v8'
     and child.prompt_version = 'qwen_extractor_v9'
     and child.grammar_version = parent.grammar_version
     and child.gateway_revision = parent.gateway_revision
     and child.gateway_image_digest <> parent.gateway_image_digest
     and child.request_schema_sha256 <> parent.request_schema_sha256
     and child.schema_sha256 <> parent.schema_sha256;
  if n <> 1 then
    raise exception '0290: the release does not move exactly what changed';
  end if;
end;
$$;
