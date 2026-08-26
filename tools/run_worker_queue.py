#!/usr/bin/env python3
"""Drain the worker queue: the consumer the armers were missing.

**Why this exists (owner, 2026-08-26).** `0363` unscheduled the pg_cron
armers because they fed a consumer — the AWS worker — that had gone
quiet: jobs accumulated forever and the hourglass never cleared. The
queue's *producers* are healthy and were never touched: ingestion
enqueues a recompute when a distillation finalizes, and since `0396`
every ontology publish enqueues one too. What was missing is the other
half. This script is it: claim queued `recompute_user` jobs, run the full
DB-only stage set for each distinct user (the same
`tools/run_worker_stages.py` every manual run uses), and record the
outcome on the job row.

Re-arming is therefore NOT re-scheduling the old cron armers — that would
recreate `0363`'s bug — it is scheduling THIS consumer on a machine that
exists. On the owner's Mac, every ten minutes:

    launchctl load ~/Library/LaunchAgents/com.written.worker-queue.plist

with `WRITTEN_DATABASE_URL` supplied by the plist from a mode-600 file
outside the repository (`~/.written/env`). The credential never enters
this tree; the script reads only the environment, the same contract as
`tools/seed_synthetic.py`.

Semantics, kept deliberately small:

- **`recompute_user` only.** It is the one job type today's producers
  write; the run it triggers executes every stage, so a finer-grained
  job vocabulary is legacy history, not work to claim. Anything else in
  the queue is counted and left alone.
- **One run per user per pass.** Ten queued jobs for one user are one
  stale page, not ten runs — all are claimed together and settled by a
  single stage run.
- **Claim with `for update skip locked`**, so two overlapping passes
  never run the same user twice.
- **Failure re-queues with backoff** (`attempts` + 1, available in
  `attempts * 10` minutes) until five attempts, then `dead` — the
  vocabulary `0363` established for "claimed by no handler".
- **One pass, then exit.** The scheduler owns the cadence; a loop here
  would be a second scheduler that can disagree with the first.

    WRITTEN_DATABASE_URL=... python3 tools/run_worker_queue.py
"""
from __future__ import annotations

import json
import os
import pathlib
import socket
import subprocess
import sys

MAX_ATTEMPTS = 5

#: A `running` row older than the lease is a claim whose holder died —
#: this pass's own first version proved it (the pooler closed a
#: connection held across 25 minutes of subprocess work, stranding three
#: jobs). Reclaiming is part of claiming.
CLAIM = """
with mine as (
  select id from semantic_private.worker_jobs
   where job_type = 'recompute_user'
     and ((status = 'queued' and available_at <= now())
          or (status = 'running'
              and locked_at < now() - interval '90 minutes'))
   order by created_at
   for update skip locked
)
update semantic_private.worker_jobs j
   set status = 'running', locked_at = now(), locked_by = %(who)s,
       updated_at = now()
  from mine
 where j.id = mine.id
returning j.id, j.user_id, j.attempts
"""

#: **The job rows speak a closed control-message contract**
#: (`guard_worker_job_contract_v03`): `locked_by` is `[A-Za-z0-9._:+-]`
#: only, `last_error` is a fixed vocabulary — `handler_error`, never
#: stderr text — and `result` admits only registered keys. Failure detail
#: therefore goes to this process's own stderr (launchd files it in
#: `~/.written/worker-queue.err`), not into the row.
SETTLE_OK = """
update semantic_private.worker_jobs
   set status = 'succeeded', result = %(result)s::jsonb, updated_at = now()
 where id = any(%(ids)s)
"""

SETTLE_FAIL = """
update semantic_private.worker_jobs
   set status = case when attempts + 1 >= %(max_attempts)s
                     then 'dead' else 'queued' end,
       attempts = attempts + 1,
       available_at = now() + make_interval(mins => (attempts + 1) * 10),
       last_error = 'handler_error',
       locked_at = null, locked_by = null, updated_at = now()
 where id = any(%(ids)s)
"""

OTHERS = """
select job_type, count(*) as n from semantic_private.worker_jobs
 where status = 'queued' and job_type <> 'recompute_user'
 group by job_type
"""


def main() -> int:
    database_url = os.environ.get("WRITTEN_DATABASE_URL")
    if not database_url:
        print("WRITTEN_DATABASE_URL is not set", file=sys.stderr)
        return 2

    import psycopg
    from psycopg.rows import dict_row

    host = "".join(ch for ch in socket.gethostname()
                   if ch.isalnum() or ch in "._:+-") or "host"
    who = f"queue-drain.{host}"
    stages_script = pathlib.Path(__file__).with_name("run_worker_stages.py")

    # **Connections are short-lived, one per act.** A stage run takes tens
    # of minutes; the pooler closes an idle connection long before that,
    # and a settle written on a dead connection strands the job `running`.
    # Claim, settle, and report each open their own connection and close
    # it before any long work begins.
    def _query(sql, params=None):
        with psycopg.connect(database_url, row_factory=dict_row,
                             prepare_threshold=None) as connection:
            with connection.cursor() as cursor:
                cursor.execute(sql, params or {})
                rows = cursor.fetchall() if cursor.description else []
            connection.commit()
        return rows

    claimed = _query(CLAIM, {"who": who})

    by_user: dict[str, list] = {}
    for job in claimed:
        by_user.setdefault(str(job["user_id"]), []).append(job)

    outcomes = []
    for user_id, jobs in by_user.items():
        ids = [job["id"] for job in jobs]
        run = subprocess.run(
            [sys.executable, str(stages_script), "--user", user_id],
            capture_output=True, text=True, timeout=3600,
            env={**os.environ, "WRITTEN_DATABASE_URL": database_url})
        if run.returncode == 0:
            _query(SETTLE_OK, {
                "ids": ids,
                "result": json.dumps({"status": "succeeded",
                                      "item_count": len(ids)})})
        else:
            print(f"stages failed for {user_id}:\n"
                  + (run.stderr or run.stdout or "").strip()[-4000:],
                  file=sys.stderr)
            _query(SETTLE_FAIL, {"ids": ids, "max_attempts": MAX_ATTEMPTS})
        outcomes.append({"user": user_id, "jobs": len(ids),
                         "ok": run.returncode == 0})

    left_alone = {row["job_type"]: row["n"] for row in _query(OTHERS)}

    print(json.dumps({"claimed_users": len(by_user), "outcomes": outcomes,
                      "other_job_types_left_alone": left_alone}))
    return 0 if all(o["ok"] for o in outcomes) else 1


if __name__ == "__main__":
    raise SystemExit(main())
