#!/usr/bin/env python3
"""Fit per-hub Memories cutoffs from every user's strikes, one vote per user.

**The owner's design (2026-09-06).** Every strike on Memories is a record.
After a window of deployment - two weeks was the figure - the strikes are
averaged across users to redesign the candidacy bar per hub, *accounting
for pseudoreplication*: ten strikes from one person are one person's view,
not ten votes. This tool is that average, written as a report the owner
reads and approves, never as a release it activates itself (the 0361
discipline: the fit reports before it acts).

The method, stated plainly:

* Per user, per hub, the existing midpoint fit (`fit_memories_cutoff.py`)
  proposes the threshold that best separates what the person struck from
  what they left standing. That is the person's one vote for the hub.
* A person votes in a hub only where they struck at least once and saw at
  least `--min-shown` rows there; silence in a hub is abstention, not a
  vote for zero.
* The hub's proposed bar is the mean of its votes (the owner's word), with
  the median and the spread reported beside it. A hub with fewer than
  `--min-voters` voters abstains and keeps the active release's value.
* The window is `--since` (default: the moment the active release went
  live); strikes and restores before it belong to an earlier framework
  and are not counted, as 0362 decided.

"Shown" is inferred, not recorded: Memories records an exposure at the
moment of an answer, not when a row draws (`SemanticSurfaceService`), so a
row counts as shown when its surfacing score clears the bar that was
active for that person and hub. Under `cutoff-v0` that is every standing
row, which is what the single-user fit already assumed.

    WRITTEN_DATABASE_URL=... python3 tools/fit_memories_cutoff_global.py \\
        [--release cutoff-v1] [--since 2026-08-25] [--min-voters 3] \\
        [--min-shown 5] [--write-draft]

`--write-draft` inserts the proposed release as a *draft* with user-less
per-hub rows. Activation stays a migration under 0360's one-active index.
"""
from __future__ import annotations

import argparse
import json
import os
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fit_memories_cutoff import propose  # noqa: E402  (the per-user vote)

ROWS = """
with v as (select id from ontology.versions where status = 'published'),
active as (select release_version, default_cutoff, created_at
             from semantic_private.memories_cutoff_releases where status = 'active')
select a.user_id,
       coalesce(s.surfacing_score, 1.0) as score,
       coalesce(semantic_private.concept_hub(
         a.concept_id, coalesce(s.ontology_version_id, v.id)), '(no hub)') as hub_key,
       -- struck within the window: an active suppression, or a suppressed
       -- preference, created since the window opened
       (exists (select 1 from semantic_private.user_suppressions us
                 where us.user_id = a.user_id and us.active
                   and us.predicate_key = a.predicate_key
                   and us.concept_id = a.concept_id
                   and us.created_at >= %(since)s)
        or exists (select 1 from semantic_private.assertion_preferences p
                    where p.assertion_id = a.id and p.user_id = a.user_id
                      and p.display_state = 'suppressed'
                      and p.updated_at >= %(since)s)) as struck,
       semantic_private.active_memories_cutoff(a.user_id,
         semantic_private.concept_hub(a.concept_id, coalesce(s.ontology_version_id, v.id))) as bar
  from semantic_private.user_assertions a
  left join semantic_private.assertion_current_scores cs
    on cs.assertion_id = a.id and cs.user_id = a.user_id
  left join semantic_private.assertion_score_versions s
    on s.id = cs.assertion_score_version_id, v
 where a.machine_state in ('candidate', 'eligible')
   and a.assertion_origin = 'inferred'
"""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--release", default="cutoff-v1")
    ap.add_argument("--since", default=None,
                    help="window start (ISO date); default: the active release's activation")
    ap.add_argument("--min-voters", type=int, default=3)
    ap.add_argument("--min-shown", type=int, default=5)
    ap.add_argument("--stat", choices=("mean", "median"), default="mean")
    ap.add_argument("--write-draft", action="store_true")
    args = ap.parse_args()

    dsn = os.environ.get("WRITTEN_DATABASE_URL")
    if not dsn:
        raise SystemExit("set WRITTEN_DATABASE_URL (worker-role Postgres DSN)")
    import psycopg
    from psycopg.rows import dict_row

    with psycopg.connect(dsn, row_factory=dict_row) as connection:
        with connection.cursor() as cursor:
            cursor.execute("select release_version, default_cutoff, created_at "
                           "from semantic_private.memories_cutoff_releases where status = 'active'")
            active = cursor.fetchone()
            since = args.since or active["created_at"]
            cursor.execute(ROWS, {"since": since})
            rows = cursor.fetchall()
            cursor.execute("select release_version, hub_key, cutoff from semantic_private.memories_cutoff_values "
                           "where release_version = %s and user_id is null", (active["release_version"],))
            current = {r["hub_key"]: float(r["cutoff"]) for r in cursor.fetchall()}

        # user -> hub -> [(score, struck)] over rows that were shown
        by_user: dict[str, dict[str, list[tuple[float, bool]]]] = {}
        for r in rows:
            if float(r["score"]) < float(r["bar"]):
                continue                                   # never on screen: no evidence either way
            by_user.setdefault(str(r["user_id"]), {}).setdefault(r["hub_key"], []) \
                   .append((float(r["score"]), bool(r["struck"])))

        # one vote per (user, hub)
        votes: dict[str, dict[str, float]] = {}
        for user, hubs in by_user.items():
            for hub, pairs in hubs.items():
                if len(pairs) >= args.min_shown and any(s for _, s in pairs):
                    votes.setdefault(hub, {})[user] = propose(pairs)["proposed_cutoff"]

        hubs = sorted({h for u in by_user.values() for h in u})
        per_hub: dict[str, dict] = {}
        for hub in hubs:
            vs = votes.get(hub, {})
            entry = {
                "shown_rows": sum(len(u.get(hub, [])) for u in by_user.values()),
                "users_shown": sum(1 for u in by_user.values() if hub in u),
                "strikes": sum(1 for u in by_user.values() for _, s in u.get(hub, []) if s),
                "voters": len(vs),
                "votes": {u[:8]: v for u, v in vs.items()},
                "current_cutoff": current.get(hub, float(active["default_cutoff"])),
            }
            if len(vs) >= args.min_voters:
                values = list(vs.values())
                entry["mean"] = round(statistics.mean(values), 4)
                entry["median"] = round(statistics.median(values), 4)
                entry["spread"] = [round(min(values), 4), round(max(values), 4)]
                entry["proposed_cutoff"] = entry[args.stat]
                entry["decision"] = "propose"
            else:
                entry["proposed_cutoff"] = entry["current_cutoff"]
                entry["decision"] = "abstain (fewer than %d voters)" % args.min_voters
            # what the proposal would hide, per user
            entry["hidden_per_user"] = {
                u[:8]: sum(1 for s, _ in hs.get(hub, []) if s < entry["proposed_cutoff"])
                for u, hs in by_user.items() if hub in hs}
            per_hub[hub] = entry

        method = ("per-user midpoint fit; one vote per user per hub; %s across voters; "
                  "min_voters=%d min_shown=%d; window since %s; shown = above the active bar"
                  % (args.stat, args.min_voters, args.min_shown, str(since)[:19]))
        with connection.cursor() as cursor:
            cursor.execute(
                """
                insert into semantic_private.memories_cutoff_dry_runs
                  (proposed_release, fitted_for_user, per_hub, method, notes)
                values (%(release)s, null, %(per_hub)s::jsonb, %(method)s,
                        'cross-user fit; a hub abstains until it has enough voters')
                returning id
                """,
                {"release": args.release, "per_hub": json.dumps(per_hub), "method": method})
            report_id = cursor.fetchone()["id"]

            if args.write_draft:
                cursor.execute(
                    "insert into semantic_private.memories_cutoff_releases "
                    "(release_version, status, default_cutoff, notes) values (%s, 'draft', %s, %s)",
                    (args.release, active["default_cutoff"],
                     "Drafted from cross-user fit report %s; activate by migration." % report_id))
                for hub, entry in per_hub.items():
                    if entry["decision"] == "propose":
                        cursor.execute(
                            "insert into semantic_private.memories_cutoff_values "
                            "(release_version, hub_key, user_id, cutoff) values (%s, %s, null, %s)",
                            (args.release, hub, entry["proposed_cutoff"]))
        connection.commit()

    print(json.dumps({"report_id": str(report_id), "release": args.release,
                      "window_since": str(since)[:19], "method": method,
                      "hubs": per_hub}, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
