#!/usr/bin/env python3
"""Validate what the lab GPU produced, and say what it means — nothing more.

**Validation happens here, not on the cluster.** The contract, the schema and
the semantic validator live with the repository, so the GPU emits raw text and
this machine decides what survives. That keeps one copy of the rules rather
than two that can drift, and it is why `ris_extract.py` writes `body` verbatim
instead of parsing it.

**This step writes no database rows.** It reports verdicts to JSON so they can
be reviewed before any migration is generated from them — the same discipline
the AWS sweep used, where the re-file was a reviewed migration rather than a
script writing directly into production.

    python3 tools/ris_ingest_results.py out/ris/items.jsonl \
        out/ris/results_00.jsonl ... out/ris/verdicts.json
"""
from __future__ import annotations

import collections
import json
import pathlib
import sys

REPOSITORY = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPOSITORY / "semantic" / "src"))

CONTRACT_PATH = (REPOSITORY / "semantic" / "contracts"
                 / "compiled_semantic_contract_v1.json")


def main() -> int:
    items_arg, *inputs, out_arg = sys.argv[1:]
    out_path = pathlib.Path(out_arg)

    # **The request, rejoined from what was sent.** Offsets are checked against
    # the exact source string, so validation needs the fields the model saw —
    # and the parent candidates, because an echoed id is only legal if it was
    # supplied. Carrying them back from the GPU would have duplicated 13 MB
    # into the results; the work list still has them, keyed by row.
    sent = {}
    for line in pathlib.Path(items_arg).read_text().splitlines():
        if line.strip():
            item = json.loads(line)
            sent[item["row_id"]] = item

    contract = json.loads(CONTRACT_PATH.read_text())
    schema_name = contract["versions"]["output_schema"].rsplit("/", 1)[-1]
    schema = json.loads(
        (REPOSITORY / "semantic" / "contracts" / schema_name).read_text())

    import jsonschema
    from written_ontology.mention_extract_v2 import (
        ExtractionInvalid, RequestItem, validate_response)

    validator = jsonschema.Draft202012Validator(schema)
    outcomes: collections.Counter = collections.Counter()
    by_source: dict = collections.defaultdict(collections.Counter)
    verdicts: list[dict] = []

    rows = []
    for pattern in inputs:
        for path in sorted(pathlib.Path().glob(pattern)) or [pathlib.Path(pattern)]:
            if path.is_file():
                rows += [json.loads(l) for l in
                         path.read_text().splitlines() if l.strip()]
    print(json.dumps({"stage": "loaded", "rows": len(rows),
                      "work_list": len(sent)}))
    missing = [r["row_id"] for r in rows if r["row_id"] not in sent]
    if missing:
        # A result whose request cannot be found cannot be validated, and
        # counting it as accepted would be asserting something unchecked.
        print(json.dumps({"unmatched_results": len(missing)}))

    for row in rows:
        source = row.get("source_code") or "unknown"

        # **Truncation is a refusal, named.** An answer that ran to the cap is
        # not a shorter answer; it is an unfinished one.
        if row.get("finish_reason") == "length":
            outcomes["output_overflow"] += 1
            by_source[source]["output_overflow"] += 1
            continue

        try:
            body = json.loads(row["body"])
        except (ValueError, TypeError):
            outcomes["unparseable"] += 1
            by_source[source]["unparseable"] += 1
            continue

        errors = sorted(validator.iter_errors(body),
                        key=lambda e: list(e.absolute_path))
        if errors:
            outcomes["schema_invalid"] += 1
            by_source[source]["schema_invalid"] += 1
            continue

        # The semantic layer the schema cannot express: offsets against the
        # source slice, control characters, the family/cardinal agreement and
        # the parent echo. The request is rebuilt from what was sent.
        original = sent.get(row["row_id"], {})
        request = [RequestItem(0, original.get("fields") or {},
                               original.get("source_action"))]
        try:
            supplied = frozenset(
                c["term_id"] for c in (original.get("parent_candidates") or []))
            validate_response(body, request, supplied or None)
        except ExtractionInvalid as refusal:
            outcomes[refusal.code] += 1
            by_source[source][refusal.code] += 1
            continue
        except Exception as error:  # noqa: BLE001 — named, never silent
            outcomes[f"validator_{type(error).__name__}"] += 1
            continue

        mentions = [m for item in body.get("items", [])
                    for m in item.get("mentions", [])]
        outcomes["accepted"] += 1
        by_source[source]["accepted"] += 1
        verdicts.append({
            "row_id": row["row_id"],
            "user_id": row.get("user_id"),
            "source_code": source,
            "mentions": mentions,
        })

    report = {
        "rows": len(rows),
        "accepted": outcomes["accepted"],
        "outcomes": dict(outcomes.most_common()),
        "by_source": {s: dict(c.most_common()) for s, c in by_source.items()},
        "mentions_total": sum(len(v["mentions"]) for v in verdicts),
        "verdicts": verdicts,
    }
    out_path.write_text(json.dumps(report, ensure_ascii=False, indent=1))
    summary = {k: v for k, v in report.items() if k != "verdicts"}
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
