-- 0300 — the wire's family→root map is pinned to the ontology's, and v12
-- teaches the boundary tests the v6 corpus proves were missing.
--
-- Diagnosis (2026-08-21, in the plan of record): 629 of 649 model mentions
-- were extracted under qwen_extractor_v6, before any boundary rule existed.
-- On topic-role mentions the model answered the content genre instead of the
-- surface entity — K-pop groups as music_work (270), CJK fandom as anime
-- (21), Mnet as book, ANOVA as sport — and watched content genres became
-- activities (asmr, study with me) because §2.2's watch-vs-do line was never
-- stated. v12 states the rules and adds a fancam and a study-with-me
-- few-shot; the validator now refuses `family_root_mismatch` outright.
--
-- The refusal reads a map. That map exists in three places — the workbook,
-- the validator module, and this database's `ontology.cardinal_root_map` —
-- and the compiler already pins the first two to each other. This migration
-- pins the pair to the third, so a root reassignment in the ontology that
-- nobody carried to the wire fails the next replay instead of shipping a
-- contradiction.

do $$
declare
  wire_map constant jsonb := '{
    "person": "person", "group": "group", "organization": "organization",
    "franchise": "franchise", "work": "work", "anime": "work", "book": "work",
    "game": "work", "music_work": "work", "album": "work",
    "sport": "activity", "activity": "activity", "idea": "concept",
    "place": "none", "culture": "concept", "event": "event", "tour": "event"
  }'::jsonb;
  entry record;
  ontology_root text;
begin
  for entry in select * from jsonb_each_text(wire_map) loop
    select coalesce(replace(m.root_id, 'cardinal:', ''), 'none')
      into ontology_root
      from ontology.cardinal_root_map m
     where m.concept_kind = entry.key;
    if not found then
      raise exception '0300: the ontology map does not know family %', entry.key;
    end if;
    if ontology_root <> entry.value then
      raise exception '0300: family % is % on the wire and % in the ontology',
        entry.key, entry.value, ontology_root;
    end if;
  end loop;
end;
$$;

-- The v12 release. Schema and request unchanged and asserted so; the prompt,
-- both builds and the gateway revision move (the refusal lives in the
-- gateway's validator). Parent is the v11 release.
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
     '6f738eb9eea3ae624db522dd48eeb9527c7bf39f38dd76933fa0a61a2962b6ff',
     '3da47c0e8148d3caa6afcace3b55865056604ca6c8eeae3b9f976d8eaf08004b',
     m.schema_sha256, m.request_schema_sha256,
     'f124615c772e2a8d46b1d894d7703f87917c70e6e5226934692211bd92071938',
     m.model_id, m.model_revision,
     'b881c3af05da5e56b4102396bf8c8a47e8b8a390d747e3b37fedc57b30e9fa62',
     'qwen_extractor_v12', m.grammar_version,
     m.tokenizer_runtime_manifest_sha256,
     'e7caf8444fc9896816e5fd50aa8934fde81a22547f41f8c32f207c8d694c7d88',
     'sha256:2155f88939cb433a767c41833e90dd943b12d88e0a5f7b21ed5be83569b5fe8d',
     m.serving_image_digest
    from ontology.release_manifests m
   where m.prompt_version = 'qwen_extractor_v11'
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
   where parent.prompt_version = 'qwen_extractor_v11'
     and child.prompt_version = 'qwen_extractor_v12'
     and child.schema_sha256 = parent.schema_sha256
     and child.request_schema_sha256 = parent.request_schema_sha256
     and child.grammar_version = parent.grammar_version
     and child.model_revision = parent.model_revision
     and child.serving_image_digest = parent.serving_image_digest
     and child.gateway_revision <> parent.gateway_revision
     and child.gateway_image_digest <> parent.gateway_image_digest
     and child.release_build_sha256 <> parent.release_build_sha256;
  if n <> 1 then
    raise exception '0300: the release does not move exactly what changed';
  end if;
end;
$$;
