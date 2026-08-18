"""The manifests, and the cycle they exist to avoid.

Stage 3 requires them generated from the running deployment rather than authored
beside it — that is the difference between an attestation and a claim.
"""
from __future__ import annotations

import importlib.util
import json
import pathlib

import pytest

REPOSITORY = pathlib.Path(__file__).resolve().parents[2]


@pytest.fixture(scope="module")
def manifest():
    spec = importlib.util.spec_from_file_location(
        "gateway_manifest", REPOSITORY / "aws" / "gateway" / "manifest.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def tokenizer_dir(tmp_path):
    (tmp_path / "tokenizer.json").write_text('{"model":{}}')
    (tmp_path / "tokenizer_config.json").write_text(
        json.dumps({"chat_template": "{% for m in messages %}{{ m }}{% endfor %}"}))
    return tmp_path


def test_an_absent_file_is_recorded_as_absent(manifest, tokenizer_dir):
    """"The tokenizer had no merges.txt" and "nobody looked" must not read the
    same, which is why every expected name appears with a present flag."""
    built = manifest.tokenizer_runtime_manifest(tokenizer_dir, "repo", "rev")
    assert built["files"]["tokenizer.json"]["present"] is True
    assert built["files"]["merges.txt"] == {"present": False}
    assert set(built["files"]) == set(manifest.TOKENIZER_FILES)


def test_the_chat_template_is_hashed_and_thinking_is_recorded(manifest, tokenizer_dir):
    """A manifest that did not carry `enable_thinking` could not afterwards tell
    a run that disabled thinking from one that forgot to."""
    built = manifest.tokenizer_runtime_manifest(tokenizer_dir, "repo", "rev")
    assert built["chat_template"]["sha256"]
    assert built["chat_template_kwargs"] == {"enable_thinking": False}


def test_a_manifest_never_contains_its_own_digest(manifest, tokenizer_dir):
    """The cycle the memo names: a contract carrying the hash of a manifest that
    carries the hash of the contract. Each layer names the one below it."""
    tokenizer = manifest.tokenizer_runtime_manifest(tokenizer_dir, "repo", "rev")
    assert manifest.digest(tokenizer) not in json.dumps(tokenizer)


def test_the_deployment_manifest_names_the_two_below_it(manifest, tokenizer_dir):
    from written_ontology.semantic_contract import load
    tokenizer = manifest.tokenizer_runtime_manifest(tokenizer_dir, "repo", "rev")
    extraction = manifest.extraction_contract_manifest(load())
    deployment = manifest.deployment_manifest(
        tokenizer=tokenizer, extraction=extraction, model_lane_mode="off",
        environment="test", gateway_image_digest="sha256:g",
        serving_image_digest="sha256:s")
    assert deployment["tokenizer_runtime_manifest_sha256"] == manifest.digest(tokenizer)
    assert deployment["extraction_contract_manifest_sha256"] == manifest.digest(extraction)
    # The image digest lives here, outside the image it identifies: a build
    # cannot hash a file containing the hash of that build.
    assert deployment["gateway_image_digest"] == "sha256:g"
    assert manifest.digest(deployment) not in json.dumps(deployment)


def test_the_digest_is_stable_across_key_order(manifest, tokenizer_dir):
    built = manifest.tokenizer_runtime_manifest(tokenizer_dir, "repo", "rev")
    shuffled = dict(reversed(list(built.items())))
    assert manifest.digest(built) == manifest.digest(shuffled)


def test_the_outcome_vocabulary_matches_the_gateway(manifest):
    """A reader must be able to tell a code it does not recognise from one this
    deployment could not produce, so the manifest carries the closed fourteen."""
    from written_ontology import gateway
    assert len(manifest.OUTCOMES) == 15
    assert "semantic_abstention" in manifest.OUTCOMES
    # Every code the gateway can raise is one the manifest declares.
    assert set(gateway._OUTCOME_FOR.values()) <= manifest.OUTCOMES
    assert set(gateway._NOT_RETRYABLE) <= manifest.OUTCOMES
