from __future__ import annotations

import argparse
import json
import os
import socket
from uuid import uuid4
from collections import Counter
from collections import defaultdict
from pathlib import Path
from typing import Any

from .demo import run_demo
from .export_adapter import WrittenExportAdapter
from .repository import PostgresJobQueue
from .worker import SemanticWorker


def _print(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="written-ontology")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("demo", help="run the deterministic offline Italy convergence demo")

    inspect_parser = subparsers.add_parser(
        "inspect-export", help="inspect an eight-column Written CSV without printing row content"
    )
    inspect_parser.add_argument("path", type=Path)

    adapt_parser = subparsers.add_parser(
        "adapt-export", help="apply source/privacy gates and print aggregate results only"
    )
    adapt_parser.add_argument("path", type=Path)

    worker_parser = subparsers.add_parser("worker", help="poll the Postgres outbox")
    worker_parser.add_argument("--once", action="store_true", required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    if args.command == "demo":
        _print(run_demo())
        return 0
    if args.command == "inspect-export":
        _print(WrittenExportAdapter().inspect(args.path).as_dict())
        return 0
    if args.command == "adapt-export":
        result = WrittenExportAdapter().read(args.path)
        lineages: dict[str, set[str]] = defaultdict(set)
        for observation in result.observations:
            lineages[observation.independence_group].add(observation.content_lineage)
        _print(
            {
                "input_counts": result.input_counts,
                "raw_retained_counts": result.raw_retained_counts,
                "included_observations": len(result.observations),
                "included_by_source_and_type": dict(
                    sorted(Counter(
                        f"{item.source}|{item.data_type}" for item in result.observations
                    ).items())
                ),
                "excluded_counts": result.excluded_counts,
                "routed_profile_counts": result.routed_profile_counts,
                "routed_location_counts": result.routed_location_counts,
                "routed_connection_counts": result.routed_connection_counts,
                "policy_quarantined_counts": result.policy_quarantined_counts,
                "fitness_records": len(result.fitness_records),
                "fitness_coverage": (
                    result.fitness_coverage.state.value
                    if result.fitness_coverage is not None
                    else None
                ),
                "fitness_habit_candidates": len(result.fitness_habit_candidates),
                "external_resolution_allowed": sum(
                    item.allow_external_resolution for item in result.observations
                ),
                "private_text_observations": sum(
                    item.privacy_class.startswith("private")
                    for item in result.observations
                ),
                "unique_lineages_by_independence_group": {
                    key: len(values) for key, values in sorted(lineages.items())
                },
            }
        )
        return 0
    if args.command == "worker":
        database_url = os.environ.get("DATABASE_URL")
        if not database_url:
            raise SystemExit("DATABASE_URL is required")
        worker_id = os.environ.get("WORKER_ID") or (
            f"written-ontology:{socket.gethostname()}:{os.getpid()}:{uuid4().hex[:8]}"
        )
        # No default, for the reason `PostgresJobQueue.__init__` gives: this
        # application owns a real `private` schema that is nothing to do with
        # the semantic system, so guessing wrong addresses live objects rather
        # than missing ones. `WORKER_SCHEMA` exists so a disposable test project
        # can point elsewhere without editing code.
        schema = os.environ.get("WORKER_SCHEMA", "semantic_private")
        worker = SemanticWorker(PostgresJobQueue(database_url, worker_id, schema=schema))
        _print(worker.run_once())
        return 0
    raise AssertionError("unreachable")


if __name__ == "__main__":
    raise SystemExit(main())
