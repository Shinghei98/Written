"""The one runtime reader of `compiled_semantic_contract_v1.json`.

**Until now nothing read it.** `tools/compile_semantic_contract.py` wrote the
contract and the tests checked it, and that was the whole of its life — an
artifact verified against its sources and consumed by nobody, while the
behaviour it describes lived in Python constants and SQL check constraints. That
is the arrangement the compiler was built to end, one layer up: *one fact in two
places is the recurring defect*, and a contract nothing consumes is the second
place rather than the first.

This module is the consumer. Everything the pipeline needs to know about
families, roles, predicates, hubs and storage names comes from here, and here
reads the compiled artifact.

## What it refuses

**A missing contract is a failure, never a default.** A pipeline that fell back
to hardcoded families when the JSON was absent would run, produce plausible
output, and diverge from the artifact the deploy attested to — which is exactly
the failure the attestation exists to catch, arriving in the one form the
attestation cannot see.

**A contract whose declared hashes are absent is refused too.** `source_hashes`
is how a running Lambda can say which workbook and schema its behaviour came
from, and a contract without them cannot answer the only question an incident
asks.

## Where it reads from

`aws/worker/build.sh` stages the JSON into the package directory at build time,
so the deployed Lambda finds it beside this file. It is **not** checked in there
— the repository has exactly one copy, under `semantic/contracts/`, and a second
committed copy would be the duplication this whole apparatus exists to prevent.
Outside a Lambda the repository path is used, so tests and the CLI read the same
bytes the bundle will carry.
"""

from __future__ import annotations

import functools
import hashlib
import json
import os
import pathlib
from typing import Any

CONTRACT_FILENAME = "compiled_semantic_contract_v1.json"

#: Beside this module first — that is where `build.sh` stages it, so a deployed
#: Lambda never depends on a repository layout it does not have.
_BUNDLED = pathlib.Path(__file__).resolve().parent / CONTRACT_FILENAME

#: …then the repository, for tests, the CLI and local runs. `parents[2]` is
#: `semantic/`: this file is `semantic/src/written_ontology/…`.
_REPOSITORY = (
    pathlib.Path(__file__).resolve().parents[2] / "contracts" / CONTRACT_FILENAME
)


class ContractUnavailable(RuntimeError):
    """The compiled contract is missing or unusable. Never repaired silently."""


def contract_path() -> pathlib.Path:
    """Where the contract is being read from.

    `WRITTEN_SEMANTIC_CONTRACT` overrides both, which exists for the staging
    lane: a canary needs to run a candidate contract without rebuilding, and a
    deploy validator needs to point this at the artifact it is validating.
    """
    override = os.environ.get("WRITTEN_SEMANTIC_CONTRACT")
    if override:
        path = pathlib.Path(override)
        if not path.is_file():
            raise ContractUnavailable(
                f"WRITTEN_SEMANTIC_CONTRACT points at {override!r}, which is not a file"
            )
        return path
    for candidate in (_BUNDLED, _REPOSITORY):
        if candidate.is_file():
            return candidate
    raise ContractUnavailable(
        f"{CONTRACT_FILENAME} is not beside this module or in the repository. "
        "aws/worker/build.sh stages it; a bundle without it must not run."
    )


@functools.lru_cache(maxsize=1)
def load() -> "SemanticContract":
    return SemanticContract(contract_path())


#: The four modes, mirrored from `tools/compile_semantic_contract.py`. Mirrored
#: rather than imported because this module ships inside the Lambda bundle and
#: the compiler does not; a test asserts the two lists agree, so a drift fails
#: rather than diverges.
MODEL_LANE_MODES = ("off", "evaluation", "shadow", "active")
MODES_CALLING_MODEL = ("evaluation", "shadow", "active")
MODES_WRITING_CANDIDATES = ("shadow", "active")


class SemanticContract:
    """The compiled contract, read once and answered from."""

    def __init__(self, path: pathlib.Path) -> None:
        self._schema: dict | None = None
        self.path = path
        raw = path.read_bytes()
        try:
            self.data: dict[str, Any] = json.loads(raw)
        except json.JSONDecodeError as broken:
            raise ContractUnavailable(f"{path} is not valid JSON") from broken

        version = self.data.get("contract_version")
        if version != "compiled_semantic_contract_v1":
            raise ContractUnavailable(
                f"{path} declares contract_version {version!r}, which this reader "
                "does not implement"
            )
        hashes = self.data.get("source_hashes") or {}
        for field in ("workbook_sha256", "mention_schema_sha256"):
            if not hashes.get(field):
                raise ContractUnavailable(f"{path} carries no {field}")

        #: The digest of the artifact itself, which is what a release manifest
        #: records and what a running invocation can be asked for. Computed here
        #: rather than read from the file: a contract cannot state its own hash.
        self.contract_sha256 = hashlib.sha256(raw).hexdigest()

    # -- identity -----------------------------------------------------------

    @property
    def source_hashes(self) -> dict[str, str]:
        return dict(self.data["source_hashes"])

    @property
    def versions(self) -> dict[str, str]:
        return dict(self.data["versions"])

    def attestation(self) -> dict[str, str]:
        """What a run should record about the contract it obeyed."""
        return {
            "compiled_contract_sha256": self.contract_sha256,
            "workbook_sha256": self.source_hashes["workbook_sha256"],
            "schema_sha256": self.source_hashes["mention_schema_sha256"],
            "grammar_version": self.versions["grammar"],
            "prompt_version": self.versions["prompt"],
            "model_id": self.versions["model_id"],
            "model_revision": self.versions["model_revision"],
            "gateway_revision": self.versions["gateway_revision"],
            # **The mode belongs in the attestation**, because it is the one
            # fact that decides whether a run was permitted to write anything
            # about a person. A release manifest recording model and gateway but
            # not the lane it ran in cannot answer that afterwards.
            "model_lane_mode": self.model_lane_mode,
        }

    # -- the model's output vocabulary --------------------------------------

    @property
    def families(self) -> tuple[str, ...]:
        """The 18 families a model may propose — *not* the ontology's 23."""
        return tuple(self.data["output_contract"]["families"])

    @property
    def mention_roles(self) -> tuple[str, ...]:
        return tuple(self.data["output_contract"]["mention_roles"])

    @property
    def predicates(self) -> tuple[str, ...]:
        return tuple(self.data["output_contract"]["predicates"])

    @property
    def abstain_reasons(self) -> tuple[str, ...]:
        return tuple(self.data["output_contract"]["abstain_reasons"])

    # -- compiling a family into storage ------------------------------------

    @property
    def ontology_families(self) -> tuple[str, ...]:
        """All 23, including the five the model may never emit."""
        return tuple(sorted(self.data["ontology_compiler"]["family_mappings"]))

    def storage_for(self, family: str) -> dict[str, str]:
        """Where a family is stored and as what.

        Returns the parsed mapping — `storage`, `concept_kind` and any metadata
        pin. **An unknown family raises**: writing a concept whose kind the check
        constraint will reject, at the end of a pipeline, for one term, is the
        failure this refuses to walk into.
        """
        mappings = self.data["ontology_compiler"]["family_mappings"]
        if family not in mappings:
            raise ContractUnavailable(
                f"family {family!r} has no storage mapping; the contract declares "
                f"{len(mappings)}"
            )
        parsed: dict[str, str] = {}
        for piece in mappings[family].split(";"):
            if "=" in piece:
                key, _, value = piece.partition("=")
                parsed[key.strip()] = value.strip()
        return parsed

    def concept_kind_for(self, family: str) -> str | None:
        """The `concept_kind` a family compiles to, or None if it is not a concept."""
        parsed = self.storage_for(family)
        if parsed.get("storage") != "concepts":
            return None
        kind = parsed.get("concept_kind")
        return None if kind in (None, "NA") else kind

    # -- hubs ---------------------------------------------------------------

    def canonical_hub(self, role_or_key: str) -> str:
        """Resolve a hub role or a legacy id to the production concept key.

        `hub:game` and `hub:games_play` are the same drawer under two names, and
        importing without canonicalising would create a second Games hub and
        split every game term between them.
        """
        compiler = self.data["ontology_compiler"]
        redirects = compiler["hub_redirects"]
        if role_or_key in redirects:
            return redirects[role_or_key]
        canonical = compiler["hub_canonical"]
        if role_or_key in canonical:
            return canonical[role_or_key]
        if role_or_key in set(canonical.values()):
            return role_or_key
        raise ContractUnavailable(f"{role_or_key!r} is not a hub role, id or alias")

    # -- storage names ------------------------------------------------------

    def production_table(self, declared: str) -> str:
        """The contract's `private.*` name resolved to this database's schema.

        `private` is a real schema here and holds the push secret; the semantic
        objects are in `semantic_private`. The compiler emits both names for
        exactly this call, so no consumer has to know the mapping.
        """
        crosswalk = self.data["runtime_requirements"].get("storage_crosswalk")
        if not crosswalk:
            raise ContractUnavailable(
                "this contract carries no storage_crosswalk; recompile it"
            )
        for entry in crosswalk["objects"]:
            if entry["declared_name"] == declared:
                return entry["production_name"]
        raise ContractUnavailable(f"{declared!r} is not a declared storage object")

    @property
    def required_tables(self) -> tuple[str, ...]:
        """Every store, under the name this database uses."""
        crosswalk = self.data["runtime_requirements"]["storage_crosswalk"]
        return tuple(entry["production_name"] for entry in crosswalk["objects"])

    # -- the pipeline -------------------------------------------------------

    @property
    def jobs(self) -> tuple[str, ...]:
        return tuple(self.data["runtime_requirements"]["jobs"])

    @property
    def consumers(self) -> tuple[str, ...]:
        return tuple(self.data["runtime_requirements"]["consumers"])

    @property
    def initial_mode(self) -> str:
        return self.data["runtime_requirements"]["initial_mode"]

    @property
    def model_lane_mode(self) -> str:
        """`off`, `evaluation`, `shadow` or `active`.

        Read from the artifact rather than a build flag, so changing it is a
        contract change the deploy validator compares against what it attested.

        **An unrecognised value raises.** The previous implementation asked
        whether the string contained "disabled" and treated everything else as
        enabled — so a typo, or a mode named `evaluation`, meant *on*. A switch
        governing whether a model runs against somebody's library must fail
        closed, and refusing outright is closed.
        """
        mode = str(
            self.data["runtime_requirements"].get("qwen_overlay", "")
        ).strip()
        if mode not in MODEL_LANE_MODES:
            raise ValueError(
                f"model lane mode {mode!r} is not one of {MODEL_LANE_MODES}")
        return mode

    # -- the output budget, read rather than copied -------------------------
    #
    # These were reachable only through `self.data`, so every caller that wanted
    # one reached past the reader and formed its own opinion of where it lived.
    # `output_budget_report.py` is the standing example: it hard-coded 512
    # because the emitter did not publish the reserve, and the docstring above
    # its constant claimed the opposite.

    @property
    def max_items_wire(self) -> int:
        """The most items one response may carry. A schema version change."""
        return int(self.data["output_contract"]["max_items_wire"])

    @property
    def default_batch_items(self) -> int:
        return int(self.data["output_contract"]["default_batch_items"])

    @property
    def calibrated_max_items(self) -> int:
        return int(self.data["output_contract"]["calibrated_max_items"])

    @property
    def max_output_tokens(self) -> int:
        return int(self.data["output_contract"]["max_output_tokens"])

    @property
    def envelope_token_reserve(self) -> int:
        return int(self.data["output_contract"]["envelope_token_reserve"])

    @property
    def output_schema_name(self) -> str:
        """`mention_extract_v2`, from the schema's own `$id`."""
        return self.versions["output_schema"].rsplit("/", 1)[-1].removesuffix(
            ".schema.json")

    @property
    def output_schema_path(self) -> pathlib.Path:
        """The file this contract was compiled against, beside this contract.

        Resolved from `self.path` rather than the module-level default, so a
        contract read from anywhere — a test copy, a staging drop — looks for its
        schema next to itself rather than next to whichever one happens to be
        installed.
        """
        beside = self.path.parent / f"{self.output_schema_name}.schema.json"
        return beside if beside.exists() else (
            contract_path().parent / f"{self.output_schema_name}.schema.json")

    @property
    def output_schema(self) -> dict:
        """Loaded once, from the path the contract names."""
        if self._schema is None:
            self._schema = json.loads(self.output_schema_path.read_text())
        return self._schema

    @property
    def model_may_be_called(self) -> bool:
        """`evaluation` and above. Invocation records are permitted."""
        return self.model_lane_mode in MODES_CALLING_MODEL

    @property
    def may_write_user_candidates(self) -> bool:
        """`shadow` and above. Mentions, provisionals and candidates may be
        attributed to a person — still with no assertion, publication or
        user-visible surface, which `calibration_reads` governs separately and
        stays false through both."""
        return self.model_lane_mode in MODES_WRITING_CANDIDATES

    def source_predicates(self, source_code: str) -> tuple[str, ...]:
        """The predicates a given source's profile permits.

        A profile may narrow the twelve and may never widen them; the compiler
        refuses to build a contract where one does.
        """
        profiles = self.data.get("source_predicate_profiles") or {}
        if source_code in profiles:
            return tuple(profiles[source_code])
        return self.predicates
