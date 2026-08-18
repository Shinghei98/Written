"""Manifests built from what was actually loaded.

Stage 3 requires the tokenizer-runtime, extraction-contract and deployment
manifests to be **generated from the running deployment**, not authored beside
it. That is the whole difference between an attestation and a claim: a manifest
typed into a workbook says what somebody intended to deploy.

## Four layers, and none of them hashes itself

The memo is explicit about the cycle to avoid — a compiled contract carrying the
hash of a tokenizer manifest that carries the hash of the compiled contract. So:

  1. the tokenizer runtime manifest covers only what determines tokenization;
  2. the extraction-contract manifest covers the schemas, prompt and validator;
  3. the deployment manifest references both and adds the image digests;
  4. the evaluation report references all three.

Each layer names the one below it and nothing above it. The image digest lives
in the deployment manifest, outside the image it identifies, because a build
cannot hash a file that contains the hash of that build.

`0235` is where these land in the database, and its check constraint is why they
matter: a manifest attesting a lane that may call a model must name what it
calls.
"""
from __future__ import annotations

import hashlib
import json
import pathlib
from typing import Any

#: What determines tokenization, and nothing else. A file absent from the
#: deployment is recorded as absent rather than skipped: "the tokenizer had no
#: merges.txt" and "nobody looked" must not read the same.
TOKENIZER_FILES = (
    "tokenizer.json",
    "tokenizer_config.json",
    "vocab.json",
    "merges.txt",
    "special_tokens_map.json",
    "added_tokens.json",
)


def _sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _canonical(payload: dict[str, Any]) -> str:
    """Sorted, separator-fixed JSON, so a manifest hashes the same twice."""
    return json.dumps(payload, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False)


def digest(manifest: dict[str, Any]) -> str:
    """The manifest's own hash, computed over its canonical form.

    Never stored inside the manifest: a document cannot state its own digest,
    which is the same reason `compile_semantic_contract` computes the contract
    hash at read time rather than emitting it.
    """
    return hashlib.sha256(_canonical(manifest).encode()).hexdigest()


def tokenizer_runtime_manifest(directory: str | pathlib.Path,
                               model_repo: str, model_revision: str) -> dict[str, Any]:
    """Layer 1, read off the files the serving engine actually loaded."""
    root = pathlib.Path(directory)
    files: dict[str, Any] = {}
    for name in TOKENIZER_FILES:
        path = root / name
        files[name] = (
            {"present": True, "bytes": path.stat().st_size, "sha256": _sha256(path)}
            if path.exists() else {"present": False}
        )

    chat_template = None
    config_path = root / "tokenizer_config.json"
    if config_path.exists():
        config = json.loads(config_path.read_text())
        template = config.get("chat_template")
        if isinstance(template, str):
            chat_template = {
                "sha256": hashlib.sha256(template.encode()).hexdigest(),
                "bytes": len(template.encode()),
            }

    try:  # the library that will do the tokenizing, not the one that wrote this
        import tokenizers
        tokenizers_version = tokenizers.__version__
    except Exception:  # noqa: BLE001
        tokenizers_version = None

    return {
        "manifest_kind": "tokenizer_runtime_v1",
        "model_repo": model_repo,
        "model_revision": model_revision,
        "files": files,
        "chat_template": chat_template,
        # **A workbook fact recorded as a runtime one.** `llm.qwen.enable_thinking`
        # is false, and a manifest that did not carry it could not afterwards
        # distinguish a run that disabled thinking from one that forgot to.
        "chat_template_kwargs": {"enable_thinking": False},
        "tokenizers_version": tokenizers_version,
    }


def extraction_contract_manifest(contract) -> dict[str, Any]:
    """Layer 2, from the compiled contract the gateway loaded."""
    attested = contract.attestation()
    return {
        "manifest_kind": "extraction_contract_v1",
        "compiled_contract_sha256": attested["compiled_contract_sha256"],
        "request_schema": contract.request_schema["$id"],
        "request_schema_sha256": attested["request_schema_sha256"],
        "output_schema": contract.versions["output_schema"],
        "output_schema_sha256": attested["schema_sha256"],
        "prompt_version": attested["prompt_version"],
        "grammar_version": attested["grammar_version"],
        "max_items_wire": contract.max_items_wire,
        "calibrated_max_items": contract.calibrated_max_items,
        "max_output_tokens": contract.max_output_tokens,
        "envelope_token_reserve": contract.envelope_token_reserve,
        # The outcome vocabulary the gateway may report, so a reader can tell a
        # code it does not recognise from one this deployment could not produce.
        "outcome_vocabulary": sorted(OUTCOMES),
    }


def deployment_manifest(*, tokenizer: dict[str, Any], extraction: dict[str, Any],
                        model_lane_mode: str, environment: str,
                        gateway_image_digest: str, serving_image_digest: str,
                        worker_build_sha256: str | None = None,
                        rollout_scope_revision: str | None = None,
                        database_fingerprint_sha256: str | None = None) -> dict[str, Any]:
    """Layer 3. References the two below it and adds what only a deploy knows."""
    return {
        "manifest_kind": "deployment_v1",
        "tokenizer_runtime_manifest_sha256": digest(tokenizer),
        "extraction_contract_manifest_sha256": digest(extraction),
        "compiled_contract_sha256": extraction["compiled_contract_sha256"],
        "model_repo": tokenizer["model_repo"],
        "model_revision": tokenizer["model_revision"],
        "gateway_image_digest": gateway_image_digest,
        "serving_image_digest": serving_image_digest,
        "worker_build_sha256": worker_build_sha256,
        "database_fingerprint_sha256": database_fingerprint_sha256,
        "environment": environment,
        "model_lane_mode": model_lane_mode,
        "rollout_scope_revision": rollout_scope_revision,
    }


#: `model_invocation_items.outcome`, restated for the manifest and checked
#: against the database by the replay rather than trusted here.
OUTCOMES = frozenset({
    "succeeded", "semantic_abstention", "input_oversize", "output_overflow",
    "schema_invalid", "offset_invalid", "missing_item", "duplicate_item",
    "source_stale", "timeout", "rate_limited", "provider_error",
    "contract_mismatch", "circuit_open",
})
