#!/usr/bin/env python3
"""RIS evaluation rig: the corpus and the Gate-B shapes, in-process on a lab GPU.

Development evidence, never release attestation — the report records this
runtime's own facts and never claims the attested manifest hash. Inputs are
exactly: the public Qwen weights, the compiled contract, the output schema, and
synthetic fixtures. Nothing about any person is present or producible here.

Runs inside vllm/vllm-openai:v0.27.1 (same vLLM release as the pin) with
`serve.py` mounted beside it, so the prompt construction and structured-output
params are the production code, not a reimplementation.
"""
from __future__ import annotations

import json
import os
import pathlib
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))  # serve.py mounted beside this file

CONTRACT = json.loads((HERE / "compiled_semantic_contract_v1.json").read_text())
OUT_SCHEMA = json.loads((HERE / "mention_extract_v2.schema.json").read_text())
CORPUS = json.loads((HERE / "evaluation_corpus_v1.json").read_text())

FIELD_MAX = {"title": 256, "channel_label": 128, "description_excerpt": 512}
TAGS_MAX, TAG_LEN = 20, 64


def gpu_mem(tag: str) -> dict:
    import torch
    free, total = torch.cuda.mem_get_info()
    return {"stage": tag, "free_gib": round(free / 2**30, 2),
            "total_gib": round(total / 2**30, 2),
            "torch_allocated_gib": round(torch.cuda.memory_allocated() / 2**30, 2)}


def max_item(index: int, seed: str) -> dict:
    base = f"最大形状の題名 🎻 {seed} — Grenzwert der Übertragung "
    return {"item_index": index, "item_id": f"rismax{index}"[:64], "fields": {
        "title": (base * 8)[:FIELD_MAX["title"]],
        "channel_label": (f"合奏団 {seed} ensemble ")[:FIELD_MAX["channel_label"]].ljust(FIELD_MAX["channel_label"], "x"),
        "description_excerpt": (f"an invented excerpt for {seed}; " * 30)[:FIELD_MAX["description_excerpt"]],
        "tags": [f"tag{seed}{n}".ljust(TAG_LEN, "y")[:TAG_LEN] for n in range(TAGS_MAX)],
    }}


def request_doc(items: list[dict], request_id: str) -> dict:
    return {"schema_version": "mention_extract_request_v1",
            "prompt_version": CONTRACT["versions"]["prompt"],
            "grammar_version": CONTRACT["versions"]["grammar"],
            "source_profile": "music_catalog",
            "request_id": request_id, "items": items}


def validate(content: str, items: list[dict]) -> dict:
    record: dict = {}
    try:
        parsed = json.loads(content)
    except Exception as e:  # noqa: BLE001
        return {"schema_valid": False, "parse_error": type(e).__name__}
    try:
        import jsonschema
        jsonschema.validate(parsed, OUT_SCHEMA)
        record["schema_valid"] = True
    except ImportError:
        record["schema_valid"] = "jsonschema_unavailable_structural_only"
        record["structural"] = isinstance(parsed.get("items"), list)
    except Exception as e:  # noqa: BLE001
        return {"schema_valid": False, "schema_error": type(e).__name__,
                "detail": str(e)[:200]}
    got = sorted(i.get("item_index") for i in parsed.get("items", []))
    want = sorted(i["item_index"] for i in items)
    record["identity_match"] = got == want
    record["response_items"] = len(parsed.get("items", []))
    record["mentions_total"] = sum(len(i.get("mentions", [])) for i in parsed.get("items", []))
    return record


def main() -> int:
    os.environ.setdefault("MODEL_PATH", "/data/written-eval/artifacts")
    import serve  # the production code, mounted beside this file

    report: dict = {"work_item": "RIS-EVAL-1", "runtime": {}, "memory": [], "probes": []}
    report["memory"].append(gpu_mem("before_load"))
    t0 = time.monotonic()
    engine = serve.engine()
    report["engine_init_s"] = round(time.monotonic() - t0, 1)
    report["memory"].append(gpu_mem("after_engine_init"))
    report["runtime"] = {k: v for k, v in serve._runtime().items()
                         if k != "tokenizer_runtime_manifest"}

    probes: list[tuple[str, list[dict]]] = []
    for entry in CORPUS["items"]:
        probes.append((f"corpus_{entry['id']}",
                       [{"item_index": 0, "item_id": entry["id"],
                         "fields": {"title": entry["title"]}}]))
    probes.append(("gateB_single_max", [max_item(0, "alpha")]))
    probes.append(("gateB_pair_max", [max_item(0, "beta"), max_item(1, "gamma")]))
    probes += [(f"gateB_soak_{n:02d}", [max_item(0, f"soak{n}")]) for n in range(10)]

    max_tokens = CONTRACT["output_contract"]["max_output_tokens"]
    for name, items in probes:
        payload = {"instructions": CONTRACT.get("prompt", {}),
                   "input": request_doc(items, f"ris_{name}"),
                   "max_output_tokens": max_tokens}
        params = serve._structured_params(OUT_SCHEMA, max_tokens)
        prompt = serve._prompt(payload)
        started = time.monotonic()
        completions = engine.generate([prompt], params)
        latency = round(time.monotonic() - started, 2)
        output = completions[0].outputs[0]
        record = {"probe": name, "items": len(items), "latency_s": latency,
                  "finish_reason": output.finish_reason,
                  "completion_tokens": len(output.token_ids)}
        record.update(validate(output.text, items))
        record["expects"] = next((e["expects"] for e in CORPUS["items"]
                                  if name == f"corpus_{e['id']}"), None)
        if record["expects"] is None:
            record.pop("expects")
        report["probes"].append(record)
        print(json.dumps(record, ensure_ascii=False), flush=True)
        report["memory"].append(gpu_mem(f"after_{name}"))

    answered = [p for p in report["probes"] if p.get("schema_valid") is True]
    report["summary"] = {
        "probes": len(report["probes"]),
        "schema_valid": len(answered),
        "identity_match": sum(1 for p in answered if p.get("identity_match")),
        "memory_monotonic_climb": report["memory"][-1]["free_gib"] <
                                  report["memory"][2]["free_gib"] - 1.0
                                  if len(report["memory"]) > 3 else None,
    }
    out = pathlib.Path(os.environ.get("REPORT_PATH",
                                      str(HERE / f"ris_report_{int(time.time())}.json")))
    out.write_text(json.dumps(report, indent=2, ensure_ascii=False))
    print(f"report: {out}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
