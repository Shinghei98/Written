#!/usr/bin/env python3
"""Run the worker's database-only stages from a laptop.

**Everything between a mention and a card is SQL, and none of it needs AWS.**
`resolve_mention`, `build_candidate_overlay`, `aggregate_term_candidates`,
`build_review_items`, `apply_feedback` and `process_mint_requests` open a
Postgres connection, execute statements that live either in `overlay.py` as
strings or in the database as functions, and commit. The resolver and scorer
are the same: `resolve_user` reads `observations.normalized_payload`, which is
the *sanitised* projection and needs no key.

**One import binds them to AWS, and it is the only one.** `resolve.py`,
`score.py` and `overlay.py` import no boto3 whatsoever — but every stage body
does `from handler import database_url`, and `aws/worker/handler.py` reads
`VAULT_KEY_ARN` and `DB_SECRET_ID` at module level and builds Secrets Manager
and KMS clients there. So this **supplies a `handler` module** exposing that
one symbol rather than importing the real one. Nothing is monkeypatched and
boto3 is never needed; the stages ask for a connection string and are given
one, which is the whole of their dependency.

**The stages are imported, never reimplemented.** This file contributes no SQL
and no ordering of its own: the order below is `arm_candidate_overlay`'s
(`0234`), which pg_cron has been enqueueing every five minutes with nothing on
the other end to run it.

**Two things are refused by name rather than left to fail.**
`extract_mentions` needs KMS, a Lambda, SageMaker, S3 and DynamoDB — the RIS
toolchain substitutes for it. And `build_fitness_snapshot` needs KMS
`Decrypt`; it lives in `handler.recompute_user`, so calling `resolve_user`
directly leaves it out by construction rather than by a flag that could be
forgotten.

    WRITTEN_DATABASE_URL=... python3 tools/run_worker_stages.py \\
        --user eb769605-... [--stages resolve_mention,build_review_items]

Needs `psycopg` only.
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import sys
import types
import uuid

REPOSITORY = pathlib.Path(__file__).resolve().parents[1]

#: The stages this runner will run, in `arm_candidate_overlay`'s order. A list
#: rather than a set because the order *is* the contract: a candidate cannot be
#: built before its mention resolves, and a review item cannot be built before
#: its candidate has a tier.
DEFAULT_STAGES = (
    "recompute_user",
    "resolve_mention",
    "build_candidate_overlay",
    "aggregate_term_candidates",
    "build_review_items",
    "process_mint_requests",
)

#: Refused rather than attempted. Failing halfway would leave the pipeline in a
#: state no receipt describes.
NEEDS_AWS = {
    "extract_mentions":
        "KMS, Lambda, SageMaker, S3 and DynamoDB — use the RIS toolchain "
        "(tools/ris/SUBMIT.md) to produce mentions instead",
}


def _install_handler_stub(database_url: str) -> None:
    """Give the stages the one symbol they import, and nothing else.

    Placed in `sys.modules` *before* any stage is imported, so
    `from handler import database_url` inside a function body finds this
    instead of the Lambda module. Deliberately carries no other attribute: if
    a stage ever starts reaching for `_kms` or `VAULT_KEY_ARN`, it fails here
    with an `ImportError` naming the symbol rather than silently doing
    something a laptop should not be doing.
    """
    # **The bundle's layout, reproduced rather than guessed.** `build.sh:37`
    # copies `tools/music_dictionary.py`, `tools/music_works.py` and
    # `tools/apple_catalog.py` flat beside the handler and `:54` copies
    # `semantic/src/written_ontology` in whole, because the stages import them
    # by bare module name. A laptop needs the same three directories on the
    # path or `resolve` fails at import with a name that looks unrelated.
    for directory in ("aws/worker", "semantic/src", "tools"):
        sys.path.insert(0, str(REPOSITORY / directory))
    stub = types.ModuleType("handler")
    stub.database_url = lambda: database_url  # type: ignore[attr-defined]
    sys.modules["handler"] = stub


def _arguments(stage: str, options) -> dict:
    """The parameters the stage itself binds, sourced where the stage sources them.

    Each entry mirrors that stage's own `arguments` dict in `overlay.py`, and
    every value is read off `overlay` or the compiled contract rather than
    restated here — so `RESOLVE_BATCH` moving moves this too. The three that
    cannot be read from code are supplied on the command line: the published
    ontology version, the review epoch, and the resolver label, which
    `arm_candidate_overlay` defaults to `exact-0.1.0`.
    """
    import overlay  # noqa: PLC0415
    from written_ontology.semantic_contract import load as load_contract  # noqa: PLC0415, E501

    common = {"user_id": options.user}
    if stage == "resolve_mention":
        return {**common, "resolver_version": options.resolver_version,
                "route": overlay.EXACT_ROUTE, "batch": overlay.RESOLVE_BATCH,
                "version": options.ontology_version}
    if stage == "build_candidate_overlay":
        return {**common, "route": overlay.EXACT_ROUTE,
                "predicate": overlay.EXACT_PREDICATE,
                "batch": overlay.CANDIDATE_BATCH}
    if stage == "aggregate_term_candidates":
        return {**common, "saturation": overlay.SATURATION,
                "bar": overlay.ELIGIBILITY}
    if stage == "build_review_items":
        return {**common, "epoch": options.review_epoch,
                "page": overlay.REVIEW_PAGE,
                "presentation": load_contract().versions["grammar"]}
    return common


def _job(job_type: str, payload: dict):
    from written_ontology.repository import WorkerJob  # noqa: PLC0415

    return WorkerJob(id=str(uuid.uuid4()), job_type=job_type,
                     user_id=payload.get("user_id"), payload=payload,
                     attempts=0, lease_token=str(uuid.uuid4()))


def _payload_for(job_type: str, user_id: str, connection) -> dict:
    """What the armer would have put on the job.

    Read from the database rather than assumed — the review epoch especially,
    because `current_review_epoch` returns the *lowest unfinished* epoch and
    building into the wrong one puts cards where nobody is served them.
    """
    payload: dict = {"user_id": user_id}
    with connection.cursor() as cursor:
        cursor.execute("select id::text as version_id from ontology.versions"
                       " where status = 'published'"
                       " order by published_at desc limit 1")
        row = cursor.fetchone()
        if row:
            payload["ontology_version_id"] = row["version_id"]
        if job_type == "build_review_items":
            cursor.execute(
                "select semantic_private.current_review_epoch(%(user)s::uuid)"
                " as epoch", {"user": user_id})
            payload["review_epoch"] = cursor.fetchone()["epoch"]
        if job_type == "recompute_user":
            cursor.execute(
                "select coalesce(max(revision), 0) as revision"
                "  from semantic_private.user_state_versions"
                " where user_id = %(user)s::uuid", {"user": user_id})
            payload["input_revision"] = cursor.fetchone()["revision"]
            # **The run's identity carries the model ids, so the payload must**
            # — `resolve_user` reads both keys, exactly as the armer's payload
            # supplies them, and a run recorded without them would not name
            # which resolver and scorer produced it. Read from the same place
            # the armer reads: the one active row per role.
            cursor.execute(
                "select model_role, id::text as model_id"
                "  from ontology.model_versions"
                " where model_role in ('resolver', 'scorer')"
                "   and status = 'active'")
            for row in cursor.fetchall():
                payload[f"{row['model_role']}_model_id"] = row["model_id"]
    return payload


def _recompute(job, database_url: str) -> dict:
    """The resolver and scorer, without the fitness snapshot.

    `handler.recompute_user` runs `build_fitness_snapshot` first and then
    `resolve_user`; the snapshot unwraps a data key and so needs KMS, while
    the resolver reads only the sanitised projection. Calling `resolve_user`
    directly is what leaves the snapshot out — not a flag — and `score_user`
    runs inside it, so assertions are produced here too.
    """
    import psycopg  # noqa: PLC0415
    from psycopg.rows import dict_row  # noqa: PLC0415
    from resolve import resolve_user  # noqa: PLC0415

    with psycopg.connect(database_url, row_factory=dict_row,
                         prepare_threshold=None) as connection:
        result = resolve_user(connection, job.payload["user_id"], job.payload)
        connection.commit()
    return {"status": "succeeded", "fitness": "skipped (needs KMS Decrypt)",
            **(result if isinstance(result, dict) else {"result": result})}


def main() -> int:
    parser = argparse.ArgumentParser(description="run the DB-only worker stages")
    parser.add_argument("--user", required=True)
    parser.add_argument("--stages", default=",".join(DEFAULT_STAGES))
    parser.add_argument("--dry-run", action="store_true",
                        help="say what would run, touch nothing")
    parser.add_argument("--print-sql", action="store_true",
                        help="emit each stage's statements with parameters "
                             "bound, for a route that is not psycopg")
    parser.add_argument("--review-epoch", type=int,
                        help="with --print-sql: the epoch to build into. Read "
                             "it from current_review_epoch first — building "
                             "into the wrong one puts cards where nobody is "
                             "served them")
    parser.add_argument("--ontology-version",
                        help="with --print-sql: the published ontology version id")
    parser.add_argument("--resolver-version", default="exact-0.1.0",
                        help="the label arm_candidate_overlay defaults to")
    options = parser.parse_args()

    if options.print_sql:
        stages = [s.strip() for s in options.stages.split(",") if s.strip()]
        _install_handler_stub("unused: --print-sql opens no connection")
        return print_sql(options.user, stages, options)

    database_url = os.environ.get("WRITTEN_DATABASE_URL")
    if not database_url:
        print("WRITTEN_DATABASE_URL is not set — the same variable "
              "tools/og_acceptance.py reads", file=sys.stderr)
        return 2

    stages = [s.strip() for s in options.stages.split(",") if s.strip()]
    for stage in stages:
        if stage in NEEDS_AWS:
            print(f"refusing {stage}: {NEEDS_AWS[stage]}", file=sys.stderr)
            return 2

    if options.dry_run:
        print(json.dumps({"user": options.user, "stages": stages,
                          "database": database_url.rsplit("@", 1)[-1]},
                         indent=2))
        return 0

    _install_handler_stub(database_url)

    import psycopg  # noqa: PLC0415
    from psycopg.rows import dict_row  # noqa: PLC0415

    import overlay  # noqa: PLC0415

    handlers = {
        "recompute_user": lambda job: _recompute(job, database_url),
        "resolve_mention": overlay.resolve_mention,
        "build_candidate_overlay": overlay.build_candidate_overlay,
        "aggregate_term_candidates": overlay.aggregate_term_candidates,
        "build_review_items": overlay.build_review_items,
        "apply_feedback": overlay.apply_feedback,
        "process_mint_requests": overlay.process_mint_requests,
    }

    # **`prepare_threshold=None`.** The transaction pooler fails an
    # auto-prepared statement with `42P05` on the second of two back-to-back
    # calls, which is why every worker connection carries this.
    reader = psycopg.connect(database_url, row_factory=dict_row,
                             prepare_threshold=None)
    try:
        for stage in stages:
            run = handlers.get(stage)
            if run is None:
                print(json.dumps({"stage": stage, "status": "no_handler"}))
                return 1
            payload = _payload_for(stage, options.user, reader)
            try:
                receipt = run(_job(stage, payload))
            except Exception as error:  # noqa: BLE001 — named, never silent
                receipt = {"status": "failed", "error": type(error).__name__,
                           "detail": str(error)[:400]}
            print(json.dumps({"stage": stage, "payload": payload,
                              "receipt": receipt},
                             ensure_ascii=False, default=str), flush=True)
            if isinstance(receipt, dict) and receipt.get("status") == "failed":
                # **Stop at the first failure**: the order is a dependency
                # chain, so continuing would report success for a stage whose
                # input never arrived.
                return 1
    finally:
        reader.close()
    return 0


# ---------------------------------------------------------------------------
# `--print-sql` — the same stages, for a connection this machine does not have
# ---------------------------------------------------------------------------
#
# **A laptop with no database password can still run these**, because four of
# the six stages are thin wrappers: each opens a connection, executes two or
# three statements from `overlay.py`, and commits. This mode emits exactly
# those statements with their parameters bound, so they can be run through any
# route that reaches the database — the Supabase SQL editor, `supabase db
# query`, or an MCP tool — and the result is the same rows the stage would
# have written.
#
# **The SQL is imported, never retyped.** Every statement below is an
# attribute read off `overlay`, so a change there is picked up here and the two
# cannot drift. What this mode does *not* cover is `recompute_user`: its work
# is `resolve_user`'s Python — mapping, scoring, saturation — and there is no
# honest way to express that as a statement. Assertions therefore still need a
# connection; the calibration cards do not.

STAGE_SQL = {
    "resolve_mention": ("RESOLVE", "PROVISION"),
    "build_candidate_overlay": ("BUILD_CANDIDATES", "LINK_EVIDENCE",
                                "BUILD_PROVISIONAL"),
    "aggregate_term_candidates": ("AGGREGATE", "TIER_TALLY"),
    "build_review_items": ("BUILD_REVIEW", "LINK_REVIEW_ROUTES",
                           "LINK_REVIEW_EVIDENCE"),
}


def _literal(value) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    return "'" + str(value).replace("'", "''") + "'"


def print_sql(user_id: str, stages: list[str], options) -> int:
    """Emit each stage's statements with `%(name)s` bound to literals."""
    import re as _re  # noqa: PLC0415

    import overlay  # noqa: PLC0415

    for stage in stages:
        names = STAGE_SQL.get(stage)
        if not names:
            print(f"-- {stage}: not expressible as SQL "
                  f"(its work is Python; it needs a connection)")
            continue
        arguments = _arguments(stage, options)
        missing = [k for k, v in arguments.items() if v is None]
        if missing:
            print(f"-- {stage}: cannot bind {missing} — supply them on the "
                  f"command line", file=sys.stderr)
            return 2
        print(f"\n-- ===== {stage} =====")
        for name in names:
            statement = getattr(overlay, name)
            bound = _re.sub(
                r"%\((\w+)\)s",
                lambda m: _literal(arguments.get(m.group(1))), statement)
            print(f"-- {name}")
            print(bound.strip().rstrip(";") + ";")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
