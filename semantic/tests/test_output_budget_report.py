"""The budget program, which had no test at all.

It is the artifact the `output_budget` gate rests on, it was structurally bound
to `mention_extract_v1`, and nothing in the suite executed a line of it — so the
fixture being invalid against its own schema, the ceiling being one token too
generous and the envelope reserve being a hard-coded constant dressed as a
contract read all survived review.

These tests do not measure Qwen. Measuring Qwen needs the pinned tokenizer, and
what can be checked without it is everything that was actually wrong: the shape
of what gets measured, and the arithmetic around it.
"""
from __future__ import annotations

import importlib.util
import json
import pathlib

import jsonschema
import pytest

REPOSITORY = pathlib.Path(__file__).resolve().parents[2]


@pytest.fixture(scope="module")
def budget():
    path = REPOSITORY / "tools" / "output_budget_report.py"
    spec = importlib.util.spec_from_file_location("output_budget_report", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def schema(budget):
    """The schema the compiled contract names, not one this file picks."""
    contract = json.loads(budget.CONTRACT.read_text())
    name = contract["versions"]["output_schema"].rsplit("/", 1)[-1]
    return json.loads((REPOSITORY / "semantic" / "contracts" / name).read_text())


@pytest.fixture(scope="module")
def limits(budget, schema):
    return budget.load_limits() | budget.schema_limits(schema)


def test_every_generated_response_validates_against_the_authored_schema(
        budget, schema, limits):
    """The defect that made the first report measure a response nothing could emit.

    `additionalProperties` is false, so a key v2 dropped is not a harmless extra
    — it is an invalid response, and measuring one reports a cost the model
    cannot incur.
    """
    validator = jsonschema.Draft202012Validator(schema)
    for name, unit in budget.SCRIPTS.items():
        text = (unit * (limits["surface_max"] // max(1, len(unit)) + 1))[
            : limits["surface_max"]]
        response = budget.make_response([text], limits, limits["max_mentions_per_item"])
        assert not list(validator.iter_errors(response)), name


def test_a_response_carries_no_field_the_schema_dropped(budget, schema, limits):
    """v2 removed three arrays and renamed the abstain flag."""
    response = budget.make_response(["a"], limits, 1)
    mention = response["items"][0]["mentions"][0]
    declared = set(schema["$defs"]["mention"]["properties"])
    assert set(mention) <= declared
    item = response["items"][0]
    assert set(item) <= set(schema["$defs"]["item"]["properties"])
    assert response["schema_version"] == schema["properties"]["schema_version"]["const"]


def test_the_singleton_ceiling_is_the_boundary_and_not_one_past_it(budget, limits):
    """2986.67 formatted with `%.0f` gives 2987, and 512 + ceil(1.2 * 2987) = 4097.

    Every safe length in the first report was derived against a ceiling one token
    over the one that exists. The boundary is asserted from the contract's own
    values rather than pinned to 2986, so moving the reserve or the headroom
    moves the assertion with it.
    """
    ceiling = budget.singleton_ceiling(limits)
    import math
    fits = limits["envelope_reserve"] + math.ceil(limits["headroom"] * ceiling)
    over = limits["envelope_reserve"] + math.ceil(limits["headroom"] * (ceiling + 1))
    assert fits <= limits["max_output_tokens"]
    assert over > limits["max_output_tokens"]


def test_the_ceiling_moves_with_the_envelope_reserve(budget, limits):
    """It was an inline loop with a literal 512 beside an unused `envelope_reserve`.

    The reserve could move in the contract and the ceiling would not, which is
    the failure mode the module docstring says the program exists to avoid.
    """
    base = budget.singleton_ceiling(limits)
    widened = dict(limits)
    widened["envelope_reserve"] = limits["envelope_reserve"] + 120
    assert budget.singleton_ceiling(widened) < base


def test_the_envelope_reserve_comes_from_the_contract(budget):
    """`int(...) and 512` named a contract key, discarded it, and returned a constant."""
    contract = json.loads(budget.CONTRACT.read_text())
    assert (budget.load_limits()["envelope_reserve"]
            == contract["output_contract"]["envelope_token_reserve"])
