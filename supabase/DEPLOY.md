# Applying the semantic chain to production

> ## APPLIED 2026-08-10. This is now a record, not a plan.
>
> Ledger repaired (0001–0041), `supabase db push` applied `0042`–`0049`, and
> every check below passed. **`0050` went the same day, on the same
> mechanism** — one pending migration, one push, recorded at the foot of this
> file. Post-deploy state after `0049`:
>
> | Check | Result |
> |---|---|
> | Semantic schemas | 3 of 3 (`semantic_private`, `ontology`, `api`) |
> | Tables created | 67 `semantic_private` + 16 `ontology` |
> | `api` RPCs | 7 (six Memories + `feature_flags`) |
> | Source-coupled run FKs | **0** — the conflation is gone in production |
> | Feature flags enabled | **0 of 7** |
> | `private` ACL fingerprint | `80a84bd432d956bb40696a66f3c0936f` — **identical to the pre-deploy baseline** |
> | `anon` / `authenticated` / `service_role` on `private` | false / false / false |
> | `authenticated` on `semantic_private` / `ontology` | false / false (`api` only) |
> | Legacy path | untouched — 6,148 `distilled_records`, 5 `discovery_cards`, icebreaker trigger and `append_source_records` both present |
> | Advisors | **no ERROR**; 70 new INFO, all `rls_enabled_no_policy` on the new schemas |
>
> **Those 70 INFO findings are the intended posture, not a gap.** RLS is on with
> no policy on every new table, which denies every caller that is not
> `service_role` — the same shape as `private.push_config`. Read them as
> confirmation.
>
> **One thing is deliberately not done yet:** the `api` schema is not in the
> project's exposed schemas, so `api.feature_flags()` is not reachable from the
> client. That is Phase 1 work, alongside the `Accept-Profile` header in
> `PostgREST.swift`.
>
> Everything below is the procedure as written beforehand, kept because the
> reasoning still applies to `0050`/`0051`.

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
`match_profile` all keep working exactly as before. **`0051` (server
projections) and `0052` (cutover) are the ones that change behaviour**, and
neither is written. Those numbers have shifted twice — `0049` went to the
captured platform trigger and `0050` to the key registry — so read a number in
the integration plan as a role rather than a filename.

**`0049` is a no-op against production**, where `rls_auto_enable` and
`ensure_rls` already exist. It is there so a replay matches.

## How this was unblocked

Two independent blocks stood in the way, either of which was enough, and both
are worth keeping because either could recur:

- **The Supabase MCP server is read-only.** Confirmed by probe, not assumed:
  `create temporary table` returns `25006: cannot execute CREATE TABLE in a
  read-only transaction`, and it exposes no `apply_migration`. It stays that
  way — the CLI is the write path.
- **The CLI was not authenticated.** `supabase projects list` returned
  `Access token not provided`. `supabase login` fixed it.

**The CLI is the right tool regardless of which block clears first**: it writes
the ledger as it goes, which is the entire point of step 1, and an MCP that can
write to production is a broader grant than this task needs. The MCP is still
what does the *verification*, which is exactly the right split.

## Rollback

`0042`–`0050` are additive: new schemas, no change to any `public` object, no
data migrated. If something is wrong, `drop schema semantic_private cascade;
drop schema ontology cascade; drop schema api cascade;` returns the database to
`0041` — and `0049` should be left in place, since it only captures what
production already had. This is the last point at which rollback is that easy;
`0052` is forward-only by contract.

**One caveat that only applies once `0050` is in use**: dropping
`semantic_private` takes `user_encryption_keys` with it, and **that is a
mass crypto-erasure** — every `encrypted_payload` written under those keys
becomes permanently unreadable. Harmless while the table is empty, which it is
today. From the first row onward, dump it before dropping anything.

---

## 0050, applied 2026-08-10

One pending migration, one `supabase db push`, no ledger work needed — the
ledger from the previous deploy is doing its job. The push warns about a Docker
file-sharing mount; that is the CLI failing to cache a local catalog and has
nothing to do with the migration, which applied.

| Check | Result |
|---|---|
| `semantic_private.user_encryption_keys` present | yes |
| RLS on / policies | **on / 0** — deny-all to every client role, `service_role` only |
| `anon` / `authenticated` select | false / false |
| `service_role` insert | true |
| Partial unique index (one live key per user) | present |
| Check constraints (version, ARN, blob length) | 3 |
| Rows | 0 — nothing writes it yet |
| `private` table-ACL fingerprint | **identical either side of the push** |
| `anon` / `authenticated` / `service_role` usage on `private` | false / false / false |
| Advisors | **no ERROR.** 71 `rls_enabled_no_policy` INFO on the new schemas — 70 before, plus this table — and the other 2 are `private.push_config` and `private.collaborators`, the same intended posture. All 24 WARN are pre-existing and in `public`. |

The ACL fingerprint here is computed by a different expression from step 4's, so
it is not comparable to `80a84bd4…`; it was measured immediately before and
immediately after the push with the same query, which is the check that matters.
