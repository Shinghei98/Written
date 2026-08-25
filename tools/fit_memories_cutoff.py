#!/usr/bin/env python3
"""Fit per-hub Memories cutoffs from one user's keep/strike record.

**The bootstrap's second half (owner, 2026-08-25).** Under `cutoff-v0` the
person is shown everything; what they struck and what they left standing is
the only ground truth this system has about where their cutoff belongs. This
joins those outcomes to each term's surfacing score and topical hub, sweeps
candidate thresholds per hub, and writes **one dry-run report row** —
`semantic_private.memories_cutoff_dry_runs` (0361) — proposing a value per
hub. It never writes a release: the owner reads the report and approves
values into a draft `memories_cutoff_releases` row by hand, which is the
0257 dry-run discipline applied to display.

The heuristic, stated plainly because n=1 deserves no more machinery:

* Per hub, candidate thresholds are the midpoints between adjacent observed
  scores. The proposal minimizes misclassification — struck terms above the
  threshold plus kept terms below it — with ties going to the lower
  threshold (withholding less on equal evidence).
* **The dominant-hub note is applied as a report, not a formula.** Where a
  hub holds more than half of what would be shown, a second number is
  computed: the threshold at which the hub's share falls to just above 50%
  (majority kept, flood cut). Both numbers appear in the report; the choice
  between them is the owner's.
* A hub with no strikes proposes 0 — no evidence anybody wants less of it.

Terms carry their hub via `semantic_private.concept_hub` (0360); a struck
term is one with an active `user_term_suppressions` / `user_suppressions`
row or a `suppressed` preference; kept is shown-and-not-struck.

    SUPABASE_SECRET_KEY=... python3 tools/fit_memories_cutoff.py <user_uuid> \
        [proposed_release]
"""
from __future__ import annotations

import json
import os
import sys

QUERY = """
with v as (select id from ontology.versions where status = 'published'),
rows as (
  select a.id as assertion_id,
         coalesce(s.surfacing_score, 1.0) as score,
         coalesce(semantic_private.concept_hub(
           a.concept_id, coalesce(s.ontology_version_id, v.id)),
           '(no hub)') as hub_key,
         (exists (select 1 from semantic_private.user_suppressions us
                   where us.user_id = a.user_id
                     and us.predicate_key = a.predicate_key
                     and us.active and us.concept_id = a.concept_id)
          or exists (select 1 from semantic_private.assertion_preferences p
                      where p.assertion_id = a.id and p.user_id = a.user_id
                        and p.display_state = 'suppressed')) as struck
    from semantic_private.user_assertions a
    left join semantic_private.assertion_current_scores cs
      on cs.assertion_id = a.id and cs.user_id = a.user_id
    left join semantic_private.assertion_score_versions s
      on s.id = cs.assertion_score_version_id, v
   where a.user_id = %(user)s::uuid
     and a.machine_state in ('candidate', 'eligible')
)
select hub_key, score, struck from rows
"""


def propose(scores_struck: list[tuple[float, bool]]) -> dict:
    """One hub's proposal: the misclassification-minimizing threshold."""
    if not any(struck for _, struck in scores_struck):
        return {"proposed_cutoff": 0.0, "misclassified": 0}
    ordered = sorted({s for s, _ in scores_struck})
    candidates = [0.0] + [
        (a + b) / 2 for a, b in zip(ordered, ordered[1:])
    ] + [min(1.0, ordered[-1] + 1e-6)]
    best, best_err = 0.0, None
    for threshold in candidates:
        err = sum(1 for s, struck in scores_struck
                  if (struck and s >= threshold) or (not struck and s < threshold))
        if best_err is None or err < best_err:
            best, best_err = threshold, err
    return {"proposed_cutoff": round(best, 4), "misclassified": best_err}


def main() -> int:
    user = sys.argv[1]
    release = sys.argv[2] if len(sys.argv) > 2 else "cutoff-v1"

    # Direct Postgres as the worker role — the fit reads semantic_private,
    # which no HTTP surface exposes, and writes one dry-run row.
    dsn = os.environ.get("WRITTEN_DB_DSN")
    if not dsn:
        raise SystemExit("set WRITTEN_DB_DSN (worker-role Postgres DSN)")
    import psycopg
    from psycopg.rows import dict_row

    with psycopg.connect(dsn, row_factory=dict_row) as connection:
        with connection.cursor() as cursor:
            cursor.execute(QUERY, {"user": user})
            rows = cursor.fetchall()

        by_hub: dict[str, list[tuple[float, bool]]] = {}
        for row in rows:
            by_hub.setdefault(row["hub_key"], []).append(
                (float(row["score"]), bool(row["struck"])))

        shown_total = len(rows)
        per_hub = {}
        for hub, pairs in sorted(by_hub.items()):
            entry = propose(pairs)
            entry.update({
                "n": len(pairs),
                "keeps": sum(1 for _, s in pairs if not s),
                "strikes": sum(1 for _, s in pairs if s),
                "share_before": round(len(pairs) / shown_total, 4) if shown_total else 0,
            })
            survivors = sum(1 for s, _ in pairs if s >= entry["proposed_cutoff"])
            other_survivors = 0
            for other, other_pairs in by_hub.items():
                if other == hub:
                    continue
                other_cut = propose(other_pairs)["proposed_cutoff"]
                other_survivors += sum(1 for s, _ in other_pairs if s >= other_cut)
            total_after = survivors + other_survivors
            entry["share_after"] = round(survivors / total_after, 4) if total_after else 0
            # The dominant-hub note: where the hub would still flood, name
            # the threshold that caps it at a bounded majority. Reported,
            # never chosen here.
            if entry["share_after"] > 0.5 and other_survivors:
                cap = int(other_survivors * 1.2)  # majority, bounded
                ranked = sorted((s for s, _ in pairs), reverse=True)
                if len(ranked) > cap:
                    entry["majority_bounded_cutoff"] = round(ranked[cap], 4)
            per_hub[hub] = entry

        with connection.cursor() as cursor:
            cursor.execute(
                """
                insert into semantic_private.memories_cutoff_dry_runs
                  (proposed_release, fitted_for_user, per_hub, method, notes)
                values (%(release)s, %(user)s::uuid, %(per_hub)s::jsonb,
                        'midpoint-sweep-misclassification-v1',
                        'n=1 fit; every number approximate by construction')
                returning id
                """,
                {"release": release, "user": user,
                 "per_hub": json.dumps(per_hub)})
            report_id = cursor.fetchone()["id"]
        connection.commit()

    print(json.dumps({"report_id": str(report_id), "release": release,
                      "hubs": {h: {k: v[k] for k in
                                   ("n", "keeps", "strikes", "proposed_cutoff",
                                    "share_before", "share_after")}
                               for h, v in per_hub.items()}}, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
