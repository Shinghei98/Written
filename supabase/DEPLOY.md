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
> reasoning still applies to `0053`/`0054`.

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
`match_profile` all keep working exactly as before. **`0053` (server
projections) and `0054` (cutover) are the ones that change behaviour**, and
neither is written. Those numbers have shifted four times — `0049` to the
captured platform trigger, `0050` to the key registry, `0051` to aligning its
key-version vocabulary, `0052` to the ingestion identity — so read a number in
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

`0042`–`0052` are additive: new schemas, no change to any `public` object, no
data migrated. If something is wrong, `drop schema semantic_private cascade;
drop schema ontology cascade; drop schema api cascade;` returns the database to
`0041` — and `0049` should be left in place, since it only captures what
production already had. This is the last point at which rollback is that easy;
`0054` is forward-only by contract.

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

---

## 0051, applied 2026-08-10

`0050` and `0046` disagreed by one character about what a `key_version` may
contain: the registry admitted a colon, and
`raw_source_records.encryption_key_version` — the column that *names* that
version — did not. So a key could have been created, used to encrypt, and then
been unstorable on the row obliged to name it, with the refusal arriving at
ingestion time one service away from the cause. Measured against production
before the fix:

| candidate | registry (0050) | record (0046) |
|---|---|---|
| `v1`, `v1.2`, `2026-08-10` | accepted | accepted |
| `v1:2026` | accepted | **refused** |

`0046` wins — it is adapted from the contract, and `0050` invented something.

**`0051` also asserts the two patterns match**, reading both out of
`pg_get_constraintdef` at migration time rather than trusting its own comment,
and raising if they differ. Proven by perturbing `0046`'s side in a throwaway
container and watching it refuse, naming both patterns:

    ERROR:  key-version vocabularies disagree:
            registry ^[a-z0-9][a-z0-9_.-]{0,63}$ vs record ^[a-z0-9][a-z0-9_.WRONG-]{0,63}$

Post-push, verified in production: both patterns now read
`^[a-z0-9][a-z0-9_.-]{0,63}$` and compare equal, `v1:2026` is refused, the
table is still empty, and the `private` table-ACL fingerprint is unchanged.

**Free only because the table is empty.** Tightening a constraint stops being
free the day Phase 1's ingestion Lambda writes the first row.

---

## 0052, applied 2026-08-10

An identity for the ingestion endpoint that can write the vault and read
nothing. It exists because the reasoning behind hosting ingestion on AWS was
half wrong: a Lambda cannot reach `semantic_private` any more than an edge
function can reach KMS, so the choice was never "credential or no credential"
but *which* credential. `service_role` would have been the largest one this
project has, sitting in a second cloud.

`semantic_ingestor` gets `usage` on the schema and `execute` on one
`security definer` function. Verified in production after the push:

| Check | Result |
|---|---|
| Role exists / can log in | yes / **no** — the password is set out of band |
| Readable tables across `semantic_private`, `ontology`, `public`, `private` | **0** |
| Callable functions in `semantic_private` | **1** |
| Usage on the app's `private` schema | false |
| `(apple_music, user)` matrix pair | present |
| `private` table-ACL fingerprint | unchanged |
| Vault rows | 0 |

**One step remains and this migration deliberately does not do it.** The role is
created `nologin` with no password, so until somebody runs

    alter role semantic_ingestor login password '<generated>';

and puts that password in AWS Secrets Manager, it cannot connect at all. A
secret in a migration is a secret in git.

**A trap worth keeping:** `has_schema_privilege('semantic_ingestor','public','usage')`
reports **true** and always will. That privilege belongs to the `PUBLIC`
pseudo-role, and revoking it from one named role does nothing while revoking it
from `PUBLIC` would break `anon` and `authenticated`. Schema usage grants
nothing on its own — the count of *readable tables* is the property that
matters, and it is 0.

### How the endpoint will actually reach Postgres

Measured 2026-08-10, and the first line is the one that constrains everything
else:

    dig db.fwnezkbesjoazlpaflbq.supabase.co A     -> (nothing)
    dig db.fwnezkbesjoazlpaflbq.supabase.co AAAA  -> 2600:1f18:45ac:6d00:…

**The direct connection has no A record at all.** Lambda's egress is IPv4, so
the direct host is not merely discouraged, it is unreachable — the shared pooler
is the only route that does not cost money. (The IPv4 add-on is the paid
alternative.)

Project region is `us-east-1`, the same as the KMS keys. Both pooler fleets
resolve and are IPv4:

    aws-0-us-east-1.pooler.supabase.com -> 44.216.29.125, 44.208.221.186, 52.45.94.125
    aws-1-us-east-1.pooler.supabase.com -> 18.214.78.123, 18.213.155.45, 3.227.209.82

Which fleet this project is on is not derivable from DNS — Supavisor resolves
the tenant from the username at authentication time, so both hosts answer for
everybody. **Dashboard → Connect** names the right one.

**Port 6543, transaction mode**, which Supabase's own documentation names for
"serverless and edge functions". One consequence for whoever writes the Lambda:
*transaction mode does not support prepared statements*, so the Postgres driver
must have them turned off or every call fails in a way that looks like a syntax
problem.

**An open premise, and it should be settled before the Lambda is written.**
Supabase documents the pooler username only as `postgres.PROJECT_REF` and says
nothing about custom roles. If Supavisor will not accept
`semantic_ingestor.fwnezkbesjoazlpaflbq`, `0052`'s design does not work from AWS
and the fallbacks are session mode on 5432, the paid IPv4 add-on, or reversing
the hosting decision to an edge function — see `semantic/docs/KMS_DESIGN.md`,
which records why that was the close second.

### A restore brings this role back mute

Supabase's own restore guidance is explicit that custom roles with `LOGIN` have
their passwords excluded from a dump, and must be set again by hand afterwards.
So a restored project has `semantic_ingestor` present, correctly privileged, and
unable to connect — which will look like a broken endpoint rather than a missing
password. The fix is the same `alter role … login password` step, and the
password is in AWS Secrets Manager under `written/semantic-ingestor`.
