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
> Latest run: **12 passed, 0 failed.**

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
| **A** | `0001`→`0053` from empty. Every semantic migration applied **and immediately replayed**. All six contracts pass in staged order. Contract 006 passes both before and after `0048`. `0048`–`0051` each apply and replay. |
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
- `0050`'s key registry, against a real chain: a second *active* key for one user
  is refused by the partial unique index; retiring the first then admitting a
  second works, which is rotation; a malformed KMS ARN is refused; and
  **`delete from auth.users` leaves zero key rows** — crypto-erasure with
  nothing to remember to call.
- `0051`'s own guard, which is the test: it reads both key-version patterns out
  of `pg_get_constraintdef` and raises if they differ, so an apply failure *is*
  the failing assertion and there is no separate contract file. Proven to bite
  by perturbing `0046`'s side in a throwaway container — it refused and named
  both patterns.

## The ingestion path, end to end

`0052`'s function is the first thing that writes the vault, and it was run
rather than read. Against a full chain in a throwaway container, as
`semantic_ingestor` itself:

- A mixed batch stores both rows, and **their provenance stays distinct**: the
  subscription row is filed under record source `user` with connector
  `apple_music`, which was structurally impossible before `0048` and had never
  been exercised through an actual ingestion call until now.
- The retry is idempotent — `{"received": 1, "stored": 0, "duplicates": 1}`,
  inferred from the partial unique index on active rows.
- A run id belonging to another user is refused, which is what makes a
  client-minted id safe.
- An undeclared connector/record pair is still refused by name
  (`connector spotify may not deliver user records`).
- **The role cannot read what it just wrote**: `permission denied for table
  raw_source_records`.

`0053` replaces that function to carry the call's wrapped data key, and was
run the same way:

- The key and the rows arrive in one statement — `key_recorded: true`.
- A second call **retires** the first key and records its own, and both rows
  still name a key that exists. That is the invariant that matters: retiring is
  not deleting, so ciphertext under an old version still decrypts.
- Reusing a version with a *different* wrapped key is **refused by name**. A
  wrong key does not announce itself, so this is the one failure that must never
  be papered over.
- An empty batch records no key at all — otherwise a probe call leaves a key
  protecting nothing, kept for the life of the account because nothing
  downstream can prove it unused.

**And the replay caught a real defect in it.** The first draft used `create
function` after the `drop`, which applies once and fails the second time with
`function ... already exists with same argument types`. `create or replace` is
correct *because* the drop removed the old signature — the drop handles the
parameter change, the replace handles being run twice, and neither substitutes
for the other.

**One of those was a product bug, found by running it.**
`AppleMusicDistiller` emits a `user` row for subscription state during an Apple
Music run, and the matrix held identity pairs only — so that record was refused
at ingestion and would simply never have arrived. `0052` declares the pair with
its rationale.

## The run lifecycle, on a real device

`0055`/`0056` on a real Apple Music distillation, 2026-08-11. The run finalized:
**9 scopes, 9 heads, 1,224 run items, 1,224 `current_source_items`, 1 worker
job enqueued** — the last being what Phase 2 consumes.

**The number that proves the design is 1,224 against 1,225 captured.**

| | captured | promoted |
|---|---|---|
| `apple_music/*`, nine data types | 1,224 | 1,224 |
| `user/apple_music_subscription` | 1 | **0** |

Every action-bearing pair promoted one for one. The subscription row carries no
action, so it belongs to no scope, gets no run item and never becomes evidence —
while still being captured and encrypted. *Capture broadly, promote narrowly*,
as an integer rather than a paragraph.

Behaviour confirmed against a throwaway chain beforehand: a two-batch run
finalizes with a receipt reading `succeeded` / revision 1 / changed 2; a re-run
of identical content finalizes again with `state_changed: false` and
`changed_item_count: 0`; and **a `complete` scope whose count is wrong is
refused by name**, rolling the whole transaction back — which is §10's "failed
runs change no current source state", seen rather than assumed.

## HealthKit, once somebody consented

A real Lifestyle connection on 2026-08-11, through `FitnessPurposePrimer` and
then HealthKit's own sheet:

| | |
|---|---|
| Grants | 1 — `active`, `fitness-v1`, matching **false**, bio **false** |
| Vault rows | 390 — `activity_day=366`, `activity_hour=24` |
| Legacy, same types | **366 / 24** — exact match |
| `consent_purpose` | `fitness_connection`, derived server-side |
| **Observations** | **0** |
| Scopes | both `partial` |

**The 24 is the design showing up in a number.** `activity_hour` is twenty-four
rows for the whole year rather than 8,760 — the distiller buckets before it
makes a record, because the question is which hours somebody moves in and not
what they did at 3pm last March. A year of Health is 390 rows against Apple
Music's 1,225.

**No `workout` rows, and that is the already-recorded finding rather than a
new fault:** steps come from the iPhone's motion coprocessor and arrive for
everyone, while `HKWorkout` needs something recording sessions, and no test
device has an Apple Watch. The legacy path agrees exactly, which is what makes
it an absence rather than a loss.

**`biological_sex` never reached the vault**, as it never reaches Postgres:
`SyncService.localOnlyTypes` refuses it at the wire and `dualWriteToVault` asks
the same function rather than reimplementing the rule. Refusing to send and
refusing to forget are one decision made in one place.

**Zero observations**, like Calendar: the sanitised fitness shape is a
classifier's output and §7 permits only the current one, which does not exist.
§10's *"aggregate-only HealthKit produces zero fitness claims"* is met by
producing none at all.

## Calendar in the vault, describing nothing

A real Apple Calendar distillation, 2026-08-11, and every number is the designed
shape rather than an approximation of it:

| | |
|---|---|
| Vault rows | 109 — 101 `event`, 8 `calendar` |
| Legacy events, same run | **101** — exact match |
| `consent_purpose` | `calendar_distillation`, derived server-side |
| **Observations** | **0** |
| Promoted to current state | 101 events; **0 of the 8 calendars** |
| Scopes | `event:booked` and `event:entered_by_user`, both `partial` |

**Three things that only line up if the design is right.** The event count
matches the legacy path exactly. The eight `calendar` rows are captured and
promoted to nothing, because a calendar is a container and structurally not an
act. And one `data_type` produced *two* scopes — `booked` and
`entered_by_user` — which is the per-row action refinement working: a booking a
ticketing site wrote in is a different act from an entry somebody typed, and
that distinction is the reason the Calendar source exists.

**Zero observations is the point, not a shortfall.** §7 permits only the current
Calendar classifier over Calendar rows, and it does not exist yet, so the
endpoint sends no projection at all. Titles, locations and organisers sit
encrypted in the vault — 519 bytes for the sample — and contribute nothing to
any surface. That is §10's Calendar gate: *"unknown, work, social/third-party,
sensitive, generated and cancelled Calendar records can be retained but
contribute zero evidence."*

## A partial distillation, and the guard that made it survivable

Two consecutive Apple Music runs on 2026-08-11: **17:01 carried four data types,
17:08 carried all nine.** Nothing was lost in transit — the endpoint logged zero
refusals and the Lambda invocation counts match the batch counts exactly (1 and
3). The distiller returned less, which it can: its endpoints run concurrently
with one `async let` each, so a failure in the library passes leaves the catalog
ones intact and the run still reports success.

**Every scope is declared `partial`, and that is the whole reason this was
survivable.** Declaring `complete` would have let finalization expire five
entire data types — 714 items — from current state because some fetches failed.
`current_source_items` still holds all nine types and 1,427 items, and zero
scopes have ever been declared `complete`.

## The first semantic evidence, and what it cost

`0059` on a real Apple Music re-distillation, 2026-08-11. **`observations` went
from 0 to 1,212** — the first evidence this system has produced. All nine music
data types, `user/apple_music_subscription` correctly absent (no action, so no
scope, so not evidence), and every one of the 1,212 stamped onto its run item's
`observation_id`.

**The vault doubled at the same time, and that was predictable rather than
alarming.** 1,227 rows became 2,441. `record_fingerprint` is computed over the
payload, and `0059`'s deploy followed the **v2 payload wire form** — so every
item's fingerprint changed even though its content did not, and the whole
library re-stored as new rows. The append-only model behaving exactly as
designed: a changed record is a new row, and the *encoding* changed.

That is the one-time price of fixing `_0`, paid once and cheaply at 1,225 rows.
The 1,229 v1 rows carry no observations — they were captured before projection
existed and their fingerprints do not match the v2 ones. They are history, which
is what the model calls them.

**And `source_item_hmac` does not include `data_type`**, deliberately: it
identifies the *item*, so one song appearing as `library_song` and again as
`recently_played` shares a hash — 1,013 distinct items across 1,224 rows. Not a
collision. `current_source_items` keys on
`(user, source, scope_key, data_type, action_type, source_item_hmac)`, so the
same song under two actions is two pieces of current state, which is correct: it
was in the library *and* it was played.

## The iOS envelope vocabulary

`Written/Models/SemanticSource.swift` maps every `data_type` the app emits to an
action, and an action is only real if that source actually weighs it. **Asked of
the built schema, not reconstructed**: five migrations touch `action_weights`
(`0042`, `0044`, `0045`, `0046`, `0048`), so parsing SQL for the final state
would be a third copy of the thing under test. Lane A has just applied the whole
chain, so the answer is sitting in the database — 28 `(source, data_type,
action)` triples, all weighted.

**Proven to bite**, which for a check with no failing case yet is the only way
to know it works: claiming `episode` for `apple_podcasts/podcast_episode` — an
action the *`podcast`* source weighs and `apple_podcasts` does not — was refused
by name. The check is per source, which is the whole point.

The other half needs no database and is
`semantic/tests/test_ios_envelope_contract.py`: every emitted `data_type` mapped
at all, every `source:` literal resolving. Also proven by perturbation —
deleting one mapping entry failed two tests, each naming the file and the type.

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

**It is captured now, as `0049`**, so the schema is reproducible from the
repository rather than partly from dashboard state — and that migration is a
no-op against production, where the trigger already exists. Worth knowing it is
one of nine `security definer` functions in `public` reachable at
`/rest/v1/rpc/` by `anon`: pre-existing, unrelated to the semantic work, and
still open.

## Not covered here

`006`'s own header requires the finalizer and the exposure/revocation races to
be run **from two independent sessions at READ COMMITTED**. Nothing calls those
functions yet, so it is Phase 5 work — but it is a release gate.
`tools/chat_e2e.py` is the pattern to extend.

`0042`–`0051` have all since been applied to production. This file
records what the *replay* proves, which is a separate question from what is
deployed — `supabase/DEPLOY.md` is the record of that.
