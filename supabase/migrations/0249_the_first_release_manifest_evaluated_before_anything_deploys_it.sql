-- 0249 — the first release manifest ever, evaluated before anything deploys it.
--
-- `ontology.release_manifests` has held zero rows since `0203` created it, and
-- that emptiness was the design: no manifest, no `authorized_model_release()`,
-- no lane. Everything the constraint demands of a non-`off` row now exists as a
-- measurement rather than an intention — the serving image was attested from a
-- GPU on 2026-08-19 (`aws/serving/PINNED.json`, `out/attestation/runtime.json`),
-- the two hashes are pinned in the compiled contract, and both bundles carrying
-- that contract are deployed.
--
-- **Every value here is copied from an artifact, none is typed from memory.**
-- The attestation values are `SemanticContract.attestation()` on the deployed
-- contract; `extraction_contract_manifest_sha256` is `manifest.digest(
-- extraction_contract_manifest(contract))` computed by the gateway's own code;
-- the image digests are what ECR answered after each build's gates passed.
--
-- **`evaluation`, and what that licenses.** The model may be called — against
-- the synthetic fixture corpus only, `0239` refusing any evaluation invocation
-- that names a person — and nothing attributable to a person may be written
-- (`0237`; `may_write_user_candidates` is false in the contract). `shadow` is a
-- later row, not an edit: a new manifest supersedes, history stays.
--
-- **The slot is deliberately NOT set here, and that is the design being
-- respected rather than a step forgotten.** Deploying a release —
-- `deployment_slots` naming this manifest — is production *state*, not schema:
-- `0248` states the replay invariant in as many words ("no non-off release is
-- deployed in a replayed chain"), and the lineage contracts behind this
-- migration each deploy a fixture release to test the guards, which
-- `guard_one_calling_deployment` refuses while any real one stands. A slot set
-- by migration broke four of them at once. It is the model-lane password's
-- class of fact: registered machinery in the repository, the act performed out
-- of band — and the ordering comes out better for it, because the slot should
-- point at a manifest only after its gate report has passed, not before.
--
-- The `evaluate_release` job IS enqueued here, because a manifest nothing
-- evaluates is a claim nothing checked — the worker compares the deployed
-- bundle's loaded contract against this row and writes the verdict to the
-- append-only `release_gate_reports`. Evaluation needs no slot: it takes the
-- manifest by id.

do $$
declare
  published_version uuid;
  manifest uuid;
begin
  -- The chain maintains exactly one published version (unique partial index);
  -- a chain where none exists has broken earlier than this migration.
  select id into strict published_version
    from ontology.versions where status = 'published';

  insert into ontology.release_manifests
    (base_ontology_version_id, environment, model_lane_mode,
     compiled_contract_sha256, workbook_sha256, schema_sha256,
     request_schema_sha256, release_build_sha256,
     model_id, model_revision, gateway_revision,
     prompt_version, grammar_version,
     tokenizer_runtime_manifest_sha256, extraction_contract_manifest_sha256,
     gateway_image_digest, serving_image_digest)
  values
    (published_version, 'production', 'evaluation',
     '9e5bcabe9d59fe9d5772811a3325f2dac47a3d30248817becbdb2e171180667a',
     '99f4ddb9dddbf5e2bf5a4860bff61a07542cdaf47c00fc17f77a20c19f160007',
     '0cdf52b572f7d89d72447c5bc2e5aa67aaec3047cbfbcbf10dcb0df7fdc5de38',
     '74f2b0a46676c2bcc09758854b0604f1f52fefa9d969021604d377ff8fa1e02d',
     '837446f04402b4e1492ec236e553695d962ea63a25f7ce795d462f3fce75010e',
     'Qwen/Qwen3.5-9B',
     'c202236235762e1c871ad0ccb60c8ee5ba337b9a',
     'a8d422ceb020993c2ebe001e0ff64c694884993fb3859600b8b0c95a53ca0edc',
     'qwen_extractor_v5', 'semantic_grammar_v3',
     '22b186f14646edf812947346f505b67e17832ebe2b6b6c454628db66184278a9',
     'dfd11e3d41635cbd3f9fcc5e716f0989e1573349a3e9617afa0f56f0e467fb6c',
     'sha256:a05ba2f11088f18806d8d7b441d22bb2c34e54866bf7549697b08e0d95534c92',
     'sha256:57b87e2ea3434d788517bf674bc6e17787a54dca6631e9c940c9ee3fb3e6575a')
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

-- ---------------------------------------------------------------------------
-- What must stay true.
-- ---------------------------------------------------------------------------

do $$
declare
  release uuid;
  n integer;
begin
  -- **The manifest exists and the lane is still shut.** Registering a release
  -- and deploying it are two acts, and this migration performs only the first —
  -- `0248`'s replay invariant (no non-off release deployed in a fresh chain)
  -- must hold after this migration exactly as before it, or the lineage
  -- contracts behind it cannot stage their fixture releases.
  select id into strict release from ontology.release_manifests
   where model_lane_mode = 'evaluation';
  select count(*) into n from semantic_private.authorized_model_release();
  if n <> 0 then
    raise exception
      '0249: % release(s) are deployed by this migration; deployment is an '
      'operational act performed after the gate report passes, never here', n;
  end if;

  -- The verdict job exists for the evaluator to claim.
  select count(*) into n from semantic_private.worker_jobs
   where job_type = 'evaluate_release'
     and payload ->> 'release_manifest_id' = release::text;
  if n <> 1 then
    raise exception '0249: the evaluate_release job for this manifest is not queued';
  end if;
end;
$$;
