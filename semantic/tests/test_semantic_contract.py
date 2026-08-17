"""The compiled semantic contract must be derivable from its stated sources.

**Everything here fails silently in production.** An enum that drifts between the
workbook and the JSON Schema does not raise — it makes a predicate unreachable,
so the model is never told it exists and a whole class of relation is quietly
never proposed. A family with no storage mapping does not raise either; it writes
a `concept_kind` the check constraint rejects, at the end of a pipeline, for one
term. A source hash that matches nothing does not raise anywhere at all: it just
means the artifact attests to a file that was not shipped with it.

**This repository has paid for the alternative three times.**
`SOURCE_ACTION_PAIRS` and `sources.action_weights` disagreed about `top_track`
for months while the comment describing that exact defect sat above the identical
bug for `playlist_item`. `0191` published a genre mint, revoked every privilege
on it, and left a header describing behaviour the shipped code could not perform.
The response is a compiler that derives rather than duplicates, and these tests
are what stop the compiler itself becoming the fourth copy.

The compiler is loaded by path rather than imported: `tools/` is not a package,
which is the same reason the worker tests load `aws/worker/*.py` by path.
"""

from __future__ import annotations

import copy
import importlib.util
import json
import os
import pathlib

import pytest

# **Hard imports, deliberately not `pytest.importorskip`.** Both are declared in
# `semantic/pyproject.toml`'s `dev` extra and both are what these tests are for:
# `openpyxl` reads the workbook the contract is compiled from, `jsonschema`
# checks that every stored few-shot is a valid complete response. Skipping on a
# missing dependency is how the schema tests sat unrun behind a green tick in CI
# — the exact failure the workflow's own header comment exists to prevent. A
# missing dependency should stop the suite, not quietly shrink it.
import jsonschema

REPOSITORY = os.environ.get("WRITTEN_REPOSITORY_PATH")

pytestmark = pytest.mark.skipif(
    not REPOSITORY, reason="WRITTEN_REPOSITORY_PATH is unset"
)


@pytest.fixture(scope="module")
def compiler():
    path = pathlib.Path(REPOSITORY) / "tools" / "compile_semantic_contract.py"
    if not path.exists():
        pytest.skip("compiler not present")
    spec = importlib.util.spec_from_file_location("written_contract_compiler", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def sheets(compiler):
    return compiler.load_workbook()


@pytest.fixture(scope="module")
def schema(compiler):
    return json.loads(compiler.SCHEMA.read_text())


@pytest.fixture(scope="module")
def config(compiler, sheets):
    return compiler.config_of(sheets)


def test_the_artifacts_agree(compiler, sheets, schema):
    """The whole validation suite, run as the compiler runs it."""
    compiler.validate(sheets, schema)


def test_every_enum_is_sorted_equal_in_both_directions(compiler, config, schema):
    """A subset test would pass while the model is told about fewer predicates.

    That is not hypothetical: the prompt offered seven predicates while the
    schema allowed twelve, so `played_for` and `represented_team_in` existed in
    the grammar, were legal in the schema, and could never be produced — which
    silently disabled every sports roster relation.
    """
    mention = schema["$defs"]["mention"]["properties"]
    expected = {
        "llm.family.enum": mention["family_hypothesis"]["enum"],
        "llm.mention_role.enum": mention["mention_role"]["enum"],
        "llm.predicate.enum":
            schema["$defs"]["relation_hypothesis"]["properties"]["predicate"]["enum"],
        "llm.schema.abstain_reasons":
            [v for v in schema["$defs"]["item"]["properties"]["abstain_reason"]["enum"] if v],
    }
    for key, values in expected.items():
        assert sorted(compiler._split(config[key])) == sorted(values), key
    assert len(expected["llm.family.enum"]) == 18
    assert len(expected["llm.mention_role.enum"]) == 15
    assert len(expected["llm.predicate.enum"]) == 12
    assert len(expected["llm.schema.abstain_reasons"]) == 5


def test_the_grammar_and_the_schema_permit_the_same_predicates(compiler, sheets, schema):
    permitted = compiler.model_predicates(sheets)
    allowed = schema["$defs"]["relation_hypothesis"]["properties"]["predicate"]["enum"]
    assert sorted(permitted) == sorted(allowed)


def test_a_source_profile_may_narrow_but_never_widen(compiler, config, schema):
    union = set(schema["$defs"]["relation_hypothesis"]["properties"]["predicate"]["enum"])
    profiles = {k: v for k, v in config.items() if k.startswith("llm.predicate.profile.")}
    assert profiles, "no source profiles are declared"
    for key, value in profiles.items():
        assert set(compiler._split(value)) <= union, key


def test_every_family_maps_exactly_once_and_virtual_ones_map_to_nothing(compiler, config):
    """A family with no mapping writes a `concept_kind` the constraint rejects.

    And a virtual evidence family with a mapping would create a concept for a
    video — an observation becoming a thing somebody is interested in.
    """
    mappings = {
        k[len("term_family.map."):]: v
        for k, v in config.items()
        if k.startswith("term_family.map.") and k != "term_family.map.version"
    }
    declared = set(compiler._split(config["ontology.family.enum"]))
    assert declared - compiler.VIRTUAL_FAMILIES <= set(mappings)
    assert not (set(mappings) & compiler.VIRTUAL_FAMILIES)
    assert len(mappings) == 23


def test_the_model_may_not_emit_the_five_structural_families(compiler, config, schema):
    """`hub`, `channel`, `platform`, `game_category` and `event_type` are ours.

    A hub is navigation, a channel is a provider account, and the other three are
    axes. The model proposing one would be proposing a structural row rather than
    a conversation topic.
    """
    declared = set(compiler._split(config["ontology.family.enum"]))
    emittable = set(schema["$defs"]["mention"]["properties"]["family_hypothesis"]["enum"])
    assert emittable < declared
    assert declared - emittable == set(compiler.MODEL_FORBIDDEN_FAMILIES)


def test_no_legacy_hub_survives_and_redirects_land_on_canonical_ids(compiler, config, sheets):
    """`hub:game` and `hub:games_play` are the same drawer under two names.

    Importing the workbook without canonicalising would create a second Games hub
    and split every game term between them.
    """
    canonical = {v for k, v in config.items() if k.startswith("ontology.hub.canonical.")}
    redirects = {
        k[len("ontology.hub.alias."):]: v
        for k, v in config.items()
        if k.startswith("ontology.hub.alias.")
        and not k.endswith((".normalization", ".prompt_policy"))
    }
    assert redirects, "no hub redirects are declared"
    for source, target in redirects.items():
        assert target in canonical, source
        assert target not in redirects, f"{source} redirects to another redirect"

    subject = sheets["terms"][0].index("subject_ID")
    family = sheets["terms"][0].index("family")
    authored = {
        row[subject] for row in sheets["terms"][1:]
        if len(row) > family and row[family] == "hub"
    }
    assert not (authored & set(redirects)), "the workbook still authors a legacy hub id"
    assert authored <= canonical


def test_the_packing_budget_is_arithmetically_consistent(compiler, config):
    """Otherwise the startup assertion the spec describes is decorative.

    `768` per item was not a worst-case bound and the reserve is now 1,280 with
    20% headroom, which is what limits a batch to two. If either number moves
    without the other, this is what says so.
    """
    reserve = int(config["llm.output.uncalibrated_item_reserve_tokens"])
    envelope = int(config["llm.output.envelope_token_reserve"])
    ceiling = int(config["llm.max_output_tokens"])
    headroom = float(config["llm.output.packing_headroom"])
    derived = int((ceiling - envelope) // (reserve * (1 + headroom)))
    assert int(config["llm.batch.calibrated_max_items"]) <= derived
    assert int(config["llm.batch.default_items"]) <= int(config["llm.batch.calibrated_max_items"])
    assert int(config["llm.batch.calibrated_max_items"]) <= int(config["llm.batch.max_items"])


def test_compilation_is_deterministic(compiler, sheets, schema):
    """The deploy validator recompiles and compares; that is worthless if the
    compiler is not a function of its inputs."""
    first = compiler.compile_contract(sheets, schema, "1970-01-01T00:00:00.000Z")
    second = compiler.compile_contract(sheets, schema, "2026-08-16T23:18:42.426Z")
    assert compiler.canonical(first) == compiler.canonical(second)
    assert first["generated_at"] != second["generated_at"]


def test_the_checked_in_contract_is_what_these_artifacts_compile_to(compiler, sheets, schema):
    """The contract is generated. If it is edited by hand, this fails."""
    existing = json.loads(compiler.CONTRACT.read_text())
    fresh = compiler.compile_contract(sheets, schema, existing["generated_at"])
    assert compiler.canonical(existing) == compiler.canonical(fresh)


def test_the_source_hashes_attest_to_the_files_actually_present(compiler):
    """The supplied contract claimed a schema hash matching no shipped file.

    Every enum agreed and every field was derivable, so nothing else caught it:
    the artifact was bound to a schema that was not in the drop. §22.4's deploy
    validator compares `schema_sha256`, so this would have failed at deploy with
    no explanation of which side moved.
    """
    contract = json.loads(compiler.CONTRACT.read_text())
    assert contract["source_hashes"]["workbook_sha256"] == compiler._sha256(compiler.WORKBOOK)
    assert contract["source_hashes"]["mention_schema_sha256"] == compiler._sha256(compiler.SCHEMA)


def test_every_predicate_has_a_schema_valid_fixture(compiler, schema):
    """The spec requires one fixture per predicate; twelve enum members with no
    exercised example is twelve untested branches."""
    predicates = schema["$defs"]["relation_hypothesis"]["properties"]["predicate"]["enum"]
    for predicate in predicates:
        response = {
            "schema_version": "mention_extract_v1",
            "items": [{
                "item_index": 0,
                "abstain": False,
                "abstain_reason": None,
                "mentions": [{
                    "surface": "FGO",
                    "source_field": "title",
                    "source_field_index": None,
                    "start": 0,
                    "end": 3,
                    "canonical_label_hypothesis": "Fate/Grand Order",
                    "family_hypothesis": "game",
                    "mention_role": "primary_subject",
                    "conversation_worthy": True,
                    "evidence_fields": ["title"],
                    "lookup_queries": ["Fate/Grand Order"],
                    "relation_hypotheses": [
                        {"predicate": predicate, "object_label_hypothesis": "Fate series"}
                    ],
                }],
            }],
        }
        jsonschema.validate(response, schema)


def test_every_stored_fewshot_is_a_valid_complete_response(compiler, config, schema):
    """A malformed few-shot teaches the model the malformed shape.

    The workbook's `examples` tab is a pipeline fixture format carrying resolved
    IDs and must never reach a prompt; only these registry entries may, and each
    has to validate as a complete outer response.
    """
    entries = {k: v for k, v in config.items()
               if k.startswith("prompt.fewshot.") and k.endswith(".output_json")}
    assert entries, "the few-shot registry is empty"
    for key, blob in entries.items():
        jsonschema.validate(json.loads(blob), schema)


def test_the_mandated_fewshot_mix_is_satisfiable(compiler, config):
    """`registry:` scopes the quota to the registry, not to one prompt.

    Worth pinning: read as a per-prompt rule it demands five examples against a
    four-example cap and would be unsatisfiable.
    """
    mix = config["prompt.fewshot.minimum_active_mix"]
    assert mix.startswith("registry:")
    required = 0
    for clause in mix[len("registry:"):].split(";"):
        if ">=" in clause:
            required = max(required, int(clause.split(">=")[1]))
    entries = [k for k in config if k.startswith("prompt.fewshot.") and k.endswith(".output_json")]
    assert len(entries) >= required
    assert int(config["runtime_pack.max_examples"]) >= 1


@pytest.mark.parametrize("key", [
    "llm.family.enum",
    "llm.mention_role.enum",
    "llm.predicate.enum",
    "llm.schema.abstain_reasons",
])
def test_drift_in_any_enum_is_refused(compiler, sheets, schema, key):
    """The compiler must fail loudly rather than pick a side.

    Silently preferring one artifact is how the two-places defect survives a
    parity check that exists to catch it.
    """
    mutated = copy.deepcopy(sheets)
    rows = mutated["runtime_config"]
    for row in rows:
        if row and row[0] == key:
            row[1] = row[1] + "|not_a_real_value"
            break
    else:  # pragma: no cover - guards the fixture, not the code
        pytest.fail(f"{key} is not in the workbook")
    with pytest.raises(compiler.ContractError):
        compiler.validate(mutated, schema)


def test_a_missing_config_key_is_refused_rather_than_defaulted(compiler):
    with pytest.raises(compiler.ContractError):
        compiler.require({}, "llm.model.default")


def test_the_database_gate_reports_rather_than_assumes(compiler):
    """It takes live values as an argument; supplying none is a problem, not a pass.

    `concept_kind_authority` is `live_pg_constraint`. A gate that fell back to a
    checked-in snapshot would turn that into a claim.
    """
    contract = json.loads(compiler.CONTRACT.read_text())
    assert contract["ontology_compiler"]["concept_kind_authority"] == "live_pg_constraint"
    assert compiler.check_database(contract, {}) != []

    live = {
        "concept_kind": ["hub", "topic", "genre", "work", "creator", "activity", "sport",
                         "event", "place", "culture", "language", "cuisine", "organization",
                         "medium", "affinity", "identity", "routine", "quantitative_feature"],
    }
    # Every family that stores a concept must land in the live allowlist.
    assert compiler.check_database(contract, live) == []

    narrowed = {"concept_kind": [k for k in live["concept_kind"] if k != "sport"]}
    assert any("sport" in problem for problem in compiler.check_database(contract, narrowed))


# ---------------------------------------------------------------------------
# The storage layer (`0203`).
# ---------------------------------------------------------------------------


#: The live `concept_kind` allowlist is the one input `check_database` demands;
#: every other check is opt-in, so a caller reading only some of the catalog gets
#: answers about what it read rather than false passes about what it did not.
LIVE_CONCEPT_KINDS = [
    "activity", "affinity", "creator", "cuisine", "culture", "event", "genre",
    "hub", "identity", "language", "medium", "organization", "place",
    "quantitative_feature", "routine", "sport", "topic", "work",
]


def live_with(**overrides):
    """A live-catalog reading that satisfies the mandatory check, plus one more."""
    return {"concept_kind": list(LIVE_CONCEPT_KINDS), **overrides}


def test_the_contracts_private_schema_is_this_databases_semantic_private(compiler):
    """`private` is a real schema here, and it is not the semantic one.

    It holds `push_config` and `collaborators` — the schema nothing is granted
    on. Resolving the contract's `private.*` there would put overlay state beside
    the push secret, so the crosswalk is explicit and only rewrites that one
    name.
    """
    assert compiler.STORAGE_SCHEMA_CROSSWALK == {"private": "semantic_private"}
    assert compiler.resolve_storage_object("private.review_items") == \
        "semantic_private.review_items"
    # Anything already naming its own schema passes through untouched.
    assert compiler.resolve_storage_object("ontology.release_manifests") == \
        "ontology.release_manifests"
    with pytest.raises(compiler.ContractError):
        compiler.resolve_storage_object("review_items")


def test_every_required_store_exists_under_the_name_this_database_uses(compiler):
    """The `storage_integration` gate's first half, both ways round."""
    contract = json.loads(compiler.CONTRACT.read_text())
    declared = contract["runtime_requirements"]["required_storage_objects"]
    assert len(declared) == 16

    present = [compiler.resolve_storage_object(name) for name in declared]
    assert compiler.check_database(contract, live_with(tables=present)) == []

    # Fourteen of the sixteen are in `semantic_private`; none may land in `private`.
    assert sum(name.startswith("semantic_private.") for name in present) == 14
    assert not any(name.startswith("private.") for name in present)

    missing_one = [n for n in present if not n.endswith(".review_exposures")]
    problems = compiler.check_database(contract, live_with(tables=missing_one))
    assert any("review_exposures" in problem for problem in problems)
    # The message must name the production table *and* what the contract called
    # it, or whoever reads the failure goes looking in the wrong schema.
    assert any("private.review_exposures" in problem for problem in problems)


def test_the_family_check_constraint_may_not_drift_from_the_family_map(compiler):
    """A closed vocabulary copied into a check constraint, verified against its source.

    The constraint is the only mechanism Postgres offers, so the copy is
    permitted — and it is made safe by being read back. Drift in either
    direction is a problem, because a constraint that permits a family nothing
    compiles is as wrong as one that refuses a family something does.
    """
    contract = json.loads(compiler.CONTRACT.read_text())
    families = sorted(contract["ontology_compiler"]["family_mappings"])
    assert len(families) == 23
    assert compiler.check_database(contract, live_with(provisional_family=families)) == []

    widened = families + ["telepathy"]
    assert any("telepathy" in p for p in compiler.check_database(
        contract, live_with(provisional_family=widened)))

    narrowed = [f for f in families if f != "anime"]
    assert any("anime" in p for p in compiler.check_database(
        contract, live_with(provisional_family=narrowed)))


def _required_keys(compiler):
    """Every `runtime_config` key the compiler insists on, read from its source.

    The source is scanned only to *enumerate* what to test; each key it yields is
    then removed from a real workbook and the compiler is watched refusing. That
    is the opposite of asserting on source text — the enumeration is what keeps
    this test honest as the compiler grows, since a newly required key joins the
    parametrisation without anyone remembering to add it.
    """
    import re

    source = pathlib.Path(compiler.__file__).read_text()
    keys = sorted(set(re.findall(r'require\(config, "([^"]+)"\)', source)))
    assert len(keys) >= 30, f"only {len(keys)} required keys found; the scan broke"
    return keys


def test_every_required_workbook_key_is_refused_when_removed(compiler, sheets, schema):
    """A missing key must stop the build, never fall back to a default.

    `semantic_gate_report_v1` is why this exists. It appeared in the compiled
    contract and in the specification and existed nowhere in the workbook, so the
    generated artifact was carrying a value that could not be derived from its
    stated source — and nothing said so, because the field was simply present.
    """
    generated = "2026-01-01T00:00:00.000Z"

    def build(source):
        """Validate then compile — the order `main()` uses.

        Running only `compile_contract` was the first version of this test and it
        reported two false survivors: `ontology.family.enum` and
        `llm.output.envelope_token_reserve` are demanded by `validate` and never
        read by the emitter, so removing them produced a contract while the real
        pipeline would already have stopped. A test of half the pipeline answers
        about half the pipeline.
        """
        compiler.validate(source, schema)
        return compiler.compile_contract(source, schema, generated)

    build(sheets)  # the intact baseline

    survived = []
    for key in _required_keys(compiler):
        wounded = copy.deepcopy(sheets)
        wounded["runtime_config"] = [
            row for row in wounded["runtime_config"] if not (row and row[0] == key)
        ]
        assert len(wounded["runtime_config"]) < len(sheets["runtime_config"]), key
        try:
            build(wounded)
        except Exception:
            continue
        survived.append(key)

    assert not survived, (
        "the compiler produced a contract without these keys, so their values "
        f"are being defaulted rather than derived: {survived}"
    )


def test_the_gate_report_version_is_one_of_them(compiler, sheets):
    """Named explicitly, because it is the key that was missing.

    A parametrised sweep proves the rule; this proves the instance, and would
    fail if the key were ever quietly reintroduced as a compiler literal.
    """
    config = compiler.config_of(sheets)
    assert config["deployment.report.schema_version"] == "semantic_gate_report_v1"
    assert "deployment.report.schema_version" in _required_keys(compiler)
