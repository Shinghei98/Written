#!/usr/bin/env python3
"""Q5-HW-G5 Gates B and C: worst-case memory probes and contract fidelity.

Runs the memo's six-probe sequence against a live qualification endpoint,
directly (no gateway), building envelopes exactly as `attest.sh` does and
validating every response against the pinned output schema. Emits one
machine-readable report; writes nothing anywhere else.

Fixtures are synthetic to the letter of the memo: no user, no observation,
no retained source text, and titles invented here. Maximum-shaped items fill
every field to the wire schema's own maxima — read from the schema, not typed.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys
import time
import uuid

import boto3
import jsonschema

ROOT = pathlib.Path(__file__).resolve().parents[1]
CONTRACT = json.loads((ROOT / "semantic/contracts/compiled_semantic_contract_v1.json").read_text())
OUT_SCHEMA = json.loads((ROOT / "semantic/contracts/mention_extract_v2.schema.json").read_text())
REQ_SCHEMA = json.loads((ROOT / "semantic/contracts/mention_extract_request_v1.schema.json").read_text())

FIELD_MAX = {"title": 256, "channel_label": 128, "description_excerpt": 512}
TAGS_MAX, TAG_LEN = 20, 64


def max_item(index: int, seed: str) -> dict:
    """Every field at its schema maximum. CJK + emoji in the title (Gate C)."""
    base = f"最大形状の題名 🎻 {seed} — Grenzwert der Übertragung "
    title = (base * 8)[:FIELD_MAX["title"]]
    return {
        "item_index": index,
        "item_id": f"g5max{index}"[:64],
        "fields": {
            "title": title,
            "channel_label": (f"合奏団 {seed} ensemble ")[:FIELD_MAX["channel_label"]].ljust(FIELD_MAX["channel_label"], "x"),
            "description_excerpt": (f"an invented excerpt for {seed}; " * 30)[:FIELD_MAX["description_excerpt"]],
            "tags": [f"tag{seed}{n}".ljust(TAG_LEN, "y")[:TAG_LEN] for n in range(TAGS_MAX)],
        },
    }


def representative(index: int, title: str) -> dict:
    return {"item_index": index, "item_id": f"g5rep{index}", "fields": {"title": title}}


def envelope(items: list[dict], request_id: str) -> bytes:
    doc = {
        "model": CONTRACT["versions"]["model_id"],
        "model_revision": CONTRACT["versions"]["model_revision"],
        "temperature": 0,
        "max_output_tokens": CONTRACT["output_contract"]["max_output_tokens"],
        "enable_thinking": False,
        "response_format": {"type": "json_schema", "name": "mention_extract_v2",
                            "strict": True, "schema": OUT_SCHEMA},
        "instructions": CONTRACT.get("prompt", {}),
        "input": {
            "schema_version": "mention_extract_request_v1",
            "prompt_version": CONTRACT["versions"]["prompt"],
            "grammar_version": CONTRACT["versions"]["grammar"],
            "source_profile": "music_catalog",
            "request_id": request_id,
            "items": items,
        },
    }
    jsonschema.validate(doc["input"], REQ_SCHEMA)
    return json.dumps(doc).encode()


def run_probe(rt, s3, endpoint: str, bucket: str, name: str, items: list[dict],
              timeout_s: float = 420.0) -> dict:
    request_id = f"g5q_{name}_{uuid.uuid4().hex[:8]}"[:64]
    body = envelope(items, request_id)
    started = time.monotonic()
    ack = rt.invoke_endpoint_async(
        EndpointName=endpoint, ContentType="application/json",
        InferenceId=request_id, Body=body, InvocationTimeoutSeconds=420)
    out_key = ack["OutputLocation"].split("/", 3)[3]
    fail_key = ack["FailureLocation"].split("/", 3)[3]
    deadline = time.monotonic() + timeout_s
    outcome, response = "poll_timeout", None
    while time.monotonic() < deadline:
        for key, kind in ((out_key, "answered"), (fail_key, "provider_failed")):
            try:
                got = s3.get_object(Bucket=bucket, Key=key)
                payload = got["Body"].read()
                s3.delete_object(Bucket=bucket, Key=key)  # retention: nothing stays
                outcome = kind
                response = payload
                break
            except s3.exceptions.NoSuchKey:
                continue
            except Exception as e:  # noqa: BLE001
                if "NoSuchKey" in type(e).__name__ or "404" in str(e): continue
                raise
        if response is not None:
            break
        time.sleep(3)
    latency = round(time.monotonic() - started, 2)

    record = {"probe": name, "items": len(items), "request_bytes": len(body),
              "outcome": outcome, "latency_s": latency}
    if outcome == "answered":
        answer = json.loads(response)
        content = answer["choices"][0]["message"]["content"]
        record["finish_reason"] = answer["choices"][0].get("finish_reason")
        record["completion_tokens"] = answer.get("usage", {}).get("completion_tokens")
        try:
            parsed = json.loads(content)
            jsonschema.validate(parsed, OUT_SCHEMA)
            record["schema_valid"] = True
            record["response_items"] = len(parsed.get("items", []))
            record["identity_match"] = (
                sorted(i.get("item_index") for i in parsed.get("items", []))
                == sorted(i["item_index"] for i in items))
        except Exception as e:  # noqa: BLE001
            record["schema_valid"] = False
            record["schema_error"] = type(e).__name__
    elif response is not None:
        record["failure_head"] = response[:200].decode(errors="replace")
    return record


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--endpoint", required=True)
    ap.add_argument("--bucket", default="written-semantic-async-616040526027")
    ap.add_argument("--out", default="out/g5test/gates_bc.json")
    args = ap.parse_args()

    rt = boto3.client("sagemaker-runtime", region_name="us-east-1")
    s3 = boto3.client("s3", region_name="us-east-1")

    sequence: list[tuple[str, list[dict]]] = [
        ("b2_single_representative", [representative(0, "Nocturne of the Paper Cranes 🕊 — 리허설 녹음")]),
        ("b3_single_max_shaped", [max_item(0, "alpha")]),
        ("b4_two_representative", [representative(0, "Tin River Overture"),
                                   representative(1, "고요한 아침의 변주곡")]),
        ("b5_two_max_shaped", [max_item(0, "beta"), max_item(1, "gamma")]),
    ]
    sequence += [(f"b6_soak_max_{n:02d}", [max_item(0, f"soak{n}")]) for n in range(10)]

    results = []
    for name, items in sequence:
        record = run_probe(rt, s3, args.endpoint, args.bucket, name, items)
        print(json.dumps(record))
        results.append(record)
        if record["outcome"] != "answered":
            print(f"!! {name} did not answer; continuing to observe stability", file=sys.stderr)

    answered = [r for r in results if r["outcome"] == "answered"]
    report = {
        "work_item": "Q5-HW-G5", "gates": "B+C",
        "endpoint": args.endpoint,
        "probes_total": len(results),
        "answered": len(answered),
        "schema_valid": sum(1 for r in answered if r.get("schema_valid")),
        "identity_match": sum(1 for r in answered if r.get("identity_match")),
        "latency_s": sorted(r["latency_s"] for r in answered),
        "results": results,
    }
    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2))
    print(f"report: {out}")
    return 0 if (answered and all(r.get("schema_valid") for r in answered)) else 1


if __name__ == "__main__":
    raise SystemExit(main())
