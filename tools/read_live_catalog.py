#!/usr/bin/env python3
"""Read the live catalog for the semantic contract's database gate, with provenance.

`compiled_semantic_contract_v1.json` declares `concept_kind_authority:
live_pg_constraint`, and `tools/compile_semantic_contract.py --check-database`
takes those live values as an argument rather than opening a connection. That
was deliberate — a compiler that fell back to a checked-in snapshot would make
the authority claim a fiction — but it left the argument itself unattested. A
hand-written array satisfies the gate exactly as well as a real reading, and
looks identical afterwards.

**This is the other half.** It emits SQL that produces the snapshot, so the
snapshot is a thing a database said rather than a thing somebody typed, and it
travels with enough provenance to say *which* database said it and *when*:

- `constraint_oids` — the specific `pg_constraint` rows the allowlists were
  parsed out of. An oid changing means the constraint was dropped and recreated,
  which is exactly the event a stale snapshot would hide.
- `database_fingerprint_sha256` — a digest over every table, column and check
  constraint in the two schemas the contract cares about. `release_manifests`
  reserves a column of this name for the same purpose.
- `environment`, `server_version`, `generated_at`, `database`.

**It emits SQL rather than connecting.** `tools/replay_contracts.sh` is where
this most needs to run, and that script holds a throwaway Postgres it reaches
only through `docker exec … psql` — no DSN, no credential, nothing published on
a port. `tools/ios_envelope_contract.py --emit-sql` already solved this the same
way, and following it means the gate works identically against CI's container
and against production through any psql the operator already has.

    ./tools/read_live_catalog.py --emit-sql | psql -tA "$DSN" > live.json
    ./tools/compile_semantic_contract.py --check-database --live-enums live.json
"""

from __future__ import annotations

import argparse
import sys

#: **Only a positive, single-column `ANY(ARRAY[…])` allowlist counts.**
#: Three constraints mention `concept_kind`, and
#: `booked_activity_candidates_target_binding_v03_check` is a compound condition
#: that would yield a wrong, shorter list. The `not like '%OR%'` is what excludes
#: it, and the definition is required to look like a bare membership test.
ALLOWLIST_VALUES = """
  select regexp_replace(x, '^''|''::text$', '', 'g') as value
    from pg_constraint c,
         lateral regexp_split_to_table(
           substring(pg_get_constraintdef(c.oid) from 'ANY \\(ARRAY\\[(.*?)\\]\\)'),
           ',\\s*') as x
   where c.oid = %(oid)s
"""

SNAPSHOT_SQL = r"""
with target as (
  select
    (select c.oid from pg_constraint c
      where c.conrelid = 'ontology.concept_revisions'::regclass
        and c.conname like '%concept_kind%'
        and pg_get_constraintdef(c.oid) like '%concept_kind%ANY (ARRAY[%'
        and pg_get_constraintdef(c.oid) not like '%OR%'
      order by c.conname limit 1) as concept_kind_oid,
    (select c.oid from pg_constraint c
      where c.conrelid = 'semantic_private.worker_jobs'::regclass
        and pg_get_constraintdef(c.oid) like '%job_type%ANY (ARRAY[%'
        and pg_get_constraintdef(c.oid) not like '%OR%'
      order by c.conname limit 1) as job_type_oid,
    (select c.oid from pg_constraint c
      where c.conrelid = 'semantic_private.provisional_entities'::regclass
        and c.conname like '%family%'
        and pg_get_constraintdef(c.oid) like '%ANY (ARRAY[%'
        and pg_get_constraintdef(c.oid) not like '%OR%'
      order by c.conname limit 1) as family_oid,
    -- **Named rather than pattern-matched.** `0207`'s rule is a `case` with two
    -- arrays: a `<> ALL` for the legacy lane and a `= ANY` for the contract
    -- lanes, carrying the same fifteen roles. The extractor below finds
    -- `ANY (ARRAY[…])` and so reads the positive branch, which is the one that
    -- says what a contract lane *may* write.
    (select c.oid from pg_constraint c
      where c.conrelid = 'semantic_private.observation_mentions'::regclass
        and c.conname = 'observation_mentions_role_vocabulary_check'
      limit 1) as mention_role_oid
),
exploded as (
  select 'concept_kind' as allowlist, t.concept_kind_oid as oid from target t
  union all select 'job_type', t.job_type_oid from target t
  union all select 'provisional_family', t.family_oid from target t
  union all select 'mention_role', t.mention_role_oid from target t
),
values_of as (
  select e.allowlist,
         regexp_replace(x, '^''|''::text$', '', 'g') as value
    from exploded e,
         lateral regexp_split_to_table(
           substring(pg_get_constraintdef(e.oid) from 'ANY \(ARRAY\[(.*?)\]\)'),
           ',\s*') as x
   where e.oid is not null
),
-- **The digest covers structure, not contents.** Tables, columns with their
-- types and nullability, and every check constraint in the two schemas the
-- contract compiles into. A row changing must not move it; a column or a
-- constraint changing must.
fingerprint as (
  select encode(sha256(convert_to(string_agg(fact, E'\n' order by fact), 'utf8')), 'hex') as digest
    from (
      select format('t:%s.%s', table_schema, table_name) as fact
        from information_schema.tables
       where table_schema in ('semantic_private', 'ontology')
      union all
      select format('c:%s.%s.%s:%s:%s', table_schema, table_name, column_name,
                    data_type, is_nullable)
        from information_schema.columns
       where table_schema in ('semantic_private', 'ontology')
      union all
      select format('k:%s:%s', c.conname, pg_get_constraintdef(c.oid))
        from pg_constraint c
        join pg_class r on r.oid = c.conrelid
        join pg_namespace n on n.oid = r.relnamespace
       where n.nspname in ('semantic_private', 'ontology')
         and c.contype = 'c'
    ) as facts
)
select jsonb_pretty(jsonb_build_object(
  'concept_kind', (select jsonb_agg(value order by value)
                     from values_of where allowlist = 'concept_kind'),
  'job_type', (select jsonb_agg(value order by value)
                 from values_of where allowlist = 'job_type'),
  'provisional_family', (select jsonb_agg(value order by value)
                           from values_of where allowlist = 'provisional_family'),
  'mention_role', (select jsonb_agg(value order by value)
                     from values_of where allowlist = 'mention_role'),
  -- Hubs must be *active* at the published version. A draft revision is a
  -- concept the ontology has not adopted, and reporting it as present is how
  -- `0198` and `0199` came to parent 36 concepts under a hub nobody published.
  'hubs', (select jsonb_agg(distinct co.concept_key)
             from ontology.concept_revisions cr
             join ontology.concepts co on co.id = cr.concept_id
             join ontology.versions v on v.id = cr.ontology_version_id
            where v.status = 'published' and cr.status = 'active'
              and co.concept_key like 'hub:%'),
  'tables', (select jsonb_agg(schemaname || '.' || tablename order by schemaname, tablename)
               from pg_tables where schemaname in ('semantic_private', 'ontology')),
  'provenance', jsonb_build_object(
    'database_fingerprint_sha256', (select digest from fingerprint),
    'constraint_oids', (select jsonb_build_object(
                                 'concept_kind', t.concept_kind_oid::text,
                                 'job_type', t.job_type_oid::text,
                                 'provisional_family', t.family_oid::text,
                                 'mention_role', t.mention_role_oid::text)
                          from target t),
    'database', current_database(),
    'environment', coalesce(current_setting('written.environment', true), 'unspecified'),
    'server_version', current_setting('server_version'),
    'generated_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  )
));
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--emit-sql", action="store_true",
        help="print the query that produces the snapshot (the only mode)",
    )
    arguments = parser.parse_args()
    if not arguments.emit_sql:
        parser.error("only --emit-sql is supported; pipe it into psql")
    sys.stdout.write(SNAPSHOT_SQL)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
