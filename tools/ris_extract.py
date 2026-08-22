#!/usr/bin/env python3
"""Extraction on a lab GPU: every item, one sequence each, one scheduler.

**The same production code, not a reimplementation.** `serve.py` is mounted
beside this file, so prompt construction, the chat template and the
structured-output parameters are the ones the attested container uses.
`tools/ris_corpus_probe.py` established that pattern against synthetic
fixtures; this runs it over real work.

**One `generate()` call for the whole run.** The serving container fans a
batch into one prompt per item, so there is nothing to gain from re-grouping
items into requests here — handing vLLM every prompt at once lets its
scheduler do continuous batching across the lot, and a single item that
rambles to its token cap costs only itself. On AWS that same item refused the
whole eight-item batch and cost ninety seconds of salvage; here it costs one
sequence.

Input and output are JSONL on disk. Nothing in this file talks to a database:
the machine holding the credentials builds the items and ingests the answers,
so a shared cluster never sees them.
"""
from __future__ import annotations

import json
import os
import pathlib
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))  # serve.py and the contract mount beside this

CONTRACT = json.loads((HERE / "compiled_semantic_contract_v1.json").read_text())
SCHEMA_NAME = CONTRACT["versions"]["output_schema"].rsplit("/", 1)[-1]
OUT_SCHEMA = json.loads((HERE / SCHEMA_NAME).read_text())


def sequence_schema(schema: dict) -> dict:
    """What one sequence may emit: a single item.

    The gateway narrows this for the same reason — a prompt carrying one item
    told it may answer with eight will pad until it hits the token cap, which
    is measurable as `output_overflow` on every batch. Narrowing is safe
    because each sequence is asked about exactly one item.
    """
    narrowed = dict(schema)
    properties = dict(narrowed.get("properties", {}))
    items = dict(properties.get("items", {}))
    if not items:
        return schema
    items["maxItems"] = 1
    properties["items"] = items
    narrowed["properties"] = properties
    return narrowed


def request_doc(item: dict) -> dict:
    """One item, as the request schema permits it to travel."""
    # **Shared keys first, varying keys last.** The document is serialised in
    # insertion order and becomes the user message, so everything identical
    # across items — the versions, the profile, the forty parent candidates —
    # sits in a prefix the engine can cache once and reuse for every sequence.
    # Putting `request_id` before the candidates, as the natural reading order
    # would, breaks that prefix on every single item.
    return {
        "schema_version": CONTRACT["versions"].get(
            "request_schema", "mention_extract_request_v2"
        ).rsplit("/", 1)[-1].removesuffix(".schema.json"),
        "prompt_version": CONTRACT["versions"]["prompt"],
        "grammar_version": CONTRACT["versions"]["grammar"],
        "source_profile": item["source_profile"],
        **({"parent_candidates": item["parent_candidates"]}
           if item.get("parent_candidates") else {}),
        "request_id": f"ris_{item['row_id']}"[:64],
        "items": [{
            "item_index": 0,
            "item_id": str(item["row_id"])[:64],
            "fields": item["fields"],
            **({"source_action": item["source_action"]}
               if item.get("source_action") else {}),
        }],
    }


def main() -> int:
    items_path = pathlib.Path(sys.argv[1])
    out_path = pathlib.Path(sys.argv[2])
    items = [json.loads(line) for line in
             items_path.read_text().splitlines() if line.strip()]
    print(json.dumps({"stage": "loaded", "items": len(items)}), flush=True)

    os.environ.setdefault(
        "MODEL_PATH",
        "/storage2/fs1/erichuang/Active/written/models/qwen3.5-9b")
    import serve  # the production code, mounted beside this file

    started = time.monotonic()
    engine = serve.engine()
    print(json.dumps({"stage": "engine_ready",
                      "seconds": round(time.monotonic() - started, 1),
                      "runtime": {k: v for k, v in serve._runtime().items()
                                  if k != "tokenizer_runtime_manifest"}},
                     ensure_ascii=False), flush=True)

    max_tokens = CONTRACT["output_contract"]["max_output_tokens"]
    params = serve._structured_params(sequence_schema(OUT_SCHEMA), max_tokens)

    # **Prompts built through `serve._prompts`, one item at a time.** A
    # single-item document takes the pass-through branch, so these are exactly
    # the prompts the attested container would build for the same input.
    prompts, kept = [], []
    for item in items:
        payload = {"instructions": CONTRACT.get("prompt", {}),
                   "input": request_doc(item),
                   "max_output_tokens": max_tokens,
                   "enable_thinking": False}
        try:
            prompts.append(serve._prompts(payload)[0])
            kept.append(item)
        except Exception as error:  # noqa: BLE001 — named, never silent
            print(json.dumps({"row_id": item["row_id"],
                              "refused": "prompt_build_failed",
                              "detail": type(error).__name__}), flush=True)
    print(json.dumps({"stage": "prompts_built", "prompts": len(prompts)}),
          flush=True)

    # One call. vLLM schedules every sequence together; a runaway costs only
    # its own slot.
    started = time.monotonic()
    completions = engine.generate(prompts, params)
    elapsed = round(time.monotonic() - started, 1)
    print(json.dumps({"stage": "generated", "seconds": elapsed,
                      "items_per_second": round(len(prompts) / max(elapsed, 1), 2)}),
          flush=True)

    written = 0
    with out_path.open("w") as out:
        for item, completion in zip(kept, completions):
            output = completion.outputs[0]
            record = {
                "row_id": item["row_id"],
                "observation_id": item.get("observation_id"),
                "user_id": item.get("user_id"),
                "source_code": item.get("source_code"),
                "finish_reason": output.finish_reason,
                "completion_tokens": len(output.token_ids),
                # The raw text, validated by the machine that holds the
                # contract and the credentials — not here.
                "body": output.text,
            }
            out.write(json.dumps(record, ensure_ascii=False) + "\n")
            written += 1
    print(json.dumps({"stage": "done", "written": written,
                      "out": str(out_path)}), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
