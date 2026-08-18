"""The contract's gateway revision must describe the gateway that is here.

This is the test the project was missing when it mattered. The gateway image was
built at one commit and `sagemaker_transport.py` was corrected ten minutes later
at the next, so the recorded digest described code that no longer existed — and
nothing anywhere could have noticed, because no check compared the contract
against the implementation it claimed to pin.

A contract compiled from a stale workbook now fails here rather than shipping.
"""
from __future__ import annotations

import json
import pathlib

from written_ontology.gateway_revision import GATEWAY_SOURCES, gateway_revision
from written_ontology.semantic_contract import contract_path

REPOSITORY = pathlib.Path(__file__).resolve().parents[2]


def test_the_contract_names_the_gateway_that_is_here():
    """Edit the transport without recompiling and this fails."""
    recorded = json.loads(contract_path().read_text())["versions"]["gateway_revision"]
    assert recorded == gateway_revision(REPOSITORY), (
        "the compiled contract's gateway_revision does not match the gateway "
        "sources in this tree. Recompile with "
        "`python tools/compile_semantic_contract.py --emit` after updating "
        "llm.gateway.revision in terms.xlsx.")


def test_every_named_source_exists():
    """A path that stops existing must fail loudly, not hash to nothing."""
    for relative in GATEWAY_SOURCES:
        assert (REPOSITORY / relative).is_file(), f"missing gateway source: {relative}"


def test_the_revision_moves_when_the_implementation_moves(tmp_path):
    """The other direction: a hash that never changes proves nothing.

    Copy the tree, change one byte of the transport, and the answer must differ.
    """
    for relative in GATEWAY_SOURCES:
        target = tmp_path / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((REPOSITORY / relative).read_bytes())
    before = gateway_revision(tmp_path)
    assert before == gateway_revision(REPOSITORY), "the copy is not a copy"

    transport = tmp_path / "aws/gateway/sagemaker_transport.py"
    transport.write_bytes(transport.read_bytes() + b"\n# one more byte\n")
    assert gateway_revision(tmp_path) != before


def test_the_placeholders_are_gone():
    """Neither revision may go back to naming nothing."""
    versions = json.loads(contract_path().read_text())["versions"]
    for field in ("model_revision", "gateway_revision"):
        value = versions[field]
        assert not value.startswith("pin_"), f"{field} is still a placeholder: {value}"
