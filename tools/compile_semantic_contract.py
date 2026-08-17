#!/usr/bin/env python3
"""Compile the semantic contract, and refuse to if the artifacts disagree.

**What this is.** `semantic/ontology/terms.xlsx` is where the grammar, seed
vocabulary, aliases, fixtures and runtime configuration are *authored*.
`semantic/contracts/mention_extract_v1.schema.json` is the strict model-output
contract. Neither is what production reads. Production reads
`semantic/contracts/compiled_semantic_contract_v1.json`, and this file is the
only thing allowed to write it.

**Why a compiler rather than three files kept in step by hand.** This repository
has paid for the alternative three times. `SOURCE_ACTION_PAIRS` in Python and
`sources.action_weights` in SQL disagreed about `top_track` for months, and the
comment recording that defect sat directly above the identical bug for
`playlist_item`. `0191` published a genre mint and revoked every privilege on it,
so the migration's own header described behaviour the shipped code could not
perform. **One fact in two places is the recurring defect**, and the response is
to derive rather than duplicate.

**Determinism is the load-bearing property.** The deploy validator recompiles the
contract and compares canonical content after removing only `generated_at`. That
comparison is worthless unless the same inputs always produce the same bytes, so
every collection here is emitted in a defined order — workbook order where the
order carries meaning, sorted where it does not — and nothing reads the clock
except the one field that is excluded from the comparison.

    python3 tools/compile_semantic_contract.py --check        # verify, emit nothing
    python3 tools/compile_semantic_contract.py --emit         # rewrite the contract
    python3 tools/compile_semantic_contract.py --check-database --live-enums live.json

The database gate is separate and takes its live values as an argument; see
`check_database` for why it does not open a connection of its own.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys
from typing import Any

REPOSITORY = pathlib.Path(__file__).resolve().parent.parent
WORKBOOK = REPOSITORY / "semantic" / "ontology" / "terms.xlsx"
SCHEMA = REPOSITORY / "semantic" / "contracts" / "mention_extract_v1.schema.json"
CONTRACT = REPOSITORY / "semantic" / "contracts" / "compiled_semantic_contract_v1.json"

CONTRACT_VERSION = "compiled_semantic_contract_v1"

# **Families that describe evidence rather than vocabulary.** A video, an
# episode or a calendar event is a thing we observed, not a term anybody could
# be interested in, so none of them may map to a concept row. They are listed
# here because the coverage check demands that *every* family resolve exactly
# once, and "resolves to nothing, on purpose" is an answer that has to be
# written down to be distinguishable from an omission.
VIRTUAL_FAMILIES = frozenset({
    "video", "episode", "article", "observation",
    "calendar_event", "travel_itinerary", "event_occurrence", "user_profile",
})

# The five ontology families the model may never emit. Checked as an exact
# difference rather than a subset test: a family appearing on one side and not
# the other is a drift signal whichever direction it points.
MODEL_FORBIDDEN_FAMILIES = frozenset({
    "channel", "event_type", "game_category", "hub", "platform",
})


class ContractError(RuntimeError):
    """A refusal to compile. Never repaired automatically."""


def _sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _split(value: str, separator: str = "|") -> list[str]:
    return [part.strip() for part in str(value).split(separator) if part.strip()]


def load_workbook() -> dict[str, Any]:
    """Read the authoring workbook into plain Python.

    `openpyxl` is a dev dependency and deliberately not a runtime one: the
    worker consumes the compiled JSON and never opens a spreadsheet.
    """
    try:
        import openpyxl
    except ModuleNotFoundError as missing:  # pragma: no cover - environment
        raise ContractError(
            "openpyxl is required to compile the contract; it is in the dev extra"
        ) from missing

    book = openpyxl.load_workbook(WORKBOOK, read_only=True, data_only=True)
    sheets: dict[str, list[list[str]]] = {}
    for name in ("terms", "relations", "aliases", "grammar", "examples", "runtime_config"):
        if name not in book.sheetnames:
            raise ContractError(f"workbook is missing the {name!r} sheet")
        rows = [
            ["" if cell is None else str(cell).strip() for cell in row]
            for row in book[name].iter_rows(values_only=True)
        ]
        sheets[name] = [row for row in rows if any(row)]
    return sheets


def config_of(sheets: dict[str, Any]) -> dict[str, str]:
    rows = sheets["runtime_config"]
    return {row[0]: (row[1] if len(row) > 1 else "") for row in rows[1:] if row and row[0]}


def _column(sheet: list[list[str]], name: str) -> int:
    header = sheet[0]
    if name not in header:
        raise ContractError(f"expected a {name!r} column, found {header}")
    return header.index(name)


def require(config: dict[str, str], key: str) -> str:
    """A missing key is a compile failure, never a default.

    A default here would be the third instance of the defect this file exists to
    prevent: the compiler would quietly supply a value the workbook does not
    state, and the two would drift with nothing reporting it.
    """
    if key not in config or config[key] == "":
        raise ContractError(f"runtime_config is missing {key!r}")
    return config[key]


def model_predicates(sheets: dict[str, Any]) -> list[str]:
    """Predicates the grammar permits the model to propose, in grammar order.

    Order is the sheet's, not sorted, because `ontology_compiler.model_predicates`
    records *what the grammar says* and the grammar is an authored document whose
    row order a reviewer reads.
    """
    grammar = sheets["grammar"]
    predicate = _column(grammar, "predicate")
    propose = _column(grammar, "llm_may_propose")
    seen: list[str] = []
    for row in grammar[1:]:
        if len(row) > propose and row[propose].upper() == "T":
            key = row[predicate]
            if key and key not in seen:
                seen.append(key)
    return seen


def validate(sheets: dict[str, Any], schema: dict[str, Any]) -> None:
    """Every check that must hold before a contract may be written.

    Each raises rather than warns. A compiler that emits a contract while
    reporting a problem is a compiler whose output nobody reads.
    """
    config = config_of(sheets)
    mention = schema["$defs"]["mention"]["properties"]
    schema_enums = {
        "llm.family.enum": mention["family_hypothesis"]["enum"],
        "llm.mention_role.enum": mention["mention_role"]["enum"],
        "llm.predicate.enum":
            schema["$defs"]["relation_hypothesis"]["properties"]["predicate"]["enum"],
        "llm.schema.abstain_reasons":
            [v for v in schema["$defs"]["item"]["properties"]["abstain_reason"]["enum"] if v],
    }

    # 1. Enum parity, both directions. Sorted equality rather than a subset test:
    #    a value in the workbook and not the schema is as wrong as the reverse,
    #    and only one of those is visible from the model's side.
    for key, values in schema_enums.items():
        workbook_values = sorted(_split(require(config, key)))
        if workbook_values != sorted(values):
            only_workbook = sorted(set(workbook_values) - set(values))
            only_schema = sorted(set(values) - set(workbook_values))
            raise ContractError(
                f"{key} disagrees with the JSON Schema; "
                f"workbook-only={only_workbook} schema-only={only_schema}"
            )

    # 2. The grammar's propose flags are the same twelve predicates. This is the
    #    check that would have caught the prompt offering seven predicates while
    #    the schema allowed twelve, which silently made every sports roster
    #    relation unreachable.
    grammar_predicates = model_predicates(sheets)
    if sorted(grammar_predicates) != sorted(schema_enums["llm.predicate.enum"]):
        raise ContractError(
            "grammar llm_may_propose=T predicates disagree with the schema: "
            f"grammar={sorted(grammar_predicates)} "
            f"schema={sorted(schema_enums['llm.predicate.enum'])}"
        )

    # 3. A source profile may narrow the union; it may never widen it.
    union = set(schema_enums["llm.predicate.enum"])
    for key, value in config.items():
        if key.startswith("llm.predicate.profile."):
            extra = sorted(set(_split(value)) - union)
            if extra:
                raise ContractError(f"{key} proposes predicates outside the union: {extra}")

    # 4. Every family resolves exactly once, and virtual families resolve to
    #    nothing on purpose.
    mappings = {
        key[len("term_family.map."):]: value
        for key, value in config.items()
        if key.startswith("term_family.map.") and key != "term_family.map.version"
    }
    declared = set(_split(require(config, "ontology.family.enum")))
    term_families = {
        row[_column(sheets["terms"], "family")]
        for row in sheets["terms"][1:]
        if len(row) > _column(sheets["terms"], "family") and row[_column(sheets["terms"], "family")]
    }
    for family in sorted(term_families | declared):
        if family in VIRTUAL_FAMILIES:
            if family in mappings:
                raise ContractError(f"virtual family {family!r} must not map to storage")
            continue
        if family not in mappings:
            raise ContractError(f"family {family!r} has no term_family.map entry")
    unknown = sorted(set(mappings) - declared - VIRTUAL_FAMILIES)
    if unknown:
        raise ContractError(f"term_family.map covers families absent from the ontology: {unknown}")

    # 5. What the model may emit is a strict subset of what the ontology holds,
    #    and the difference is exactly the five it must never produce.
    model_families = set(schema_enums["llm.family.enum"])
    difference = declared - model_families
    if difference != set(MODEL_FORBIDDEN_FAMILIES):
        raise ContractError(
            "the families the model may not emit are not the expected five: "
            f"{sorted(difference)}"
        )
    if model_families - declared:
        raise ContractError(
            f"the model may emit families the ontology does not hold: "
            f"{sorted(model_families - declared)}"
        )

    # 6. Hub canonicalization: nothing legacy survives, and every canonical
    #    target is a production hub id rather than an authoring one.
    canonical = {
        key[len("ontology.hub.canonical."):]: value
        for key, value in config.items()
        if key.startswith("ontology.hub.canonical.")
    }
    redirects = {
        key[len("ontology.hub.alias."):]: value
        for key, value in config.items()
        if key.startswith("ontology.hub.alias.")
        and not key.endswith((".normalization", ".prompt_policy"))
    }
    for source, target in sorted(redirects.items()):
        if target not in set(canonical.values()):
            raise ContractError(f"hub redirect {source!r} points outside the canonical set")
        if target in redirects:
            raise ContractError(f"hub redirect {source!r} points at another redirect")
    hub_column = _column(sheets["terms"], "subject_ID")
    family_column = _column(sheets["terms"], "family")
    for row in sheets["terms"][1:]:
        if len(row) > family_column and row[family_column] == "hub":
            key = row[hub_column]
            if key in redirects:
                raise ContractError(
                    f"the workbook still authors the legacy hub {key!r}; "
                    f"use {redirects[key]!r}"
                )

    # 7. The packing formula must be arithmetically consistent with the values
    #    beside it, or the startup assertion it describes is decorative.
    reserve = int(require(config, "llm.output.uncalibrated_item_reserve_tokens"))
    envelope = int(require(config, "llm.output.envelope_token_reserve"))
    ceiling = int(require(config, "llm.max_output_tokens"))
    headroom = float(require(config, "llm.output.packing_headroom"))
    calibrated = int(require(config, "llm.batch.calibrated_max_items"))
    derived = int((ceiling - envelope) // (reserve * (1 + headroom)))
    if calibrated > derived:
        raise ContractError(
            f"calibrated_max_items={calibrated} exceeds the {derived} items the "
            f"budget permits ({ceiling}-{envelope})/({reserve}*{1 + headroom})"
        )
    if int(require(config, "llm.batch.default_items")) > calibrated:
        raise ContractError("default_batch_items exceeds calibrated_max_items")


def compile_contract(sheets: dict[str, Any], schema: dict[str, Any],
                     generated_at: str) -> dict[str, Any]:
    config = config_of(sheets)
    mention = schema["$defs"]["mention"]["properties"]

    return {
        "contract_version": CONTRACT_VERSION,
        "generated_at": generated_at,
        "source_hashes": {
            # Recomputed, never copied. A hash carried in the workbook would be a
            # claim about the workbook made by the workbook.
            "workbook_sha256": _sha256(WORKBOOK),
            "mention_schema_sha256": _sha256(SCHEMA),
        },
        "versions": {
            "term_family_map": require(config, "term_family.map.version"),
            "grammar": require(config, "grammar.version"),
            "prompt": require(config, "prompt.version"),
            "model_id": require(config, "llm.model.default"),
            "model_revision": require(config, "llm.model.revision"),
            "gateway_revision": require(config, "llm.gateway.revision"),
            # From the schema's own `$id`, so the contract cannot name a schema
            # other than the one it was compiled against.
            "output_schema": schema["$id"],
            "output_budget_policy": require(config, "llm.output.budget_policy.version"),
        },
        "output_contract": {
            # Schema order, not workbook order: the schema is the wire contract
            # and a reader comparing the two should see the same sequence.
            "families": list(mention["family_hypothesis"]["enum"]),
            "mention_roles": list(mention["mention_role"]["enum"]),
            "predicates": list(
                schema["$defs"]["relation_hypothesis"]["properties"]["predicate"]["enum"]
            ),
            "abstain_reasons": [
                value
                for value in schema["$defs"]["item"]["properties"]["abstain_reason"]["enum"]
                if value
            ],
            "max_items_wire": int(require(config, "llm.batch.max_items")),
            "default_batch_items": int(require(config, "llm.batch.default_items")),
            "calibrated_max_items": int(require(config, "llm.batch.calibrated_max_items")),
            "max_mentions_per_item": int(require(config, "llm.max_mentions_per_item")),
            "max_output_tokens": int(require(config, "llm.max_output_tokens")),
            "uncalibrated_item_reserve_tokens":
                int(require(config, "llm.output.uncalibrated_item_reserve_tokens")),
            "predictor_quantile": float(require(config, "llm.output.predictor.quantile")),
            "packing_headroom": float(require(config, "llm.output.packing_headroom")),
            "packing_formula": require(config, "llm.batch.output_budget_formula"),
            "tokenizer_manifest_sha256":
                require(config, "llm.output.tokenizer_manifest_sha256"),
            "stress_fixture_version": require(config, "llm.output.stress_fixture.version"),
            "output_budget_gate": require(config, "release.gate.output_budget"),
        },
        "ontology_compiler": {
            "concept_kind_authority": "live_pg_constraint",
            "concept_kind_target": "ontology.concept_revisions.concept_kind",
            # Sorted: a map has no meaningful order and sorting makes a diff
            # between two compilations readable.
            "family_mappings": {
                key[len("term_family.map."):]: value
                for key, value in sorted(config.items())
                if key.startswith("term_family.map.") and key != "term_family.map.version"
            },
            "hub_canonical": {
                key[len("ontology.hub.canonical."):]: value
                for key, value in config.items()
                if key.startswith("ontology.hub.canonical.")
            },
            "hub_redirects": {
                key[len("ontology.hub.alias."):]: value
                for key, value in config.items()
                if key.startswith("ontology.hub.alias.")
                and not key.endswith((".normalization", ".prompt_policy"))
            },
            "model_predicates": model_predicates(sheets),
        },
        "runtime_requirements": {
            "consumers": _split(require(config, "runtime.contract.required_consumers")),
            "jobs": _split(require(config, "job.pipeline"), ">"),
            "required_storage_objects": _split(require(config, "data.table.minimum")),
            "initial_mode": require(config, "deployment.initial_mode"),
            "qwen_overlay": require(config, "deployment.feature.semantic_qwen_overlay"),
            "deployment_gates": _split(require(config, "validation.deploy_scope"), "+"),
            "gate_report_schema_version": require(config, "deployment.report.schema_version"),
            "report_test_result_policy": require(config, "deployment.report.test_result_policy"),
            "release_attestation_fields":
                _split(require(config, "deployment.attestation.required_fields")),
            "retrieval_policy": {
                "max_prompt_examples": int(require(config, "runtime_pack.max_examples")),
                "term_cluster_cap": require(config, "runtime_pack.term_cluster_cap"),
                "prompt_registry_mix": require(config, "prompt.fewshot.minimum_active_mix"),
            },
        },
    }


def canonical(contract: dict[str, Any]) -> str:
    """The form the deploy validator compares: everything but `generated_at`."""
    without_timestamp = {k: v for k, v in contract.items() if k != "generated_at"}
    return json.dumps(without_timestamp, indent=2, ensure_ascii=False, sort_keys=False)


#: **`private` in the contract is `semantic_private` in this database.**
#:
#: The contract names its stores `private.review_items` and so on. `private` is a
#: real schema here and holds `push_config` and `collaborators` — the schema
#: nothing is granted on, where the push secret lives — so the contract's name and
#: the production name genuinely differ. It is the same class of crosswalk as
#: `hub:game` meaning `hub:games_play`, and it is written down for the same
#: reason: a compiler that resolved it quietly would be one nobody could audit,
#: and the failure it would hide is a semantic table created next to a secret.
STORAGE_SCHEMA_CROSSWALK = {"private": "semantic_private"}


def resolve_storage_object(declared: str) -> str:
    """Map a contract storage name onto the schema this database actually uses."""
    schema, _, table = declared.partition(".")
    if not table:
        raise ContractError(f"storage object {declared!r} names no schema")
    return f"{STORAGE_SCHEMA_CROSSWALK.get(schema, schema)}.{table}"


def check_database(contract: dict[str, Any], live: dict[str, Any]) -> list[str]:
    """The live-database gate, against values a caller supplies.

    **It takes the live enums as an argument instead of opening a connection**,
    and that is a decision rather than a shortcut. The credential that can read
    `pg_constraint` is not one this repository holds, and a compiler that
    silently falls back to a checked-in snapshot would make
    `concept_kind_authority: live_pg_constraint` a claim rather than a fact.
    Whatever holds the credential reads the constraint and passes it in; this
    checks the contract against it and says which side is wrong.

    The caller must select **only a positive, single-column `ANY(ARRAY[…])`
    allowlist** on the target column. Three constraints in this schema mention
    `concept_kind`, and `booked_activity_candidates_target_binding_v03_check` is
    a compound condition that would yield a wrong, shorter list.
    """
    problems: list[str] = []
    kinds = set(live.get("concept_kind") or [])
    if not kinds:
        problems.append("no live concept_kind allowlist supplied")

    for family, mapping in contract["ontology_compiler"]["family_mappings"].items():
        parts = dict(
            piece.split("=", 1) for piece in mapping.split(";") if "=" in piece
        )
        kind = parts.get("concept_kind")
        if parts.get("storage") != "concepts":
            continue
        if kind and kind not in kinds:
            problems.append(
                f"family {family!r} compiles to concept_kind={kind!r}, "
                f"which the live constraint does not permit"
            )

    jobs = set(live.get("job_type") or [])
    if jobs:
        missing = [j for j in contract["runtime_requirements"]["jobs"] if j not in jobs]
        if missing:
            problems.append(
                "the live worker_jobs allowlist does not yet permit: " + ", ".join(missing)
            )

    hubs = set(live.get("hubs") or [])
    if hubs:
        for role, hub in contract["ontology_compiler"]["hub_canonical"].items():
            if hub not in hubs:
                problems.append(f"canonical hub {hub!r} for role {role!r} is not in the ontology")
        for legacy in contract["ontology_compiler"]["hub_redirects"]:
            if legacy in hubs:
                problems.append(f"legacy hub {legacy!r} exists in the ontology and must be merged")

    # The `storage_integration` gate's first half: the sixteen stores exist,
    # under the names this database uses rather than the ones the contract does.
    tables = set(live.get("tables") or [])
    if tables:
        for declared in contract["runtime_requirements"]["required_storage_objects"]:
            actual = resolve_storage_object(declared)
            if actual not in tables:
                note = "" if actual == declared else f" (declared as {declared})"
                problems.append(f"required storage object {actual} does not exist{note}")

    # **A check constraint restating a closed vocabulary is a second copy of it**,
    # and this repository's recurring defect is one fact in two places. The copy
    # in `semantic_private.provisional_entities.family` is permitted because the
    # database has no other mechanism — and it is made safe here, by reading it
    # back and refusing to agree that the contract compiles if the two have
    # drifted. The contract is the authority; the constraint is its enforcement.
    stored_families = set(live.get("provisional_family") or [])
    if stored_families:
        declared_families = set(contract["ontology_compiler"]["family_mappings"])
        for extra in sorted(stored_families - declared_families):
            problems.append(
                f"provisional_entities.family permits {extra!r}, which no family mapping declares"
            )
        for absent in sorted(declared_families - stored_families):
            problems.append(
                f"family {absent!r} is declared but provisional_entities.family refuses it"
            )
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--emit", action="store_true", help="rewrite the compiled contract")
    parser.add_argument("--check", action="store_true",
                        help="validate and compare against the checked-in contract")
    parser.add_argument("--check-database", action="store_true",
                        help="validate the contract against live enums")
    parser.add_argument("--live-enums",
                        help="JSON with concept_kind[], job_type[] and hubs[] read from the "
                             "live database by whatever holds the credential")
    arguments = parser.parse_args()

    sheets = load_workbook()
    schema = json.loads(SCHEMA.read_text())

    try:
        validate(sheets, schema)
    except ContractError as refusal:
        print(f"contract refused: {refusal}", file=sys.stderr)
        return 1
    print("artifact parity: workbook, schema and grammar agree", file=sys.stderr)

    if arguments.check_database:
        if not arguments.live_enums:
            print("--check-database requires --live-enums", file=sys.stderr)
            return 2
        existing = json.loads(CONTRACT.read_text())
        problems = check_database(existing, json.loads(pathlib.Path(arguments.live_enums).read_text()))
        for problem in problems:
            print(f"  live database: {problem}", file=sys.stderr)
        print(f"live database: {len(problems)} problem(s)", file=sys.stderr)
        return 1 if problems else 0

    from datetime import datetime, timezone
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + \
        f"{datetime.now(timezone.utc).microsecond // 1000:03d}Z"
    contract = compile_contract(sheets, schema, stamp)

    if arguments.emit:
        CONTRACT.write_text(json.dumps(contract, indent=2, ensure_ascii=False) + "\n")
        print(f"wrote {CONTRACT.relative_to(REPOSITORY)}", file=sys.stderr)
        return 0

    if arguments.check:
        existing = json.loads(CONTRACT.read_text())
        if canonical(existing) != canonical(contract):
            print("the checked-in contract is not what these artifacts compile to",
                  file=sys.stderr)
            return 1
        print("compiled contract matches the checked-in artifact", file=sys.stderr)
        return 0

    json.dump(contract, sys.stdout, indent=2, ensure_ascii=False)
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
