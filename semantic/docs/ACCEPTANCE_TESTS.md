# v0.3.1 acceptance gates

Use this checklist after reading
[`ENGINEERING_SPEC.md`](ENGINEERING_SPEC.md). Passing the package tests proves
the deterministic decision cores and schema contracts exercised here; it does
not prove that production handlers, iOS flows, cross-user RPCs, or native
Supabase deployment exist.

It also does not prove integration with `Shinghei98/Written` commit
`8203353532dffd5f608df92861fd8a631dc7b7d4`/migration head 0041. Reference SQL
001–006 are not app migration numbers; the app upgrade begins at 0042+ and uses
`semantic_private` in place of reference `private`.

## Package automation

Run the dependency-free Python suite:

```bash
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=src \
  python -m unittest discover -s tests -v
```

The current package baseline is **244/244 tests passing** when
`WRITTEN_REPOSITORY_PATH` points to the pinned Written checkout, including
**14/14 HealthKit tests**. Without that environment variable, the one checkout
manifest test is intentionally skipped.

The suite must cover these core contracts:

- repeated observations saturate within a content lineage, and one
  cross-posted item cannot create source breadth;
- missing sources do not become negative evidence;
- ambiguous, folded, related, inactive, incompatible, and sensitive mappings
  fail closed;
- weak evidence cannot fire a cultural-affinity motif, and online candidates
  cannot directly become assertions;
- one-tap removal has no reason field, creates no global semantic negative,
  and survives recomputation;
- Health/HealthKit/Apple Health/Motion aliases canonicalize to one private
  source; user-authorized rows may be retained in the encrypted private vault,
  but only valid daily, hourly, workout, and sleep contracts become typed
  quantitative records, while malformed/unknown rows fail closed at that
  feature boundary;
- daily/hourly aggregates alone return `aggregate_only` coverage and zero
  fitness-habit candidates; no number of steps or hourly bins can invent a
  sport or workout type;
- duplicate hourly bins and incoherent complete share distributions remain
  raw-vault-only and do not become typed timing features;
- the current export result is exactly 389 private Health records retained and
  typed, `aggregate_only` coverage, and zero fitness-habit candidates;
- duplicate workouts cannot satisfy recurrence; a workout routine or daypart
  appears only after its respective 4-in-42-days/3-weeks or
  6-and-70%-across-3-weeks threshold;
- valid sleep sessions may produce only private `sleep_typed`/`mixed` coverage;
  even repeated, stable sleep records cannot create a sleep-schedule or other
  semantic candidate, matching input, name, explanation, or public surface;
- HealthKit raw and derived data never call online providers, enter global term
  mining, generic embeddings, population factors, advertising, or general
  desirability scoring;
- a HealthKit-derived fact is selectable only for `fitness_connection` under
  active user grants; general-social matching rejects it, both users must opt
  in for Health-based dyadic comparison, bio/icebreaker naming and explanation
  default off, and confirmation cannot broaden the purpose;
- explicit profile, location, and connector state route outside behavioral
  ontology evidence;
- YouTube stable channel identity survives title changes;
- official creator, publisher, topical, fan/repost, and unknown roles remain
  distinct, and only an exact reviewed active resolution can transfer a
  represented concept;
- one liked video's content/topic evidence is stronger than its channel or
  represented-creator evidence, while a subscription can carry stronger
  creator intent;
- YouTube evidence with `cross_source_fusion_allowed=false` may retain its
  source-local score but cannot add breadth/synergy or fire convergence;
- recency uses versioned domain/source/action rules, keeps temporal weight
  separate from timestamp quality, pins one run clock, and handles scheduled
  event anticipation and post-event decay without a universal half-life;
- Calendar hard exclusions cover birthdays, medical events,
  funerals/memorials, friends' events, private social events, work/school
  meetings, cancelled entries, third-party ownership/declined attendance, and
  unknown text;
- one strong structured ticket creates a private typed scheduled/booked candidate
  without a second app or other orthogonal proof;
- that one ticket does not prove attendance, preference, completed travel,
  recurrence, hometown, or residence;
- recurrence counts distinct journeys, not mirrored rows, flight legs, or
  multiple reservations within one trip;
- transit locations receive no destination vote, and one round trip cannot
  become recurrence or hometown;
- additions preserve predicate and free text, propagate only upward with a
  conserved evidence-family mass, and never create children;
- Memories group by semantic hierarchy without turning headings into editable
  assertions;
- dyadic transport distinguishes exact, hierarchical, curated, and
  embedding-only paths and reports comparability separately from proximity;
- a bio contains only true subject facts, with at most one viewer-conditioned
  selection;
- icebreaker wording is licensed by both typed paths, requires surface
  permission on both sides, and never receives raw private Calendar evidence.
- the closed registry accepts exactly its registered typed job payloads;
  malformed or private payloads fail before dispatch to a registered handler,
  and any fitness-derivation job carries only durable IDs, revision, model, and
  policy version rather than Health values;
- the CSV/SQL seed auditor proves exact parity for 45 concepts, 42 aliases,
  and 37 edges, while documenting the SQL-only catalogs separately.

## SQL contract

The first three SQL contracts assert the pre-migration-004 surface whitelist,
so execute them before reference migration 004:

```bash
psql "$DATABASE_URL" -f sql/001_schema.sql
psql "$DATABASE_URL" -f sql/002_rls_and_rpc.sql
psql "$DATABASE_URL" -f sql/003_seed.sql
psql "$DATABASE_URL" -f sql/tests/001_version_rollover.sql
psql "$DATABASE_URL" -f sql/tests/002_integrity_contract.sql
psql "$DATABASE_URL" -f sql/tests/003_exact_revision_finalization.sql
psql "$DATABASE_URL" -f sql/004_product_surfaces.sql
psql "$DATABASE_URL" -f sql/tests/004_product_surfaces_contract.sql
```

Then prove replay safety and rerun the base product-surface contract:

```bash
psql "$DATABASE_URL" -f sql/004_product_surfaces.sql
psql "$DATABASE_URL" -f sql/tests/004_product_surfaces_contract.sql
```

After the validated base sequence, apply and replay the private-ingestion and
fitness extension:

```bash
psql "$DATABASE_URL" -f sql/005_private_ingestion_and_fitness.sql
psql "$DATABASE_URL" -f sql/005_private_ingestion_and_fitness.sql
psql "$DATABASE_URL" -f sql/tests/005_private_ingestion_and_fitness_contract.sql
psql "$DATABASE_URL" -f sql/006_current_state_and_surface_hardening.sql
psql "$DATABASE_URL" -f sql/006_current_state_and_surface_hardening.sql
psql "$DATABASE_URL" -f sql/tests/006_current_state_and_surface_hardening_contract.sql
```

The recorded validation state for the standalone chain is in `VALIDATION.md`.
The complete three-lane PGlite matrix, including reference 006 replay, its main
contract, and the persisted surface-fact upgrade contract, passes. Repeat the
sequences and specified two-session races on disposable native
Supabase/PostgreSQL projects before release. Neither package execution nor
native reference execution proves the adapted Written upgrade.

Also run the persisted Calendar upgrade path in a separate disposable database:

```bash
psql "$DATABASE_URL" -f sql/001_schema.sql
psql "$DATABASE_URL" -f sql/002_rls_and_rpc.sql
psql "$DATABASE_URL" -f sql/003_seed.sql
psql "$DATABASE_URL" -f sql/004_product_surfaces.sql
psql "$DATABASE_URL" -f sql/tests/fixtures/004_calendar_upgrade_fixture.sql
psql "$DATABASE_URL" -f sql/005_private_ingestion_and_fitness.sql
psql "$DATABASE_URL" -f sql/005_private_ingestion_and_fitness.sql
psql "$DATABASE_URL" -f sql/tests/005_calendar_upgrade_contract.sql
psql "$DATABASE_URL" -f sql/006_current_state_and_surface_hardening.sql
psql "$DATABASE_URL" -f sql/006_current_state_and_surface_hardening.sql
psql "$DATABASE_URL" -f sql/tests/006_current_state_and_surface_hardening_contract.sql
```

The Calendar fixture must prove internal reference 004→005 replay, not merely
empty-schema
idempotence: one revision bump, removal of legacy Memories presentation rows,
retention plus canonical downgrade of the legacy typed booking candidate,
continued ineligibility of its backfilled classification, and exactly one
classification and one recompute job.

Also run the persisted surface-fact 005→006 upgrade lane in a third disposable
database:

```bash
psql "$DATABASE_URL" -f sql/001_schema.sql
psql "$DATABASE_URL" -f sql/002_rls_and_rpc.sql
psql "$DATABASE_URL" -f sql/003_seed.sql
psql "$DATABASE_URL" -f sql/004_product_surfaces.sql
psql "$DATABASE_URL" -f sql/005_private_ingestion_and_fitness.sql
psql "$DATABASE_URL" -f sql/tests/fixtures/005_surface_fact_upgrade_fixture.sql
psql "$DATABASE_URL" -f sql/006_current_state_and_surface_hardening.sql
psql "$DATABASE_URL" -f sql/006_current_state_and_surface_hardening.sql
psql "$DATABASE_URL" -f sql/tests/006_surface_fact_upgrade_contract.sql
```

This PGlite lane passes. It must prove that a genuinely current pre-006 score
pointer is preserved for audit, but every pre-006 fact without an exact recorded
score/revision attestation is retired with naming/explanation disabled rather
than assigned fabricated provenance. Linked ready bios and unexposed ready
icebreakers become stale without losing audit links; the stale icebreaker cannot
cross first exposure.

Reference migration/test 004 must prove:

- exact source-policy parity with the deterministic adapters, including the
  high-signal Calendar classifier output and zero-weight rejected actions;
- bounded mapping agreement, evidence quality, relation-specific evidence
  weights, and complete versioned recency provenance pinned to the run clock;
- YouTube role/relation constraints, weak one-video creator transfer, and
  default-false per-run gates tied to a current durable approval;
- the historical migration-004 allowlist-only Calendar mapping behavior,
  canonical segment/journey HMACs, explicit primary/mirror sources, optional
  origin, and terminal-only scheduled travel;
- normalized `booked_activity_at`, `booked_event`, and `scheduled_dining`
  candidates plus Memories foreign keys;
- the private 2-journey/2-month/90-day recurrence floor, the stronger public
  3-journey/2-complete-round-trip/180-day state, and forbidden inferred
  `hometown`/`lives_in`;
- separate selection, naming, and explanation permissions for Memories,
  matching, bio, and icebreaker;
- no public/dyadic naming or explanation of unconfirmed Calendar evidence;
- recursive JSON key, depth, string, size, and root-allowlist firewalls across
  classification, derivation, and presentation payloads;
- Memories, dyad, bio, and icebreaker objects require current revisions;
- ready icebreakers require active match authorization and validated facts;
- migration-004 tables are default-deny under RLS and explicitly granted only
  to the service role;
- the worker job type constraint includes `classify_calendar`,
  `resolve_youtube_channel`, `build_memories`, `compute_dyad`, `render_bio`,
  and `render_icebreaker`.

The HealthKit extension must additionally prove:

- canonical aliasing without duplicate evidence, encrypted private capture,
  and typed parsing for the four closed row contracts;
- the worker constraint and closed payload registry include
  `derive_fitness_habits`, whose payload contains only durable IDs, revision,
  model ID, and policy version;
- raw HealthKit rows cannot enter ordinary observation mapping, online/global
  mining, or generic cross-source fusion;
- generic source-row mapping is fully closed for Calendar and HealthKit. Only a
  current typed Calendar candidate or the exact controlled workout-candidate
  projection may cross its dedicated promotion boundary; aggregates and sleep
  never enter mapping;
- reference migration 005 supersedes reference migration 004's historical allowlisted Calendar
  mapping path and rejects every Apple/Google Calendar observation from generic
  `observation_mappings`; promotion is possible only through a current typed
  travel/booking candidate;
- legacy typed Calendar rows remain stored for private audit, but revision bump
  makes them non-current and ineligible while versioned reclassification and a
  typed-candidate rebuild are pending;
- Calendar candidate and Memories labels are server-controlled and regenerated
  from exact controlled predicate templates and active ontology preferred
  labels;
  raw connector/classifier labels and client-authored display text are rejected;
- typed sleep coverage cannot create or reactivate a `sleep_schedule`
  candidate, including through the reserved ontology seed;
- each derived fitness assertion is linked to a validated, versioned habit
  candidate and retains `fitness_connection` purpose and HealthKit provenance;
- `allow_fitness_matching`, `allow_bio_naming`, and
  `allow_icebreaker_naming` are independent and default-off outside private
  review; matching grants are required from both users for a Health-based dyad,
  controlled explanation requires its additional grant, and revocation makes
  dependent
  snapshots, dyads, bios, and unexposed icebreakers stale without rewriting an
  exposed historical message; and
- queue, candidate, mapper, and presentation payloads reject raw workout
  labels, exact sleep/workout times, routes, heart-rate/medical fields, and
  other unapproved Health values. Purpose-limited private typed records may
  retain only the structured time and duration fields needed for workout
  recurrence/daypart validation or typed-private sleep coverage.

Reference migration/test 006 must additionally prove:

- `source_state_heads` authority is per `(user, source, scope_key)`: a newer
  disjoint scope does not supersede an older one, while a stale overlapping
  scope makes the entire multi-scope finalization superseded without partial
  effects or orphan placeholder heads;
- finalized partial, truncated, and delta scopes may affirm or update items
  they actually report, including an explicit provider-deleted item;
- only a finalized complete full snapshot can infer absence from an omitted
  item; failed runs and all other omissions preserve prior state as unknown;
- direct run-status/current-pointer updates are unavailable even to the service
  role; only fixed-path service-only finalize/fail functions may create
  receipt-idempotent terminal transitions, and terminal runs cannot be edited;
- raw-record, observation, and membership staging serializes with finalization,
  so no late append can enter a terminal run or escape its stored receipt;
- latest-ever legacy rows cannot silently become current evidence;
- current surface facts require exact current-revision attestation and, for
  inferred facts, the exact current score version; legacy pre-attestation facts
  retire and linked unexposed products stale rather than acquiring invented
  provenance;
- match authorization participants and epoch identity are immutable, epoch
  numbers are contiguous, only one epoch per product match and one match ID per
  unordered user pair may be active, and terminal epochs cannot reactivate;
- first exposure and revocation lock the same authorization row, are idempotent
  under retry, reject stale/unexposed output after revocation, and preserve
  exposed history;
- replay is idempotent and cannot duplicate a revision bump, tombstone,
  invalidation, or exposure; and
- all new current-state and surface-hardening objects remain default-deny under
  RLS/ACLs with only exact service/RPC grants.

## Integration-required gates

Before production, add environment-specific tests for:

1. concurrent feedback versus a stale semantic or surface run;
2. authenticated owner RLS behavior for two users and denial of unapproved
   cross-user reads;
3. match authorization, revocation, and either-user revision invalidation,
   including atomic first-exposure rejection for stale frames and immutability
   of already exposed historical messages;
4. account deletion across observations, terms, assertions, Calendar/travel,
   Memories, dyads, feedback, and suppressions;
5. worker crash/lease recovery, idempotent handler effects, and sanitized JSON
   results/errors;
6. typed connector payload validation and rejection of raw Calendar details
   from feature/presentation JSON;
7. end-to-end enforcement of the private 2-journey/2-month/90-day floor and
   public 3-journey/2-complete-round-trip/180-day gate, including explicit
   confirmation and permission;
8. a real, written YouTube capability approval and production policy rollout;
9. seed parity, migration replay, and extension placement on native Supabase;
10. exposure-to-feedback and deterministic-renderer presentation fidelity;
11. HealthKit authorization denial/revocation, purpose-grant enforcement,
    sparse/aggregate-only abstention, data minimization, and the shipped
    fitness-service disclosure; and
12. scheduled raw-vault expiry at `retained_until`, including ciphertext/blob
    purge, retry/idempotency, and account/grant deletion races. The schema
    validates retention state but is not an automatic TTL scheduler;
13. adapted app migrations using `semantic_private`, including clean 0042+
    install and a real 0001–0041 → 0042+ upgrade on native Supabase, with no
    object, grant, default-privilege, trigger, or extension regression in the
    existing app `private`, public chat, push, auth, or profile paths;
14. typed dual-write correlation and shadow reconciliation by completed run,
    proving record source cannot be restamped by an outer connector batch and
    that legacy agreement is never used as truth;
15. conservative `legacy_unverified` backfill, fresh-distillation supersession,
    and no automatic promotion from `summary_distilled_records`, legacy
    `health_sports`, discovery JSON, bans, or conversation themes;
16. an audited `api` PostgREST profile/header path, or separately audited
    minimal public wrappers, while `semantic_private`, app `private`, and
    `ontology` remain unexposed;
17. KMS/HSM-backed envelope encryption, separately keyed lineage HMACs, key
    rotation, audited narrow worker decrypt, crypto-erasure, backup/object-store
    deletion, and zero raw Calendar/HealthKit leakage through logs, traces,
    analytics, queues, or durable errors;
18. server-owned discovery/profile RPCs enforcing mutual block/removal,
    eligibility, rate limit, current revisions, purpose/surface grants, and
    representative p95 latency;
19. independent runtime flags and a server-side privacy kill-switch drill. Safe
    rollback must omit a clause rather than re-enable generic Calendar/Health,
    client-authored semantics, or the legacy overlap icebreaker; and
20. minimum-client enforcement, forward-only legacy revocation, and a bounded
    read-only rollback/audit window before any legacy data removal.

Passing these gates does not guarantee App Review approval.

The queue runner alone does not satisfy these gates. Every registered job type
requires production repositories and registered handlers. New client RPCs for
directional bio and matched-chat icebreakers require an explicit threat model
and authorization tests.

## Schema-ready, integration-required

Reference migration 004 implements the base product-surface persistence and historical
allowlisted Calendar-mapping defense. Reference migration 005 supersedes that mapping
path, adds the encrypted raw-source vault, HealthKit fitness
snapshots/candidates/provenance, purpose grants, and an eleventh typed job. Both
the clean 001–006/replay baseline, fixture-backed internal 004→005 path, and
persisted 005→006 surface-fact path are described in `VALIDATION.md`. Reference
006 adds current-state and surface hardening; both its main PGlite contract and
persisted fact-upgrade contract pass. Native deployment,
cross-user RPCs, product repositories, connector catalogs, registered handlers,
iOS editing flows, and external YouTube approval remain integration-required.
Keep those paths disabled until their integration gates pass.
`calendar_event_classifications.feature_snapshot` is bounded classifier
metadata, not a substitute for the normalized candidate tables.

The actual Written upgrade is a separate integration gate. No adapted 0042+
migrations are included merely because the standalone 001–006 reference chain
exists, and no reference validation proves upgrade compatibility with app
migrations 0001–0041.

## Cohort gate

Validate by user, not observation. The initial report should include precision
and abstention by source and role, correction/suppression rates,
leave-one-source-out stability, Calendar parse precision, journey reconstruction
errors, channel-role resolution precision, and the number of users with at
least three usable independence groups. The historical aggregate export is a
mechanics fixture, not a multi-user validation cohort. HealthKit reporting must
additionally separate retained raw records, successfully typed records,
coverage class, candidate count, and candidate acceptance by modality; row
count is not semantic coverage.
