"""The runtime reader of the compiled contract.

`tools/compile_semantic_contract.py` and `semantic/tests/test_semantic_contract.py`
check that the artifact is *derivable from its sources*. This checks the other
side: that the pipeline actually reads it, and that it refuses rather than
improvises when it cannot.

**The refusals are the point.** A reader that fell back to hardcoded families
when the JSON was missing would run, produce plausible output, and diverge from
the artifact the deploy attested to — a divergence invisible to the attestation,
because the attestation describes a file nothing opened.
"""

from __future__ import annotations

import json
import pathlib

import pytest

from written_ontology import semantic_contract as reader


@pytest.fixture
def contract():
    reader.load.cache_clear()
    return reader.load()


def test_the_contract_is_found_and_identifies_itself(contract):
    assert contract.path.name == reader.CONTRACT_FILENAME
    assert len(contract.contract_sha256) == 64
    # A contract cannot state its own hash, so this is computed rather than read.
    assert contract.contract_sha256 not in json.dumps(contract.data)


def test_the_two_family_vocabularies_are_kept_apart(contract):
    """18 the model may emit, 23 the ontology stores.

    Conflating them is how a model comes to propose a `hub` — navigation
    furniture rather than a thing anybody is interested in.
    """
    assert len(contract.families) == 18
    assert len(contract.ontology_families) == 23
    assert set(contract.families) < set(contract.ontology_families)
    assert set(contract.ontology_families) - set(contract.families) == {
        "channel", "event_type", "game_category", "hub", "platform",
    }


def test_a_family_compiles_to_a_concept_kind_or_explicitly_to_nothing(contract):
    assert contract.concept_kind_for("anime") == "work"
    assert contract.concept_kind_for("person") == "creator"
    assert contract.concept_kind_for("sport") == "sport"
    # `channel` is stored as an external entity, not a concept — and the reader
    # says so rather than guessing a kind.
    assert contract.concept_kind_for("channel") is None
    assert contract.storage_for("channel")["storage"] == "external_entities"

    with pytest.raises(reader.ContractUnavailable):
        contract.concept_kind_for("telepathy")


def test_hub_aliases_resolve_and_a_canonical_id_is_its_own_answer(contract):
    """`hub:game` and `hub:games_play` are one drawer under two names."""
    assert contract.canonical_hub("hub:game") == "hub:games_play"
    assert contract.canonical_hub("root:game") == "hub:games_play"
    assert contract.canonical_hub("game") == "hub:games_play"
    assert contract.canonical_hub("hub:games_play") == "hub:games_play"
    with pytest.raises(reader.ContractUnavailable):
        contract.canonical_hub("hub:nonsense")


def test_storage_names_resolve_to_this_databases_schema(contract):
    """`private` here holds the push secret; the semantic objects are elsewhere."""
    assert contract.production_table("private.review_items") == \
        "semantic_private.review_items"
    assert contract.production_table("ontology.release_manifests") == \
        "ontology.release_manifests"
    assert len(contract.required_tables) == 16
    assert not any(name.startswith("private.") for name in contract.required_tables)


def test_the_overlay_is_off_and_that_is_read_from_the_artifact(contract):
    """Not a build flag — turning it on must be a contract change a deploy compares."""
    assert contract.initial_mode == "exact_only"
    assert contract.model_lane_mode == "off"
    assert contract.model_may_be_called is False
    assert contract.may_write_user_candidates is False
    assert len(contract.jobs) == 9
    assert "extract_mentions" in contract.jobs


def test_an_unrecognised_mode_raises_rather_than_defaulting(contract):
    """**Fails closed.** The predecessor asked whether the value contained
    "disabled" and treated anything else as enabled, so a typo meant a model
    running against somebody's library."""
    import copy

    import pytest

    from written_ontology.semantic_contract import MODEL_LANE_MODES

    for bad in ("", "enabled", "disabled_until_all_deploy_gates_pass", "Shadow"):
        broken = copy.deepcopy(contract)
        broken.data["runtime_requirements"]["qwen_overlay"] = bad
        with pytest.raises(ValueError):
            broken.model_lane_mode

    assert MODEL_LANE_MODES == ("off", "evaluation", "shadow", "active")


def test_the_two_mode_lists_agree(contract):
    """The reader mirrors the compiler's constants rather than importing them,
    because this module ships in the Lambda bundle and the compiler does not.
    A mirror that nobody checks is a divergence waiting to happen."""
    import importlib.util
    import pathlib as _pathlib

    from written_ontology.semantic_contract import (
        MODEL_LANE_MODES, MODES_CALLING_MODEL, MODES_WRITING_CANDIDATES)

    path = (_pathlib.Path(__file__).resolve().parent.parent.parent
            / "tools" / "compile_semantic_contract.py")
    spec = importlib.util.spec_from_file_location("written_contract_compiler", path)
    compiler = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(compiler)

    assert compiler.MODEL_LANE_MODES == MODEL_LANE_MODES
    assert compiler.MODES_CALLING_MODEL == MODES_CALLING_MODEL
    assert compiler.MODES_WRITING_CANDIDATES == MODES_WRITING_CANDIDATES


def test_the_attestation_names_what_a_run_obeyed(contract):
    attestation = contract.attestation()
    assert attestation["compiled_contract_sha256"] == contract.contract_sha256
    assert len(attestation["workbook_sha256"]) == 64
    assert len(attestation["schema_sha256"]) == 64
    assert attestation["grammar_version"] == "semantic_grammar_v3"
    # Every field a release manifest records about the model side is present,
    # including the two still carrying placeholders — an absent field and a
    # visibly unpinned one are different problems.
    assert set(attestation) >= {
        "model_id", "model_revision", "gateway_revision", "prompt_version",
    }


def test_a_missing_contract_refuses_rather_than_defaults(tmp_path, monkeypatch):
    monkeypatch.setenv("WRITTEN_SEMANTIC_CONTRACT", str(tmp_path / "absent.json"))
    reader.load.cache_clear()
    with pytest.raises(reader.ContractUnavailable) as refusal:
        reader.load()
    assert "not a file" in str(refusal.value)
    reader.load.cache_clear()


@pytest.mark.parametrize("damage,expected", [
    ({"contract_version": "compiled_semantic_contract_v2"}, "contract_version"),
    ({"source_hashes": {"workbook_sha256": "x"}}, "mention_schema_sha256"),
    ({"source_hashes": {}}, "workbook_sha256"),
])
def test_a_contract_that_cannot_say_what_it_came_from_is_refused(
    tmp_path, monkeypatch, contract, damage, expected
):
    """`source_hashes` is how a running Lambda answers the only question an
    incident asks: which workbook and which schema produced this behaviour."""
    broken = dict(contract.data)
    broken.update(damage)
    path = tmp_path / reader.CONTRACT_FILENAME
    path.write_text(json.dumps(broken))

    monkeypatch.setenv("WRITTEN_SEMANTIC_CONTRACT", str(path))
    reader.load.cache_clear()
    with pytest.raises(reader.ContractUnavailable) as refusal:
        reader.load()
    assert expected in str(refusal.value)
    reader.load.cache_clear()


def test_the_bundled_copy_wins_over_the_repository():
    """A deployed Lambda has no repository, and must not depend on one.

    `aws/worker/build.sh` stages the JSON beside the module for exactly this,
    and the lookup order is what makes the staged copy the one that runs.
    """
    module_dir = pathlib.Path(reader.__file__).resolve().parent
    assert reader._BUNDLED == module_dir / reader.CONTRACT_FILENAME
    # And it is deliberately absent from the tree: one copy in the repository,
    # under semantic/contracts/, staged into the bundle at build time.
    assert not reader._BUNDLED.exists(), (
        "the contract has been committed into the package directory, which makes "
        "a second copy that can drift from semantic/contracts/"
    )
    assert reader._REPOSITORY.is_file()
