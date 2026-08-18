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
import re

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
def schema_path(compiler, sheets):
    """The schema the workbook names, not one this file picks.

    Reading it through `output_schema_path` is what keeps these tests pointed at
    whatever is authoritative: before `0234`'s compiler change the path was a
    module constant and a test could pass against a schema the contract did not
    use.
    """
    return compiler.output_schema_path(compiler.config_of(sheets))


@pytest.fixture(scope="module")
def schema(schema_path):
    return json.loads(schema_path.read_text())


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
        "llm.schema.abstain_reasons":
            [v for v in schema["$defs"]["item"]["properties"]["abstain_reason"]["enum"] if v],
    }
    # Only if the schema declares relations. `mention_extract_v2` does not, and
    # the predicate vocabulary is checked against the grammar instead — see
    # `test_the_grammar_and_the_workbook_permit_the_same_predicates`.
    relations = schema["$defs"].get("relation_hypothesis")
    if relations is not None:
        expected["llm.predicate.enum"] = relations["properties"]["predicate"]["enum"]

    for key, values in expected.items():
        assert sorted(compiler._split(config[key])) == sorted(values), key
    assert len(expected["llm.family.enum"]) == 17
    assert len(expected["llm.mention_role.enum"]) == 15
    assert len(expected["llm.schema.abstain_reasons"]) == 5


def test_the_grammar_and_the_workbook_permit_the_same_predicates(compiler, sheets, config):
    """The check that caught the prompt offering seven where twelve were legal.

    It used to compare the grammar against the schema. `mention_extract_v2`
    carries no relations at all, so the schema has nothing to say here and the
    workbook's own `llm.predicate.enum` is the other side — which is where the
    vocabulary lived all along. The defect this guards against is unchanged: a
    predicate the grammar permits and nothing else knows about is a relation that
    can never be produced.
    """
    permitted = compiler.model_predicates(sheets)
    declared = compiler._split(config["llm.predicate.enum"])
    assert sorted(permitted) == sorted(declared)


def test_a_source_profile_may_narrow_but_never_widen(compiler, sheets, config):
    union = set(compiler.model_predicates(sheets))
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


def test_compilation_is_deterministic(compiler, schema_path, sheets, schema):
    """The deploy validator recompiles and compares; that is worthless if the
    compiler is not a function of its inputs."""
    first = compiler.compile_contract(sheets, schema, schema_path, "1970-01-01T00:00:00.000Z")
    second = compiler.compile_contract(sheets, schema, schema_path, "2026-08-16T23:18:42.426Z")
    assert compiler.canonical(first) == compiler.canonical(second)
    assert first["generated_at"] != second["generated_at"]


def test_the_checked_in_contract_is_what_these_artifacts_compile_to(compiler, schema_path, sheets, schema):
    """The contract is generated. If it is edited by hand, this fails."""
    existing = json.loads(compiler.CONTRACT.read_text())
    fresh = compiler.compile_contract(sheets, schema, schema_path, existing["generated_at"])
    assert compiler.canonical(existing) == compiler.canonical(fresh)


def test_the_source_hashes_attest_to_the_files_actually_present(compiler, schema_path):
    """The supplied contract claimed a schema hash matching no shipped file.

    Every enum agreed and every field was derivable, so nothing else caught it:
    the artifact was bound to a schema that was not in the drop. §22.4's deploy
    validator compares `schema_sha256`, so this would have failed at deploy with
    no explanation of which side moved.
    """
    contract = json.loads(compiler.CONTRACT.read_text())
    assert contract["source_hashes"]["workbook_sha256"] == compiler._sha256(compiler.WORKBOOK)
    assert contract["source_hashes"]["mention_schema_sha256"] == compiler._sha256(schema_path)


def test_a_relation_cannot_be_smuggled_into_an_extraction_response(compiler, schema):
    """The successor to one-fixture-per-predicate, and it asserts more.

    That test built a response carrying a `relation_hypotheses` array and
    validated it once per predicate — twelve enum members with no exercised
    example being twelve untested branches. `mention_extract_v2` emits no
    relations at all, so the honest question changed: not *is each predicate
    reachable* but *is any of them reachable*. `additionalProperties: false` is
    what makes the answer no, and it is worth pinning, because a schema that
    merely omitted the `$def` while tolerating extra keys would let a model send
    relations that nothing validates and nothing reads.
    """
    if "relation_hypothesis" in schema["$defs"]:
        pytest.skip("this schema declares relations; the older fixture test applies")

    smuggled = {
        "schema_version": schema["properties"]["schema_version"]["const"],
        "items": [{
            "item_index": 0,
            "status": "extracted",
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
                "relation_hypotheses": [
                    {"predicate": "part_of_franchise",
                     "object_label_hypothesis": "Fate series"}
                ],
            }],
        }],
    }
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(smuggled, schema)

    # And the same response without the smuggled key is legal, so the refusal
    # above is about the relation rather than about the rest of the shape.
    smuggled["items"][0]["mentions"][0].pop("relation_hypotheses")
    jsonschema.validate(smuggled, schema)


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

    live = live_with()
    # Every family that stores a concept must land in the live allowlist.
    assert compiler.check_database(contract, live) == []

    narrowed = live_with(concept_kind=[k for k in live["concept_kind"] if k != "sport"])
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


#: A snapshot must say which database it came from, or it is indistinguishable
#: from a hand-written array — which is the whole objection `read_live_catalog.py`
#: answers. Tests supply a synthetic one so they exercise the checks they are
#: about rather than this one; `test_a_snapshot_without_provenance_is_refused`
#: is where its absence is asserted.
LIVE_PROVENANCE = {
    "database_fingerprint_sha256": "0" * 64,
    "constraint_oids": {"concept_kind": "1", "job_type": "2", "provisional_family": "3"},
    "database": "postgres",
    "server_version": "17.6",
    "environment": "test",
}


def live_with(**overrides):
    """A live-catalog reading that satisfies the mandatory checks, plus one more."""
    return {
        "concept_kind": list(LIVE_CONCEPT_KINDS),
        "provenance": dict(LIVE_PROVENANCE),
        **overrides,
    }


def test_a_snapshot_without_provenance_is_refused(compiler):
    """The gate takes its values as an argument, so it must know where they came from.

    Taking them as an argument was deliberate — a compiler falling back to a
    checked-in snapshot would make `concept_kind_authority: live_pg_constraint`
    a fiction. But an argument nobody has to justify is one anybody can type, and
    a typed array passes exactly as well as a reading.
    """
    contract = json.loads(compiler.CONTRACT.read_text())
    bare = {"concept_kind": list(LIVE_CONCEPT_KINDS)}
    problems = compiler.check_database(contract, bare)
    assert any("database_fingerprint_sha256" in p for p in problems)
    assert any("constraint_oids" in p for p in problems)
    # And with provenance the same values pass.
    assert compiler.check_database(contract, live_with()) == []


def test_the_contract_carries_both_storage_names(compiler):
    """A consumer must be able to read the production name without deriving it."""
    contract = json.loads(compiler.CONTRACT.read_text())
    crosswalk = contract["runtime_requirements"]["storage_crosswalk"]
    assert crosswalk["schema_map"] == {"private": "semantic_private"}

    declared = contract["runtime_requirements"]["required_storage_objects"]
    objects = crosswalk["objects"]
    assert [o["declared_name"] for o in objects] == declared
    for entry in objects:
        assert entry["production_name"] == \
            compiler.resolve_storage_object(entry["declared_name"])
        assert not entry["production_name"].startswith("private.")
    assert sum(o["production_name"].startswith("semantic_private.") for o in objects) == 14


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


def test_every_required_workbook_key_is_refused_when_removed(compiler, schema_path, sheets, schema):
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

        `llm.output.schema_version` was the third, and it arrived the moment the
        schema stopped being a module constant: `main()` resolves the path from
        that key before anything else runs, so a harness given a path resolved
        outside cannot notice the key is gone. Resolving it here from the same
        sheets is what keeps this test about the whole pipeline — and
        `envelope_token_reserve` is no longer a survivor because the emitter now
        publishes it.

        The five `llm.input.max_*` bounds were the next batch, and they arrived
        the same way: the request schema is validated against them only when one
        is supplied, and a harness that supplied none could not notice they were
        gone. Resolving it here from the same sheets is the same repair.
        """
        config = compiler.config_of(source)
        path = compiler.output_schema_path(config)
        request = json.loads(compiler.request_schema_path(config).read_text())
        compiler.validate(source, schema, request)
        return compiler.compile_contract(source, schema, path, generated)

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


#: The objects that genuinely live in the physical `private` schema. It is the
#: schema nothing is granted on — `push_config` holds the APNs shared secret and
#: `collaborators` decides whose data may train a model — and the reference
#: chain this project adapts puts *its* semantic objects there too. Everything
#: semantic goes to `semantic_private` instead, and this list is what makes a
#: fourteenth name a decision rather than a typo.
PHYSICAL_PRIVATE_OBJECTS = frozenset({
    "notify", "push_config", "collaborators",
    "is_blocked", "may_see_match", "gender_key", "phone_digits",
    "open_match_authorization", "revoke_match_authorization_on_block",
    "revoke_likes_on_block", "refuse_blocked_message", "refuse_blocked_like",
    "enqueue_recompute_on_revision_move",
})

PRIVATE_REFERENCE = re.compile(r"(?<![a-z_])private\.([a-z_][a-z0-9_]*)")


def _executable(sql: str) -> str:
    """The statements, with line comments removed.

    **The distinction is the whole rule.** `0203`'s header explains at length
    that the contract's `private.review_items` means `semantic_private.review_items`
    here, and quotes both — in a comment. A scan that could not tell a comment
    from a statement would either refuse that explanation or, tuned the other
    way, permit a real `create table private.review_items`. A `--` inside a
    string literal is not a comment, so quotes are counted before truncating.
    """
    kept = []
    for line in sql.splitlines():
        marker = line.find("--")
        while marker != -1 and line.count("'", 0, marker) % 2 == 1:
            marker = line.find("--", marker + 2)
        kept.append(line if marker == -1 else line[:marker])
    return "\n".join(kept)


def test_no_migration_creates_a_semantic_object_in_the_physical_private_schema():
    """`private` is not `semantic_private`, and the hazard is the grant.

    The reference chain grants `service_role` broad access to everything in its
    `private`; here that would widen access to the push secret and the
    collaborator list. A bare `private.` grep cannot enforce this — every
    `semantic_private.` reference contains the substring, and thirteen genuine
    objects do live there — so this asks for names instead.
    """
    import re as _re  # local alias so the module-level import stays with its use

    directory = pathlib.Path(REPOSITORY) / "supabase" / "migrations"
    unexpected: dict[str, set[str]] = {}
    seen: set[str] = set()

    for path in sorted(directory.glob("*.sql")):
        for name in PRIVATE_REFERENCE.findall(_executable(path.read_text())):
            seen.add(name)
            if name not in PHYSICAL_PRIVATE_OBJECTS:
                unexpected.setdefault(path.name, set()).add(name)

    assert not unexpected, (
        "these migrations name an object in the physical `private` schema that is "
        "not one of the thirteen that belong there — if it is semantic, it goes in "
        f"`semantic_private`: { {k: sorted(v) for k, v in unexpected.items()} }"
    )
    # The scan must be finding the real ones, or a pass means only that the
    # regex stopped matching.
    assert len(seen) >= 10, f"only {len(seen)} private.* objects found; the scan broke"


def test_the_private_scan_reads_statements_and_not_comments():
    """Both directions, since this passes over the tree on its first run."""
    commented = "-- the contract calls it private.review_items, which here means\n" \
                "create table semantic_private.review_items (id uuid);\n"
    assert PRIVATE_REFERENCE.findall(_executable(commented)) == []

    executable = "create table private.review_items (id uuid);\n"
    assert PRIVATE_REFERENCE.findall(_executable(executable)) == ["review_items"]

    # `semantic_private.` contains the substring and must never match.
    assert PRIVATE_REFERENCE.findall("select * from semantic_private.observations") == []

    # A `--` inside a literal does not start a comment.
    literal = "select 'a -- b', private.push_config;\n"
    assert PRIVATE_REFERENCE.findall(_executable(literal)) == ["push_config"]


def test_unregistered_jobs_are_pending_while_the_overlay_is_off_and_failing_once_it_is_on(compiler):
    """The one check that measures a future state, in both of its two states.

    Eight of the nine pipeline jobs are unbuilt, and registering a `job_type`
    before its handler ships is actively worse than leaving it out — the job is
    claimed, found to have no handler, and marked `dead` with no retry. So their
    absence is *pending* while the mode is `off`, and a release blocker the
    moment the model may actually be called.
    """
    contract = json.loads(compiler.CONTRACT.read_text())
    assert compiler.overlay_disabled(contract)

    live = live_with(job_type=["recompute_user"])
    pending: list[str] = []
    problems = compiler.check_database(contract, live, pending)
    assert problems == []
    assert any("extract_mentions" in note for note in pending)

    switched_on = copy.deepcopy(contract)
    switched_on["runtime_requirements"]["qwen_overlay"] = "shadow"
    assert not compiler.overlay_disabled(switched_on)
    problems = compiler.check_database(switched_on, live)
    assert any("extract_mentions" in problem for problem in problems)

    # And a fully registered allowlist is clean under either setting.
    complete = live_with(job_type=contract["runtime_requirements"]["jobs"])
    assert compiler.check_database(contract, complete) == []
    assert compiler.check_database(switched_on, complete) == []


def test_the_schema_is_chosen_by_the_workbook(compiler, sheets, schema_path):
    """`llm.output.schema_version` names the file, and nothing else does.

    It was a module constant, so evaluating a new output contract meant editing
    the compiler while the workbook already carried the version it claimed to be
    authoritative — one fact in two places with the code winning. Naming a schema
    and compiling against it are now the same act.
    """
    version = compiler.require(compiler.config_of(sheets), "llm.output.schema_version")
    assert schema_path.name == f"{version}.schema.json"
    assert schema_path.parent == compiler.SCHEMA_DIR


def test_a_schema_version_with_no_file_is_refused_by_name(compiler, sheets):
    """The refusal says which name failed.

    The likely cause is a version named before its schema was written, and an
    `OSError` on a path the author never typed is a worse thing to read than the
    value they did.
    """
    wounded = copy.deepcopy(sheets)
    for row in wounded["runtime_config"]:
        if row and row[0] == "llm.output.schema_version":
            row[1] = "mention_extract_v99"
    with pytest.raises(compiler.ContractError) as refusal:
        compiler.output_schema_path(compiler.config_of(wounded))
    assert "mention_extract_v99" in str(refusal.value)


def test_the_contract_publishes_the_envelope_reserve(compiler, sheets):
    """Demanded by `validate` since it was written, and never emitted.

    `output_budget_report.py` could not read it and hard-coded 512 twice
    instead — once as `int(...) and 512`, which reads like a derivation of the
    contract value and is a constant. A limit the contract requires and does not
    publish is a limit every reader copies.
    """
    contract = json.loads(compiler.CONTRACT.read_text())
    published = contract["output_contract"]["envelope_token_reserve"]
    authored = int(compiler.require(
        compiler.config_of(sheets), "llm.output.envelope_token_reserve"))
    assert published == authored


def test_predicates_are_not_read_from_a_schema_that_emits_none(compiler, sheets, schema):
    """A relation vocabulary is not an extraction fact.

    `mention_extract_v2` carries no `relation_hypothesis`, so reading the
    predicate list off the schema reads a `$def` that is not there. The grammar
    sheet is the authority either way, and `output_contract.predicates` says what
    the model may emit — which for a schema without relations is nothing.
    """
    relationless = copy.deepcopy(schema)
    relationless["$defs"].pop("relation_hypothesis", None)

    # It validates rather than raising: a schema that declares no relations is
    # not drift, it is a schema with a smaller wire contract. The old code
    # raised `KeyError` here on a `$def` that was simply absent.
    compiler.validate(sheets, relationless)

    compiled = compiler.compile_contract(
        sheets, relationless, compiler.CONTRACT, "1970-01-01T00:00:00.000Z")
    assert compiled["output_contract"]["predicates"] == []
    assert compiled["ontology_compiler"]["model_predicates"] == compiler.model_predicates(sheets)
