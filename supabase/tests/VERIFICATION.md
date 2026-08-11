# What has actually been run, and against what

Written 2026-08-10. **Documentation is not a passing test result** — this file
records executions, and anything not listed here has not happened.

> **This is now reproducible rather than a story about one afternoon.**
> Everything below was originally run by hand in a throwaway container, which
> meant the proof evaporated with the container. It lives in
> `tools/replay_contracts.sh` now, runs in CI on any push touching
> `supabase/migrations/**` or `supabase/tests/**`, and runs the same way
> locally:
>
> ```bash
> ./tools/replay_contracts.sh        # needs Docker, a few minutes
> ```
>
> Latest run: **11 passed, 0 failed.**

## Environment

Supabase Postgres **17.6** (`public.ecr.aws/supabase/postgres:17.6.1.156`) in a
local container. Deliberately not PGlite: that harness shimmed the `auth`
schema and substituted a UUID primitive for `pgcrypto`, so it could not
exercise the 31 `auth.users` foreign keys the semantic chain declares.

Real in this environment: `auth.users`, `auth.uid()`, the `anon` /
`authenticated` / `service_role` roles, `pgcrypto`, `vector`, `pg_trgm`.

**Two gaps stood up by hand.** Neither is a migration defect; both are things a
hosted project's *services* create rather than the database image:

- `storage.buckets` and `storage.objects` — created by storage-api at runtime.
  `0010`, `0012` and `0015` need them.
- `auth.users.phone` — the image ships a pre-phone GoTrue schema. `0033` needs
  it.

## Lanes executed — all green

| Lane | What it proves |
|---|---|
| **A** | `0001`→`0048` from empty. Every semantic migration applied **and immediately replayed**. All six contracts pass in staged order. `0048` applies and replays. Contract 006 passes both before and after `0048`. |
| **B** | Calendar upgrade fixture: `0042`–`0045`, load `fixtures/0046_calendar_upgrade_fixture.sql`, apply+replay `0046`, contract passes. Then `0047` and `0048` on that populated state. |
| **C** | Surface-fact fixture: `0042`–`0046`, load `fixtures/0047_surface_fact_upgrade_fixture.sql`, apply+replay `0047`, contract passes. Then `0048` on that populated state. |

**Contracts must run in staged order.** Running them all at the end fails two of
them, and neither failure is real: `0044_integrity_contract` asserts the
pre-`0045` surface whitelist, and `0045_product_surfaces_contract` asserts a
`worker_jobs` constraint that `0046` deliberately replaces. Each contract tests
the state at *its own* migration.

## Behaviour confirmed, not just structure

- A `user` record stores inside an `apple_music` batch with both provenances
  distinct — **structurally impossible before `0048`**.
- That pair is refused until `connector_record_source_matrix` allows it.
- Connector provenance is append-only.
- A legacy backfill cannot assert a complete full snapshot.
- The emergency kill switch takes an enabled flag from true to false.
- **Zero** source-coupled run foreign keys remain in `semantic_private`.

## The `private` grants check

`0042`'s header prescribes it, and "an adapted grant broadens access" is the
integration plan's named deployment-failure condition. Measured before and after
`0048`: the app's `private` schema ACLs are **byte-identical**, with `postgres`
the only grantee on `push_config`, `collaborators`, `notify` and the schema
itself. `anon`, `authenticated` and `service_role` all have `usage = false`.

## Drift between the files and production — measured, one finding

The concern that motivated a production-clone lane is that 41 migrations were
applied to production **by hand, with no ledger**, so the files might not
describe what is actually there. Measured against the live project, read-only:

- **126 `public` columns across 17 tables: identical.** Same names, types and
  nullability, no exceptions.
- **117 objects in production against 116 built from the files**, comparing
  constraints, policies, functions, triggers and views. Everything matches
  except one.

**The single difference is `public.rls_auto_enable()`**, which no migration
creates. It is a Supabase *platform* feature — a `security definer` event
trigger named `ensure_rls` that enables row-level security automatically on any
new table created in `public`. It came from the dashboard, not the repository.

Impact on this work: **none.** Its enforced list is `public` alone, and
`0042`–`0048` create no table in `public` — every one goes to
`semantic_private` or `ontology`. But it is a real behavioural difference
between a local replay and production, and it matters the moment a future
migration adds a `public` table: production will silently enable RLS on it and a
local replay will not.

Two things follow. It should be **captured in a migration** so the schema is
reproducible from the repository rather than partly from dashboard state. And
it is worth knowing it is one of nine `security definer` functions in `public`
reachable at `/rest/v1/rpc/` by `anon` — pre-existing, unrelated to the semantic
work, and noted in the plan as its own small migration.

## Not covered here

`006`'s own header requires the finalizer and the exposure/revocation races to
be run **from two independent sessions at READ COMMITTED**. Nothing calls those
functions yet, so it is Phase 5 work — but it is a release gate.
`tools/chat_e2e.py` is the pattern to extend.

Nothing here has been applied to the production project.
