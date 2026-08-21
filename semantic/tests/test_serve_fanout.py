"""A batch is one prompt per item, and the answers merge back into one envelope.

**A batch was one prompt until 2026-08-21, and that was the throughput
problem.** `generate([prompt])` on an eight-item document is a single
sequence: one enormous structured JSON decoded token by token while every
other slot on the GPU sits idle. The endpoint's own log measured 162 s for one
eight-item batch — which was also just under the caller's patience, so half
those answers were abandoned seconds before they landed, read, deleted by the
retention rule, and re-run for ever.

These are the properties the fan-out has to keep, checked here because the
next place they can be checked is a GPU that takes hours to reacquire.
"""
from __future__ import annotations

import importlib.util
import json
import pathlib
import sys
import types

import pytest

REPOSITORY = pathlib.Path(__file__).resolve().parents[2]


class _FakeTokenizer:
    """Returns the user message unchanged, so the fan-out is inspectable."""

    def apply_chat_template(self, messages, **kwargs):
        return messages[-1]["content"]


@pytest.fixture(scope="module")
def serve():
    spec = importlib.util.spec_from_file_location(
        "serve_fanout_under_test", REPOSITORY / "aws" / "serving" / "serve.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    # The engine is never loaded: nothing here needs weights, and a test that
    # needed a GPU would not run.
    module.engine = lambda: types.SimpleNamespace(
        get_tokenizer=lambda: _FakeTokenizer())
    return module


def _document(count):
    return {"schema_version": "mention_extract_request_v2",
            "request_id": "req_fanout",
            "items": [{"item_index": i, "item_id": f"i{i}",
                       "fields": {"title": f"title {i}"}} for i in range(count)]}


def _envelope(index):
    return json.dumps({"schema_version": "mention_extract_v4",
                       "items": [{"item_index": index, "status": "extracted",
                                  "mentions": [], "abstain_reason": None}]})


class _Output:
    def __init__(self, text, finish="stop"):
        self.text = text
        self.finish_reason = finish
        self.token_ids = [0] * 5


def test_a_batch_becomes_one_prompt_per_item(serve):
    prompts = serve._prompts({"input": _document(4)})
    assert len(prompts) == 4
    for index, raw in enumerate(prompts):
        sent = json.loads(raw)
        assert len(sent["items"]) == 1
        # **The true index travels.** Renumbering would work right up until an
        # answer had to be matched back to the row that asked for it.
        assert sent["items"][0]["item_index"] == index
        assert sent["request_id"] == "req_fanout"


def test_a_single_item_request_is_unchanged(serve):
    payload = {"input": _document(1)}
    assert serve._prompts(payload) == [serve._prompt(payload)]


def test_the_answers_merge_into_one_envelope(serve):
    content, finish = serve._merge(
        [_Output(_envelope(0)), _Output(_envelope(1)), _Output(_envelope(2))])
    merged = json.loads(content)
    assert [item["item_index"] for item in merged["items"]] == [0, 1, 2]
    assert merged["schema_version"] == "mention_extract_v4"
    assert finish == "stop"


def test_one_truncated_sequence_truncates_the_answer(serve):
    """The gateway refuses a truncated answer, and a batch where one item ran
    to the cap is a truncated answer. Reporting `stop` would let a half
    extraction through as a whole one."""
    _, finish = serve._merge([_Output(_envelope(0)),
                              _Output(_envelope(1), "length")])
    assert finish == "length"


def test_an_unparseable_sequence_drops_only_its_own_item(serve):
    """Refused by name downstream — the gateway's coverage check says
    `missing_item` — rather than accepted as a silently shorter batch."""
    content, _ = serve._merge([_Output(_envelope(0)), _Output("not json")])
    assert [item["item_index"] for item in json.loads(content)["items"]] == [0]
