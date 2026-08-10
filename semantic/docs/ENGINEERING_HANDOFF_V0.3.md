# Written semantic system v0.3.1 engineering handoff

**Audience:** iOS, backend, data, ML, privacy, product, and release engineering  
**Status:** standalone reference handoff; packaged decision cores and the full
PGlite 001–006 matrix have a tested baseline, while native deployment, adapted
Written migrations, and application wiring remain separately recorded release
gates  
**Reviewed Written baseline:** `Shinghei98/Written` commit
`8203353532dffd5f608df92861fd8a631dc7b7d4`, migration head
`0041_collaborator.sql`

## 1. Governing verdict

The governing law for v0.3.1 is:

> **Capture broadly in the user-authorized private vault; promote narrowly into
> semantic evidence; expose only purpose- and surface-authorized projections.**

Retention, classification, semantic promotion, and presentation are four
different decisions. A row may be worth retaining for sync, reclassification,
deletion, or audit while being completely ineligible for the ontology. A
classifier may read a raw record inside the private worker without copying its
raw fields into durable feature, queue, candidate, or presentation JSON.

| Layer | Permitted content | Prohibited transition |
|---|---|---|
| Private raw vault | Application ciphertext or encrypted-object reference, keyed identity, owner, consent purpose, retention and lifecycle state | Raw text or measurements becoming ontology terms merely because they were retained |
| Source classifier/builder | Ephemeral access to the raw record; closed typed output | Arbitrary title substring matching, online resolution, generic embeddings, or global mining of private input |
| Semantic candidate | Controlled predicate, concept/entity ID, bounded quality/reason codes, version and provenance; a private typed timestamp column may support recency/recurrence | Raw title, route, itinerary text, contact, booking detail, Health measurement, medical field, or exact time copied into JSON/presentation |
| Product surface | Sanitized fact selected under current user, purpose, surface, revision, and match authorization | Broad client reads, purpose laundering, or client-authored presentation facts |

This is fail-closed at the semantic boundary, not delete-by-default at the
capture boundary.

## 2. Calendar: response to the engineer

The engineer identified a real defect in the reviewed Written baseline: private Calendar rows
reached a broad title-substring ontology classifier, while exclusions were
applied only when drawing. That was fail-open inference. It allowed examples
such as another person's arrival, a medical title, or test appointments to
contribute to a semantic profile, and it became harder to defend once those
labels appeared under readable Memories headings.

The statement "the app deliberately keeps what the spec deliberately rejects"
needs one distinction:

- If **keeps** means encrypted, owner-scoped raw retention for sync and local
  reclassification, v0.3.1 permits it with consent, lifecycle, retention, and
  deletion controls.
- If **keeps** means passing the row into `Ontology.classify`, a generic mapper,
  embeddings, term mining, or a product surface, the engineer is right: that is
  incompatible with v0.3.1 and must be removed.

The implemented order is exclusion first, commercial recognition second, and
unknown-private quarantine last. It runs locally before embeddings, online
knowledge, or ontology mapping.

### Exact finalized-export disposition

The export has 106 event rows. The following partition is mutually exclusive
because classifier precedence assigns each event once:

| Disposition | Event rows |
|---|---:|
| Included sanitized semantic rows | 9 |
| Unknown / not allowlisted | 60 |
| Work / school / meeting | 18 |
| Personal or third-party | 11 |
| Sensitive | 3 |
| Cancelled | 1 |
| User removed | 4 |
| **Total** | **106** |

There are also 10 Calendar-container metadata rows. They inform subscribed,
birthday, and holiday-calendar exclusions but are not events or ontology
evidence. Thus the Calendar source has 116 rows in total, of which only 9 event
rows cross the sanitized semantic boundary.

Those 9 rows collapse to 5 evidence lineages: eight connector-mirrored flight
rows become four canonical flight-leg lineages, plus one booked-activity
lineage. Mirrors do not create additional volume, breadth, or journey votes.

The engineer's displayed gate counts are useful diagnostics, but they are not
an exclusive partition: `33 + 25 + 7 + 2 + 10 + 51 = 128`, not 106. Events can
match more than one rough category, and container metadata is a separate row
type. The engineer's conclusion of roughly ten survivors was directionally
right; the deterministic v0.3.1 result is exactly nine included rows and five
lineages.

### Calendar application rule

The connector may write the whole authorized event to the encrypted raw vault.
The private classifier may inspect it, but its durable output is a closed
projection: disposition, controlled artifact/predicate, stable keyed lineage,
reason codes, bounded quality, and version. A private typed occurrence column
may retain the timestamp needed for recency and journey reconstruction. It must
not copy raw titles, routes, exact times, contacts, organizers, meeting URLs,
booking references, or attendee details into feature snapshots, worker
payloads, logs, candidate/presentation JSON, or rendered text. Unknown events
remain raw-vault-only and emit no evidence.

Reference migration 004 historically allowed an eligible classified Calendar projection
to enter generic `observation_mappings`. Reference migration 005 supersedes that
compatibility path: every Apple/Google Calendar observation is blocked from the
generic mapper. Classifications remain metadata; Calendar semantics can be
promoted only through a current typed travel or booking candidate.

The upgrade retains legacy typed classifications and travel/booking rows for
private audit, but it rewrites their display payloads, bumps every affected user
revision, and queues versioned reclassification. Retention is not eligibility:
those legacy rows are non-current after the bump and cannot feed Memories or a
surface. A current eligible classification and rebuilt typed candidate are
required before promotion resumes.

Calendar labels are canonical and server-controlled. The server builds the
versioned display payload from the controlled predicates `Scheduled travel to`,
`Booked activity`, `Booked event`, or `Scheduled dining` plus active ontology
preferred labels. Memories derives its display label from that typed payload;
raw connector titles/locations and client-authored labels are never accepted.

## 3. Ticket and public-entity nuance

A single high-quality commercial ticket can create a private review candidate;
it does not need corroboration from another app. The strongest automatic
predicate remains the action actually evidenced:

| Artifact | Maximum automatic predicate | It does not prove |
|---|---|---|
| Airline itinerary | `scheduled_travel_to(place)` | boarding, completed travel, liking, recurrence, hometown, or residence |
| Tour or attraction ticket | `booked_activity_at(place)` | attendance or place affinity |
| Live-event ticket | `booked_event(event/topic)` | attendance or performer affinity |
| Restaurant reservation | `scheduled_dining(cuisine/place)` | attendance or cuisine preference |

The private receipt is not made public. However, when a stable vendor event ID
or an independently verified public-catalog identifier resolves a public event,
performer, venue, restaurant, or place, the sanitized candidate may retain that
public entity under the booked/scheduled predicate. Free-text title resemblance
alone is insufficient. A public entity does not make the user's association
public: unconfirmed Calendar evidence remains in private review and cannot be
named or explained in a bio or icebreaker. Stronger wording requires the
corresponding user confirmation and surface permission.

## 4. HealthKit verdict and ingestion capacity

HealthKit is no longer blanket-quarantined. It is an optional, private,
high-rigor lane whose only data-use purpose is `fitness_connection`: helping
users identify compatible exercise routines and support shared exercise or
sustained fitness habits. The service must be genuine and evident in product
copy, permission text, UI, storage, deletion, and review notes.

Approved product-policy wording:

> Written retains HealthKit as an optional, purpose-limited fitness-connection
> input. Activity and workout data help users find people with compatible
> exercise routines and support shared exercise and sustained fitness habits.
> HealthKit data are not used for advertising, general desirability scoring,
> unrelated dating profiling, external resolution, or population-model
> training. Sparse or low-modality data produce abstention. Users separately
> control fitness matching and public naming/explanation; confirmation never
> removes HealthKit provenance or its fitness-purpose restriction.

Structured sleep-session data may be retained only as typed-private coverage for
ingestion completeness and quality. V0.3.1 never promotes sleep to a semantic
candidate and never makes it eligible for matching, naming, explanation, or a
public/product surface. The reserved `routine:consistent_sleep_schedule`
ontology seed may remain for compatibility; it is not an active HealthKit
promotion path.

The adapter canonicalizes `health`, `healthkit`, `apple_health`,
`apple_healthkit`, and `motion_fitness` to `healthkit`. Broad authorized raw
capture does not broaden feature eligibility. The V1 builder accepts only four
closed contracts:

| Contract | Accepted private typed fields | Maximum semantic effect |
|---|---|---|
| `activity_day` | ISO date; bounded steps and/or active energy; optional valid first-movement time | `aggregate_only` coverage and quality; never nominates a sport |
| `activity_hour` | unique hour 0–23; bounded steps and/or share in `[0,1]`; complete 24-bin share snapshots normalize to approximately one | timing coverage; never nominates a workout |
| `workout` | allowlisted activity type; structured start; bounded duration or later end | may support that controlled activity routine |
| `sleep` / `sleep_session` | allowlisted stage; structured start and later end; bounded derived duration | private `sleep_typed`/`mixed` coverage only; never a semantic candidate |

Unsupported types and malformed or non-finite required values fail closed at
the feature boundary. Free-text workout names, routes, heart-rate fields,
diagnoses, quality labels, and other unapproved values are discarded before
candidate projection. Raw and derived HealthKit data must not be used for
external resolution, global term mining, generic embeddings, population-factor
training, advertising, general desirability, medical inference, or unrelated
dating profiling.

Generic source-row mapping is fully closed for both Calendar and HealthKit.
Calendar promotes only through current typed travel/booking candidates. Raw,
aggregate, and sleep Health rows never map; only the exact controlled projection
of a validated workout-derived candidate may cross the closed fitness promotion
boundary.

Policy `written-healthkit-fitness-v1.0.0` abstains unless one of these workout
gates is met:

- activity routine: at least 4 same-type workouts in 42 days across at least 3
  distinct ISO weeks;
- workout daypart: at least 6 workouts in 42 days, at least 70% in one coarse
  daypart, across at least 3 distinct weeks.

There is no v0.3.1 sleep-promotion threshold. Repeated or stable sleep sessions
remain typed-private coverage and the builder/SQL contract rejects a
`sleep_schedule` candidate.

Duplicate records cannot satisfy recurrence. One workout is a private completed
activity, not a claim that the user likes the activity or has an identity tied
to it. All candidates require review and retain HealthKit provenance and the
`fitness_connection` purpose after confirmation.

An active fitness-service grant permits owner-only Memories review.
`allow_fitness_matching`, `allow_bio_naming`, and
`allow_icebreaker_naming` are independent, default-off grants. Controlled
explanation requires its additional grant together with the relevant naming
grant. A HealthKit-based dyad requires active matching grants from both users; a
`general_social` run must reject the evidence.
Grant narrowing or revocation removes eligibility and invalidates dependent
unexposed output. Confirmation cannot broaden the purpose.

### Current export outcome

The current export contains 365 `activity_day` rows and 24 `activity_hour`
rows, with no structured workouts or sleep sessions:

| Result | Exact value |
|---|---:|
| Private Health rows retained | 389 |
| Successfully typed Health records | 389 |
| Coverage | `aggregate_only` |
| Fitness-habit claims/candidates | 0 |

This is a correct abstention for missing modality. It is not evidence that
HealthKit lacks ingestion value, and row count must never be reported as habit
coverage.

## 5. Icebreaker staleness: first-exposure contract

The old choices—freeze indefinitely at match time or silently rewrite prior
messages whenever either profile changes—are both too coarse. V0.3.1 uses first
exposure as the boundary:

1. Match-time generation creates a provisional, unexposed frame.
2. Immediately before first exposure, a service-only transaction revalidates
   the active match authorization and participants, both users' current
   revisions, linked validated facts, naming/selection grants, purpose, and
   frame state.
3. If any dependency changed, the unexposed frame becomes stale and must be
   rebuilt; it is not shown.
4. Once exposed, its text, validated frame, fact links, and provenance are
   immutable historical message content. Later profile revisions do not rewrite
   what a participant already saw.
5. Any new frame or reuse decision must revalidate current dependencies.

Only the service-only exposure function may perform the first-exposure
transition; direct client mutation is forbidden.

## 6. Cross-user reads are narrow and server-owned

The standalone v0.3.1 reference creates no broad `authenticated` read policy
over discovery, dyad, bio, icebreaker, raw-vault, HealthKit, or candidate
tables. The reviewed app currently makes `public.discovery_cards` readable by
every signed-in account and permits client-authored semantic JSON. That is a
present legacy path to replace, not evidence that the new surface is missing or
already safe.

Production discovery, bio, and matched-chat RPCs must run on the server, derive
the viewer from `auth.uid()`, and verify the exact subject plus block/privacy/
rate-limit rules, match authorization where required, both current revisions,
data-use purpose, surface selection/naming/explanation grants, and sanitized
fact lineage. They return only the minimal sanitized projection. The service
role is a backend credential, never a client entitlement.

## 7. App migration and deployment gates

The complete repository overlay is
[`WRITTEN_REPOSITORY_INTEGRATION.md`](WRITTEN_REPOSITORY_INTEGRATION.md). It is
mandatory for implementation. The standalone reference schema remains the
semantic authority; the repository overlay translates it into the current app
without allowing the prototype schema to constrain ontology quality.

### Application wiring

- Adapt `CalendarDistiller`, `GoogleCalendarDistiller`, `DistillViewModel`, and
  `SyncService` so Calendar follows: encrypted raw write
  → local allowlist-first classifier → closed sanitized candidate. Do not send
  excluded or unknown events to the generic mapper.
- Keep Calendar containers as classifier metadata only. Preserve provider event
  IDs, revision/etag, ownership/attendance/status, time zone, and typed vendor
  artifacts in connector contracts rather than semicolon-packed title text.
- Adapt `HealthKitDistiller` and the health branch in `DistillViewModel.sync`.
  Add HealthKit/Motion permission, denial, revocation, and deletion UX. Serialize
  only the four typed contracts and keep surface choices separate from source
  authorization.
- Implement idempotent repositories and handlers for all 11 closed jobs,
  including `derive_fitness_habits`; never place raw Calendar or Health values in
  queue payloads or durable errors.
- Route first icebreaker exposure through the service-only atomic revalidation
  function. Never accept client-authored ready bio or icebreaker text.
- Add a scheduled retention worker. The schema validates `retained_until`, and
  HealthKit grant revocation purges Health ciphertext, but time-based raw-vault
  expiry is not an automatic database TTL.
- Replace client semantic writes in `DiscoveryCardService`, broad reads in
  `DiscoveryService`, legacy `match_profile`, and `seed_icebreaker()` only after
  server-owned projections and two-version compatibility tests exist.
- Implement envelope encryption with KMS/HSM-controlled key wrapping,
  separately keyed lineage HMACs, audited worker decrypt access, rotation, and
  deletion across Postgres, object storage, queues, logs, and backups.

### Database order and packaged validation

The standalone reference order is:

```text
001_schema.sql
002_rls_and_rpc.sql
003_seed.sql
004_product_surfaces.sql
005_private_ingestion_and_fitness.sql
006_current_state_and_surface_hardening.sql
```

Run contracts 001–003 immediately after migration 003, then apply and replay
004 and run contract 004, apply/replay 005 and run contract 005, then
apply/replay 006 and run
`sql/tests/006_current_state_and_surface_hardening_contract.sql`. See
`VALIDATION.md` for what has actually been executed; documentation is not a
passing test result.

A separate internal reference 004→005/replay chain has a recorded passing
baseline: apply reference migrations 001–004, load
`sql/tests/fixtures/004_calendar_upgrade_fixture.sql`, apply and replay migration
005, then run `sql/tests/005_calendar_upgrade_contract.sql`. This proves the
reference 004→005 upgrade against synthetic stored Calendar mappings, typed candidates, and
Memories state rather than only an empty schema. It verifies one revision bump,
canonical downgrade with no private caption, continued legacy-classification
ineligibility, one classification/recompute job each, and replay safety.

A third recorded passing lane applies reference 001–005, loads
`sql/tests/fixtures/005_surface_fact_upgrade_fixture.sql`, applies/replays 006,
and runs `sql/tests/006_surface_fact_upgrade_contract.sql`. It proves that
pre-006 facts without exact score/revision attestation retire without invented
provenance, linked ready bios and unexposed icebreakers stale, and audit links
remain intact.

The recorded Python baseline is **244/244** with the pinned Written checkout
manifest enabled, including **14/14 HealthKit tests**; the
closed job registry contains **11** job types, and CSV/SQL seed parity is
**45 concepts, 42 aliases, and 37 edges**.

These filenames are not the Written app's migrations. At the reviewed head the
app already has `0001–0041`, and its `0004`/`0005` are unrelated. Adapt
reference 001–006 into the next app migrations (`0042+` at this pin), map
reference `private.*` to app `semantic_private.*`, and preserve the existing
app `private` schema. Never run the reference files unadapted against the app.

Before production, repeat the standalone sequence on a disposable native Supabase/
PostgreSQL project and test extension placement, replay, RLS/ACLs, two-user
authentication, narrow RPC authorization, account deletion, grant narrowing
and revocation, raw retention expiry/purge, stale-run races, lease loss/retry/
dead-letter behavior, deterministic rendering, and first-exposure concurrency.
Package or PGlite success is not evidence that the hosted deployment or app
integration is complete. The real `0001–0041 → 0042+` Written upgrade remains
an integration gate until adapted migrations and their native contracts exist.

### Rollout order

1. Ship additive `semantic_private` storage, KMS-backed capture, retention, and
   typed dual-write behind flags; keep all new semantic outputs in shadow.
2. Backfill only as `legacy_unverified`, require fresh distillation where
   current membership cannot be proved, and compare old/new outputs for
   diagnostics rather than truth.
3. Validate false positives, abstention, correction/removal, provenance, and
   permission behavior with a user-level cohort.
4. Cut over owner-only Memories first.
5. Enable stable confirmed/user-added bio facts and server-owned discovery for
   a canary cohort.
6. Enable viewer-conditioned selection only behind revision-safe experiments.
7. Enable matched-chat icebreakers with atomic first-exposure checks.
8. Enable the independent HealthKit matching, bio-naming, icebreaker-naming, and
   controlled-explanation grants only after each surface's product, privacy,
   and native authorization review.
9. Revoke legacy semantic writes/direct reads and disable the old trigger only
   after a minimum supported client and rollback window are defined.

Rollback is forward-only and fail-closed. Independent flags must disable typed
ingestion, shadow computation, Memories, discovery/profile clauses,
icebreakers, and HealthKit use. An emergency privacy switch must stop promotion
and cross-user exposure without an app release. Calendar substring inference,
broad HealthKit use, client-authored semantic JSON, and the old creator-overlap
icebreaker are never rollback targets; omission is the safe fallback.

## 8. Apple policy references and release caveat

As checked for this handoff, Apple's current materials make the relevant
direction clear: HealthKit must be used for health or fitness purposes, Health
and Motion data cannot be used for advertising or unrelated use-based mining,
and collection/use/sharing must be disclosed and permissioned. Review the live
documents again before submission because Apple can revise them:

- [Apple Developer Program License Agreement, section 3.3.3(H)](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/)
- [App Review Guidelines 2.5.1, 5.1.2(vi), and 5.1.3(i)](https://developer.apple.com/app-store/review/guidelines/)
- [HealthKit documentation](https://developer.apple.com/documentation/healthkit)
- [Apple health and fitness app guidance](https://developer.apple.com/health-fitness/)

The `fitness_connection` design is a product and engineering constraint intended
to support a genuine fitness service. Neither this handoff, passing tests,
purpose strings, privacy manifests, nor technical conformance guarantees App
Review approval. Written must submit the actual end-to-end use, UI, disclosures,
storage, server transfer, matching behavior, and deletion flow for review.

## 9. Definition of done

V0.3.1 is ready to enable only when all of the following are true:

- broad capture is encrypted, owner-scoped, consented, retained, and deletable;
- raw Calendar/HealthKit data cannot enter the generic mapper, online/global
  mining, worker payloads, or presentation JSON;
- every Calendar semantic output comes from a current typed candidate with a
  server-controlled canonical label; retained legacy typed rows remain
  ineligible after revision bump and pending rebuild;
- the exclusive 106-event Calendar partition and 9-row/5-lineage result are
  reproduced;
- ticket predicates never overstate attendance, preference, recurrence, or
  identity, and public-entity resolution uses stable verified IDs;
- HealthKit sparse/aggregate-only data abstains and every derived fact remains
  purpose- and surface-locked;
- Health matching, bio naming, and icebreaker naming are independent grants,
  with bilateral matching authorization and separately controlled explanation;
- HealthKit sleep remains typed-private coverage and cannot become a semantic
  candidate or surface fact, including through the reserved ontology seed;
- unexposed stale icebreakers cannot be shown and exposed ones are immutable;
- cross-user output is available only through narrow server-owned RPCs;
- the standalone 001–006 reference chain and contract 006 pass, and adapted
  `semantic_private` app migrations pass both clean and real 0001–0041 upgrade
  paths on native Supabase;
- KMS-backed encryption, key rotation, audited decrypt, retention, account
  deletion, backup deletion, and privacy-safe telemetry are demonstrated;
- all 11 handlers are wired and idempotent;
- native migrations/contracts, RLS, deletion, retention worker, revocation,
  concurrency, and two-user authorization tests pass; and
- product/privacy review accepts the exact shipped behavior, with no assumption
  that package conformance guarantees platform approval.
