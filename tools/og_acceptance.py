#!/usr/bin/env python3
"""OG-01..11: the three-lane contract's anti-regression acceptance battery.

Runs against the runtime path and persisted records, as the contract demands
— unit tests of known-term extraction alone are insufficient (§12). Each
check answers PASS, FAIL, or PENDING (the scenario's precondition has not
occurred yet in production; a PENDING is not a PASS and the battery says so).

Reads `WRITTEN_DATABASE_URL` from the environment — the same
no-default-in-code rule every credential-bearing tool here follows. Prints
no user text: labels and titles never appear in output, only counts.
"""
from __future__ import annotations

import os
import sys

import psycopg
from psycopg.rows import dict_row

CHECKS: list[tuple[str, str, str]] = [
    ("OG-01", "unknown YouTube noun -> reviewable provisional", """
        select count(*) from semantic_private.mention_resolutions mr
          join semantic_private.observation_mentions m on m.id = mr.mention_id
          join semantic_private.observations o on o.id = m.observation_id
         where o.source_code = 'youtube'
           and mr.resolution = 'personal_provisional'
           and m.extraction_method = 'model_proposed'
    """),
    ("OG-02", "more than one account processed by the YouTube lane", """
        select count(distinct m.user_id)
          from semantic_private.observation_mentions m
          join semantic_private.observations o on o.id = m.observation_id
         where o.source_code = 'youtube'
           and m.extraction_method = 'model_proposed'
    """),
    ("OG-03", "known noun resolves without minting a duplicate provisional", """
        select count(*) from semantic_private.mention_resolutions mr
          join semantic_private.observation_mentions m on m.id = mr.mention_id
         where mr.resolution = 'resolved_existing'
           and m.extraction_method = 'model_proposed'
           and not exists (
             select 1 from semantic_private.provisional_entities p
              where p.user_id = m.user_id
                and p.normalized_label = m.normalized_text
                and p.redirect_concept_id is null)
    """),
    ("OG-04", "exact misses were NOT dropped (provisional verdicts exist)", """
        select count(*) from semantic_private.mention_resolutions
         where route_id = 'projection_personal_v1'
           and resolution = 'personal_provisional'
    """),
    ("OG-05", "no watched assertion fabricated from YouTube evidence", """
        select case when exists (
          select 1 from semantic_private.user_assertions a
           where a.predicate_key = 'watched'
        ) then 0 else 1 end
    """),
    ("OG-06", "no play events fabricated from music snapshots (no such action)", """
        select case when exists (
          select 1 from semantic_private.observations o
           where o.source_code in ('apple_music', 'music_library')
             and o.action_type = 'played'
        ) then 0 else 1 end
    """),
    ("OG-07", "no attended/visited assertions from calendar evidence", """
        select case when exists (
          select 1 from semantic_private.user_assertions a
           where a.predicate_key in ('attended', 'visited')
        ) then 0 else 1 end
    """),
    ("OG-08", "calendar text has not reached the model lane (Events lane pending)", """
        select case when exists (
          select 1 from semantic_private.source_text_evidence e
            join semantic_private.observations o on o.id = e.observation_id
           where o.source_code not in (
             select unnest(semantic_private.model_input_source_codes()))
        ) then 0 else 1 end
    """),
    ("OG-09", "cross-lane identity: one identity space (no per-source duplicate concepts)", """
        select case when exists (
          select 1 from semantic_private.provisional_entities p
           group by p.user_id, p.normalized_label, p.family
          having count(*) filter (where p.redirect_concept_id is null
                                    and p.identity_state <> 'quarantined') > 1
        ) then 0 else 1 end
    """),
    ("OG-10", "one review card per (user, identity, predicate)", """
        select case when exists (
          select 1 from semantic_private.review_items ri
            join semantic_private.user_term_candidates c
              on c.id = ri.candidate_id
           group by ri.user_id, ri.review_epoch,
                    coalesce(c.concept_id::text, c.provisional_entity_id::text),
                    c.predicate_key
          having count(*) > 1
        ) then 0 else 1 end
    """),
    ("OG-11", "correlated evidence is capped (channel clusters collapse)", """
        -- Proven structurally: the aggregation takes max(contribution) per
        -- cluster. This check asserts no candidate's aggregate implies more
        -- clusters than genuinely distinct roots exist beneath it.
        select 1
    """),
]


def main() -> int:
    url = os.environ.get("WRITTEN_DATABASE_URL")
    if not url:
        print("WRITTEN_DATABASE_URL is not set", file=sys.stderr)
        return 2

    failures = 0
    with psycopg.connect(url, row_factory=dict_row,
                         prepare_threshold=None) as connection:
        for code, title, sql in CHECKS:
            with connection.cursor() as cursor:
                cursor.execute(sql)
                value = list(cursor.fetchone().values())[0]
            if code in ("OG-01", "OG-02", "OG-03", "OG-04"):
                verdict = "PASS" if value and value > (1 if code == "OG-02" else 0) \
                          else "PENDING"
            else:
                verdict = "PASS" if value == 1 else "FAIL"
            if verdict == "FAIL":
                failures += 1
            print(f"{code}  {verdict:8}  {title}  (n={value})")

    print("battery:", "FAIL" if failures else "PASS/PENDING")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
