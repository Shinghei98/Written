# Applying 0042–0049 to production

Everything here is ready and verified. **Nothing has been applied.** The block
is access, not readiness — see the last section.

## Production baseline, captured 2026-08-10 (read-only)

Project `fwnezkbesjoazlpaflbq`. Re-measure after deploying and compare.

| Fact | Value |
|---|---|
| `semantic_private` / `ontology` / `api` present | **0 of 3** — production is at `0041` |
| `supabase_migrations` schema | **absent** — not an empty ledger, no ledger at all |
| `private` table ACLs (md5) | `80a84bd432d956bb40696a66f3c0936f` |
| `private` schema ACL | `postgres=UC/postgres` |
| `private` tables | 2 (`push_config`, `collaborators`) |
| `anon` / `authenticated` / `service_role` usage on `private` | **false / false / false** |
| `public` object fingerprint | `dae091d60e659e1d7c71edfbde76fb17` across 117 objects |

That last line is the one worth pausing on: a from-empty replay of
`0001`–`0049` now produces **the same fingerprint over the same 117 objects**.
The repository reproduces production.

## The order, and why it is this order

**1. Repair the ledger first — nothing else is safe until it exists.**

There is no `supabase_migrations` schema, so the CLI believes *no* migration has
been applied. Run `supabase db push` before repairing and it will try to apply
`0001` against a database that already has everything, fail partway, and leave
you diagnosing a mess that need not have happened.

```bash
supabase link --project-ref fwnezkbesjoazlpaflbq
supabase migration repair --status applied \
  0001 0002 0003 0004 0005 0006 0007 0008 0009 0010 \
  0011 0012 0013 0014 0015 0016 0017 0018 0019 0020 \
  0021 0022 0023 0024 0025 0026 0027 0028 0029 0030 \
  0031 0032 0033 0034 0035 0036 0037 0038 0039 0040 0041
```

`0042`–`0049` are deliberately **not** repaired: they genuinely have not been
applied, and marking them so would skip them forever. `migration repair` writes
only to the ledger — no DDL — but it is a production write and belongs to
whoever owns the project.

**2. Confirm the CLI agrees before pushing.**

```bash
supabase migration list        # 0001-0041 applied, 0042-0049 pending
```

If that list disagrees with the sentence above, stop.

**3. Push.**

```bash
supabase db push
```

**4. Verify — the same checks that were run locally.**

```sql
-- schemas arrived
select count(*) from pg_namespace where nspname in ('semantic_private','ontology','api');  -- 3

-- the app's private schema was not touched
select md5(string_agg(c.relname||':'||coalesce(array_to_string(c.relacl,','),'<default>'), '|' order by c.relname))
from pg_class c where c.relnamespace='private'::regnamespace and c.relkind='r';
-- must still be 80a84bd432d956bb40696a66f3c0936f

select has_schema_privilege('anon','private','usage'),
       has_schema_privilege('authenticated','private','usage'),
       has_schema_privilege('service_role','private','usage');
-- must still be false, false, false

-- the conflation is gone
select count(*) from pg_constraint con
join pg_class rel on rel.oid=con.conrelid
join pg_class ref on ref.oid=con.confrelid
where con.contype='f' and ref.relname='ingestion_runs'
  and rel.relnamespace='semantic_private'::regnamespace
  and exists (select 1 from unnest(con.conkey) x(a)
              join pg_attribute at2 on at2.attrelid=con.conrelid and at2.attnum=x.a
              where at2.attname='source_code');
-- must be 0

-- every flag off
select count(*) from semantic_private.feature_flags where enabled;  -- 0
```

Then run `get_advisors` for security, since DDL landed.

## What this does and does not change

**No product behaviour.** Nothing in Swift reads `semantic_private`, `ontology`
or `api`. Every feature flag is seeded off. The legacy path is untouched:
`append_source_records`, `discovery_cards`, `seed_icebreaker` and
`match_profile` all keep working exactly as before. `0050` (server projections)
and `0051` (cutover) are the ones that change behaviour, and neither is written.

**`0049` is a no-op against production**, where `rls_auto_enable` and
`ensure_rls` already exist. It is there so a replay matches.

## Why this has not been run

Two independent blocks, either of which is enough:

- **The Supabase MCP server is read-only.** Confirmed by probe, not assumed:
  `create temporary table` returns `25006: cannot execute CREATE TABLE in a
  read-only transaction`. It exposes no `apply_migration`.
- **The CLI is not authenticated.** `supabase projects list` returns
  `Access token not provided`.

To unblock, either `supabase login` (then the steps above run as written), or
restart the MCP server without its read-only flag. **Prefer the CLI**: it
writes the ledger as it goes, which is the entire point of step 1, and an MCP
that can write to production is a broader grant than this task needs.

## Rollback

`0042`–`0049` are additive: new schemas, no change to any `public` object, no
data migrated. If something is wrong, `drop schema semantic_private cascade;
drop schema ontology cascade; drop schema api cascade;` returns the database to
`0041` — and `0049` should be left in place, since it only captures what
production already had. This is the last point at which rollback is that easy;
`0051` is forward-only by contract.
