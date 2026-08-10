# Validation record — v0.3.1

This record separates checks executed against the package from work that still
requires native Supabase and product integration. The authoritative behavior
and status map are in [`ENGINEERING_SPEC.md`](ENGINEERING_SPEC.md).

## Reviewed Written baseline

Repository-specific conclusions in this record are pinned to Written commit
`8203353532dffd5f608df92861fd8a631dc7b7d4`, whose migration head is `0041`.
The review found the existing `DistilledRecord` ingestion path, flat Swift
ontology, client-written `discovery_cards`, Memories surfaces, and
`seed_icebreaker()` RPC. Those are **present legacy seams to adapt or replace**,
not missing greenfield components. No adapted Written migration numbered
`0042` or later has been applied by this package validation.

## Python

Validated with Python 3.12:

```bash
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=src \
  WRITTEN_REPOSITORY_PATH=/path/to/pinned/Written \
  python -m unittest discover -s tests -v
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=src \
  python -m written_ontology.cli demo
```

`WRITTEN_REPOSITORY_PATH` pointed to the reviewed commit named above. Result:
**244/244 tests passed**, including **14/14 HealthKit tests** and the pinned
repository manifest check. If that variable is omitted, the manifest check is
the sole intentional skip. Coverage
includes graph/version mechanics,
adapter and safety gates, fail-closed mapping, missing-aware fusion,
source-volume saturation, feedback and suppression, Calendar classification
and journey reconstruction, typed bookings, YouTube channel roles and fusion
gates, recency, conserved addition granularity, Memories, directional dyads,
bios, icebreakers, surface permissions, HealthKit closed-contract ingestion,
fitness abstention/thresholds and purpose grants, all eleven closed job payload
contracts, and CSV/SQL seed consistency. The seed auditor proves exact parity
for 45 concepts, 42 aliases, and 37 edges and identifies SQL-only catalogs
explicitly.

The deterministic demo produced one reviewable three-source cultural-affinity
candidate, no identity assertion, one saturated music lineage, and a
suppression that remained effective after recomputation. It is a mechanics
demo, not a calibrated model result.

The current aggregate-only export adapter result is:

| Measure | Result |
|---|---:|
| Input rows | 2,539 |
| Semantic observations | 1,830 |
| Music observations / lineages | 1,313 / 731 |
| YouTube observations / lineages | 508 / 508 |
| Calendar observations / private lineages | 9 / 5 |
| Private Health records retained / typed | 389 / 389 |
| Health coverage class | `aggregate_only` |
| Fitness-habit candidates | 0 |

The nine Calendar observations comprise eight mirrored flight rows collapsed
to four canonical legs plus one typed booked activity. They reconstruct one
round trip and produce zero recurrence or possible-base candidates. Eight
explicit profile facts, one location fact, and one connector-state fact route
outside behavioral ontology evidence. No raw user-export Calendar title,
route, activity, airport, booking, contact, or date appears in this record or
the package; all packaged fixtures are synthetic.

The 389 Health records comprise 365 daily activity summaries and one 24-bin
hourly activity distribution. They contain no structured workout or sleep
sessions. They are therefore retained as private quantitative inputs but do
not clear an exercise-type or daypart threshold. Sleep would remain typed-private
coverage even if present; v0.3.1 has no sleep-routine promotion threshold. The
exact result is `aggregate_only` coverage and zero fitness-habit candidates;
this is abstention for insufficient modality, not a recommendation to remove
HealthKit. Health records and any future workout-derived candidates remain
unavailable to online resolution and global mining and are usable only under the
`fitness_connection` purpose and its separate grants.

Calendar has the same capture-versus-promotion distinction. A source connector
may retain a complete event privately for sync and local classification, while
only nine sanitized, allowlisted observations in five lineages are eligible for
semantic processing in this export. The remaining captured events are not
generic ontology inputs. Generic source-row mapping is fully closed for Calendar
and HealthKit: Calendar uses current typed candidates, while HealthKit admits
only an exact controlled workout-candidate projection. Raw aggregates and
typed-private sleep remain coverage-only and never map.

## Standalone reference SQL

The current PGlite matrix passes three independent paths through **standalone
reference migrations 001–006**. The clean 001–006/replay path was:

1. migrations 001–003;
2. contracts 001–003 while their pre-004 surface whitelist still applied;
3. migration 004, immediate replay of 004, and contract 004;
4. migration 005, immediate replay of 005, and contract 005; and
5. migration 006, immediate replay of 006, and contract 006.

The persisted reference 004→005/replay path was:

1. migrations 001–004;
2. `sql/tests/fixtures/004_calendar_upgrade_fixture.sql`, which persists
   synthetic legacy Calendar classification, generic mapping, typed booking,
   and Memories state;
3. migration 005 and immediate replay of 005;
4. `sql/tests/005_calendar_upgrade_contract.sql`; and
5. migration 006, immediate replay of 006, and
   `sql/tests/006_current_state_and_surface_hardening_contract.sql`.

The fixture-backed contract proves that the standalone reference replay bumps
the synthetic legacy user exactly once, removes legacy Memories presentation rows, retains but canonically
downgrades the typed booking candidate, leaves its backfilled classification
ineligible, and queues exactly one classification and one recompute job.

This fixture is not Written migration `0004` or `0005`, and this path does not
exercise an upgrade of the reviewed app from head `0041`.

The persisted reference 005→006 surface-fact path also passed:

1. migrations 001–005;
2. `sql/tests/fixtures/005_surface_fact_upgrade_fixture.sql`, which persists a
   current pre-006 inferred score, three pre-attestation surface facts, a ready
   bio, and an unexposed ready icebreaker;
3. migration 006 and immediate replay of 006; and
4. `sql/tests/006_surface_fact_upgrade_contract.sql`.

That contract proves the historical current-score pointer and audit links are
preserved, while every pre-006 fact lacking an exact recorded score/revision
attestation is retired with naming/explanation disabled rather than assigned
fabricated provenance. The linked bio and unexposed icebreaker become stale,
and the stale frame cannot cross first exposure.

The harness loaded vector/trigram support, used a minimal Supabase auth-schema
shim, and replaced unavailable pgcrypto extension setup with the runtime's UUID
primitive. Reference contract 004 exercised source-policy parity, the allowlist-first
Calendar mapping guard that existed at the migration-004 boundary, versioned
recency, JSON firewalls, YouTube approval and
fusion gates, keyed journey lineage, typed bookings, recurrence floors,
surface permissions, revision checks, and default-deny RLS.

Reference contract 005 exercised the encrypted/blob raw-vault shapes, lifecycle and
purpose rules, the superseding generic Calendar-mapping prohibition,
current typed-candidate-only promotion, retained legacy typed rows made
non-current and ineligible by revision bump with reclassification queued,
canonical server-controlled Calendar labels, exact Calendar/HealthKit
observation projections, all eleven exact SQL worker control-message schemas,
closed queue result/error/token fields, destructive content-free remediation
of invalid legacy queue rows,
raw-HealthKit mapping prohibition, typed-private sleep with semantic promotion
disabled, fitness builder/snapshot/candidate/support integrity, non-launderable
provenance, independent matching/bio/icebreaker grants, bilateral fitness dyads,
grant narrowing/revocation, first-exposure icebreaker checks,
exposed-frame immutability, RLS, ACLs, and service-only functions. This is
package validation, not evidence of deployment on native Supabase/PostgreSQL.

Reference migration
[`006_current_state_and_surface_hardening.sql`](../sql/006_current_state_and_surface_hardening.sql)
and its
[`006_current_state_and_surface_hardening_contract.sql`](../sql/tests/006_current_state_and_surface_hardening_contract.sql)
passed in the clean and Calendar-fixture PGlite lanes for v0.3.1. It covers
per-scope source heads, disjoint/overlapping scope order, complete/partial/
truncated/delta membership, explicit provider tombstones, fixed-path
service-only finalize/fail transitions, idempotent retry, out-of-order
finalization, rejection of late raw/observation/membership appends, and
transactional rollback. It also covers exact score/revision
surface-fact binding, permission narrowing/deletion, immutable contiguous match
epochs, one active match per unordered pair, terminal revocation, first
exposure and immutable exposed history, plus RLS/ACL boundaries. Finalized
partial, truncated, and delta scopes may affirm or update seen items, while
only a finalized complete full snapshot may infer absence from omission.

The separate persisted surface-fact contract named above passed after 006
replay. Together, the three lanes establish package migration behavior; none
executes the Written app's migration history.

This is still package-harness validation, not native deployment proof. Native
PostgreSQL/Supabase must rerun 001–006 with two independent sessions for
finalization, permission narrowing, match revocation, and first-exposure races.

The standalone namespace remains `001`–`006` and uses `private.*`. Written must
adapt those migrations as app-native `0042+`, translating ontology internals
to `semantic_private.*` so the app's existing unrelated `private` schema is not
silently repurposed. Passing the standalone path cannot close that integration
gate.

## Remaining deployment validation

Before production:

1. run standalone reference migrations 001–006 and their contracts on a
   disposable native Supabase project, including replay, extension placement,
   RLS, authenticated two-user behavior, account deletion, and the required
   two-session races;
2. create adapted, app-native migrations beginning at `0042`, use
   `semantic_private.*`, and prove both clean installation and the real
   `0001`–`0041` to `0042+` upgrade with production-like data. The Written
   upgrade remains an integration gate until these migrations exist and pass;
3. implement production repositories and register idempotent handlers for all
   eleven typed jobs, then test lease loss, retry, dead-letter, and revision
   races;
4. replace packed export fields with typed connector payloads and maintain
   licensed/versioned airport, carrier, event, attraction, dining, and vendor
   catalogs;
5. obtain written approval for the exact YouTube policy before enabling any
   default-false run gate;
6. adapt or replace the present Memories and discovery surfaces and expose
   narrowly scoped, server-owned APIs. Prefer an audited exposed `api` schema
   selected with Supabase profile headers; if public wrappers are required,
   keep them minimal, invoker-safe, and explicitly ACL-tested;
7. use and test the deterministic versioned renderer so ready text cannot be
   supplied or altered by a client;
8. provision a managed KMS/HSM envelope-encryption path, separate key-unwrap
   authority from ordinary database access, audit decrypts, exercise rotation,
   and prove ciphertext/key destruction on deletion and retention expiry;
9. validate native HealthKit permission denial and revocation, private typed
   ingestion, versioned habit thresholds, both-user fitness grants, surface
   grants, data minimization, and purpose-restricted deletion/invalidation;
   this validation can support, but cannot guarantee, App Review approval; and
10. implement and test a scheduled retention worker that expires and purges raw
   vault payloads at `retained_until`. The schema validates the timestamp and
   grant revocation purges Health ciphertext, but it is not an automatic TTL
   scheduler; and
11. execute an additive rollout: dual-write with divergence alarms, shadow
   recomputation, legacy-state backfill/reconciliation, read canaries, and only
   then cut over writes and reads. Keep ingestion, dual-write, shadow,
   Memories, bio, icebreaker, and fitness flags independent. Rollback must
   disable exposure and return safely to legacy reads without reversing schema
   or replaying private content; a privacy kill switch must revoke semantic
   reads and stop derived work while deletion/invalidation drains.

The standalone package intentionally exposes no cross-user client RPC. The
reviewed Written app does contain present legacy cross-user/card paths; those
paths must not be mistaken for the new server-owned contract or left active
past cutover without equivalent authorization and revision checks. The
package's queue runner demonstrates queue mechanics, but product effects do not exist until handlers
and repositories are registered. Production scheduling must also designate an
authoritative `run_purpose` when multiple model configurations could finalize
against one unchanged user revision.
