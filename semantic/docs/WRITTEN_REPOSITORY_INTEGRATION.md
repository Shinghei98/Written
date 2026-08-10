# Written repository integration and cutover plan

**Package release:** 0.3.1  
**Semantic contract:** v0.3.1  
**Reviewed application baseline:** `Shinghei98/Written` at commit
`8203353532dffd5f608df92861fd8a631dc7b7d4`  
**Reviewed migration head:** `0041_collaborator.sql`

This document is the repository-specific execution overlay for the target
architecture in [`ENGINEERING_SPEC.md`](ENGINEERING_SPEC.md). The application
repository is an acquisition, product-shell, and migration baseline. It is not
the authority for semantic design. When the current Swift/SQL implementation
and the v0.3.1 contract disagree, the v0.3.1 contract controls.

The governing rule remains:

> **Capture broadly in an authorized private store; promote narrowly; label
> rigorously.**

The repository snapshot will drift. Before implementation, record the new Git
commit and migration head. If either differs from the baseline above, rerun the
preflight in section 6 and allocate new migration numbers. Do not reuse an
already-landed number.

## 1. What the current repository provides

The repository already contains a substantial iOS product and useful source
acquisition work:

- authentication, onboarding, profile photos, discovery, likes, matching,
  chat, attachments, notifications, reporting, blocking, and deletion flows;
- Apple Music, local music, YouTube, podcasts, Apple Calendar, Google Calendar,
  HealthKit, location, and user-entered adapters;
- local snapshot/cache behavior and source connection state;
- an existing Supabase history through migration 0041; and
- profile, Memories-like dashboard, match-profile, and icebreaker UI shells.

Those assets should be reused. The semantic core should not be extended from
the existing flat record and substring model merely because it exists.

### Current end-to-end path

1. Source adapters return `DistilledRecord` values.
2. `DistillViewModel.replaceRecords(from:with:)` replaces the device snapshot.
3. `SyncService` sends legacy JSON to `append_source_records` or, for HealthKit,
   sends only the current derived summaries.
4. `Ontology.swift`, `ListeningHighlights`, and related helpers compute flat
   terms and percentages on the client.
5. `DiscoveryCardService` lets the client write semantic JSON into
   `public.discovery_cards`.
6. Every authenticated user may select every discovery-card row.
7. `public.seed_icebreaker()` intersects legacy strings when a conversation is
   inserted and freezes the result in conversation columns.

This path is suitable for a prototype, not for evidence-licensed assertions.

## 2. Keep, adapt, replace, and build

| Decision | Repository components | Required treatment |
|---|---|---|
| Keep | Source authorization/acquisition; auth; profiles; photos; chat; push; report/block; visual shells | Preserve behavior while replacing the record contract beneath it |
| Adapt | `DistilledRecord`, `DistillViewModel`, `SyncService`, `RecordStore`, source adapters, Dashboard/Memories editing, discovery and chat services | Dual-write typed envelopes; consume server-owned assertion/surface IDs |
| Replace as semantic authority | `Ontology.swift`, client-side domain/subject percentages, generic Calendar title matching, `summary_distilled_records` as current state, client-authored discovery semantics, `seed_icebreaker()` | Keep only behind a temporary legacy feature flag during shadow operation |
| Build | Private ingestion endpoint, encrypted raw vault, typed observations/candidates, revisioned assertions, worker handlers, grants, retention, safe RPCs, shadow comparison, cutover and rollback controls | Use this package's Python and SQL contracts as the canonical implementation source |

Do not port the decision rules independently into Swift, SQL, and Python. Swift
captures typed source data and renders validated outputs. The Python worker
owns deterministic classification, mapping, scoring, and frame construction.
Postgres owns authorization, versions, current pointers, invalidation, and
final promotion constraints.

## 3. Repository findings that change the implementation plan

### 3.1 Provenance is lost at the current transport boundary

`SyncService.push(source:records:)` omits each record's own source, and
`append_source_records` stamps the outer batch source. An Apple Music run can
contain a user/connection row. Under the current transport, that row can be
stored as Apple Music evidence even though its `DistilledRecord.source` says
otherwise.

The new envelope must carry both:

- `connector_source`: which authorization/distillation produced the batch; and
- `record_source`: the source whose semantics and policy apply to this row.

The server must validate the exact `record_source`/action contract. It must not
overwrite record provenance with the batch source.

### 3.2 The legacy summary is history, not current state

Written app migrations 0004–0006 retain changed versions and expose the latest version ever
seen for each key. They do not record complete ingestion-run membership,
absence, provider deletion, lookback expiry, or connector revocation. A record
that disappears from a later source snapshot can therefore remain semantically
active indefinitely.

The new path requires:

- an ingestion run with start/finalization state and source coverage;
- explicit membership of provider items in a completed snapshot;
- `first_seen_at`, `last_seen_at`, lifecycle state, and tombstones where the
  connector can establish deletion;
- validity windows and source-specific recency; and
- a user semantic revision increment when current input changes.

Finalized partial, truncated, and delta runs may affirm or update items they
actually report, including explicit provider deletions. Missing from those
runs is unknown—not deleted and not negative evidence. Only a finalized
complete full snapshot may infer absence from omission; a failed run changes
no current source state.

### 3.3 Calendar capture and Calendar promotion are conflated

The current EventKit and Google adapters filter some calendars before storage,
store accepted events whole, and later allow broad title/creator processing.
`ListeningHighlights` applies presentation exclusions, but drawing is too late
to be an inference boundary. A medical appointment, test, meeting, or another
person's arrival can still influence the semantic model before being hidden.

The v0.3.1 correction is not narrow ingestion. The new path may capture the
complete authorized Calendar record—including records that later become
work, personal, sensitive, subscribed, generated, or unknown—inside the
owner-private encrypted vault when the product's disclosed scope and retention
permit it. The classifier then assigns exactly one disposition. Only a current
typed flight/ticket/reservation candidate may promote. All other dispositions
produce zero semantic mass.

For migration:

- keep the legacy UI path temporarily so the app remains usable;
- send all newly authorized raw Calendar records to the new private endpoint;
- never send a Calendar row to the generic alias mapper or embeddings;
- preserve provider ID, etag/revision, status, ownership/attendance,
  calendar type, time zone, structured start/end, URL host, and stable public
  ticket/catalog IDs where present; and
- keep title, route, location, organizer, attendees, meeting URL, and booking
  text only inside the encrypted raw object, never in durable queue, candidate,
  log, error, or presentation JSON.

If ingestion is capped or paginated, persist explicit coverage/truncation state
so missing rows cannot be treated as absence.

### 3.4 HealthKit is acquired but not ingested through the claimed path

The source code contains contradictory comments. `SyncService` has a generic
path that could serialize Health records, but `DistillViewModel.sync` special-
cases `health` and currently sends only derived `health_signals` and
`health_sports`. The raw/typed workout, activity-day, and activity-hour records
remain device-side. Sleep is not an active semantic input.

The new implementation must make HealthKit ingestion real:

- record the `fitness_connection` purpose grant before transfer;
- send typed `activity_day`, `activity_hour`, `workout`, and optionally
  authorized `sleep_session` envelopes to the private endpoint;
- keep HealthKit object identity so mirrored/revised workouts cannot fabricate
  recurrence;
- retain age/profile routing separately and keep biological-sex/medical fields
  outside the social ontology;
- treat daily/hourly-only coverage as `aggregate_only` and emit no exercise
  label; and
- keep sleep as typed-private coverage with no v0.3.1 matching or surface path.

The legacy `health_sports` table is not sufficient evidence for a v0.3.1 habit.
Do not backfill a fitness assertion from it. Require a new typed distillation
under the current purpose grant.

### 3.5 Client-authored discovery JSON is not an assertion surface

`public.discovery_cards` is selectable by every authenticated account, while
`DiscoveryCardService` lets each client write its own `interests`, `domains`,
and `top_subjects`. Even when the JSON is thin, it bypasses evidence lineage,
surface grants, revision checks, block checks, and server-controlled rendering.

During shadow mode the old table may continue serving the released client.
The new client must use a paginated server-owned discovery RPC that:

1. derives the viewer from `auth.uid()`;
2. enforces discoverability, mutual block, eligibility, and rate limits;
3. selects only current, surface-authorized assertions;
4. applies viewer-conditioned selection without changing subject truth;
5. returns only minimal rendered output and media references; and
6. never accepts semantic terms, weights, captions, or ready text from the
   client.

After cutover, revoke authenticated direct selection and client semantic writes
on the legacy table. A rollback must disable the new semantic clause or use a
neutral profile fallback; it must not reactivate fail-open client semantics.

### 3.6 The current icebreaker is neither typed nor revision-bound

The current `seed_icebreaker()` reads legacy creator strings across sources and
labels a generic overlap as an artist. Podcast publishers, Calendar organizers,
or other creators can collide. It runs at conversation insertion and never
revalidates either user revision.

Do not migrate legacy conversation themes into validated facts. New matches use
`semantic_private.match_authorizations`, revisioned dyads, validated two-sided facts, and
the atomic first-exposure transition. Existing conversation columns may remain
read-only for a rollback window, but the new client must not newly expose an
unvalidated legacy theme. Already seen legacy text is historical; it is not
retroactively blessed or silently rewritten.

### 3.7 Title-keyed bans cannot become assertion feedback automatically

Legacy Calendar removal is keyed by title and legacy bans do not identify a
typed assertion or exact exposure. Import them as conservative, user-specific
legacy suppressions at the raw/source layer. Do not attach a title ban to an
arbitrary ontology concept, and never turn it into a global mapping negative.
New Memories removal must call the assertion-specific no-reason RPC.

## 4. New iOS contracts

Add a typed envelope alongside `DistilledRecord` during dual-write. A minimal
shape is:

```text
SourceEnvelope
  schema_version
  ingestion_id
  connector_source
  record_source
  action
  provider_item_id
  provider_revision_or_etag?
  observed_at
  source_event_at?
  lifecycle_state
  data_use_purpose
  typed_payload
```

`typed_payload` is a source/action-specific Codable enum, not a semicolon string
and not arbitrary JSON. Raw Calendar and HealthKit payloads travel only to the
authenticated ingestion service over TLS. The service derives the user from
the access token, validates purpose/source/action, performs application-layer
envelope encryption before durable storage, and returns an ingestion receipt.
The encryption master key must not exist in the iOS binary or database row.

Recommended new app files:

- `Written/Models/SourceEnvelope.swift`
- `Written/Models/SourcePayload.swift`
- `Written/Services/SemanticIngestionService.swift`
- `Written/Services/SemanticSurfaceService.swift`
- `Written/Services/SemanticFeedbackService.swift`
- `Written/Services/FitnessPurposeGrantService.swift`

The exact filenames are flexible. The boundaries are not.

### Required changes at existing seams

| File/path | Change |
|---|---|
| `Written/Models/DistilledRecord.swift` | Keep as legacy UI model during shadow; stop treating it as the semantic contract |
| `Written/ViewModels/DistillViewModel.swift` | Produce one ingestion ID per run, dual-write typed envelopes, and stop publishing semantics directly |
| `Written/Services/SyncService.swift` | Preserve per-record provenance; call the private ingestion endpoint; surface durable retry state |
| `Written/Services/RecordStore.swift` | Remain a scoped offline cache, not the authority; keep new receipts/retry queue separately |
| Calendar distillers | Capture broadly to the private lane; emit structural fields; move semantic exclusion to the closed classifier |
| `HealthKitDistiller.swift` | Emit canonical typed records with stable HealthKit identity and explicit modality coverage |
| `Ontology.swift` and highlight helpers | Legacy-only during shadow; remove from production semantic publication after cutover |
| `DiscoveryCardService.swift` / `DiscoveryService.swift` | Replace semantic upsert/direct table read with server-owned surface RPCs |
| `MatchProfileService.swift` | Require current match/invitation authorization and block state; do not rely on any historical like row |
| `ChatService.swift` / `IcebreakerCard.swift` | Fetch and atomically expose a validated frame; ignore unvalidated legacy theme columns |
| Dashboard/Memories UI | Render assertion IDs and groups; confirmation/removal are RPCs, not title-string edits |

## 5. Two migration namespaces

The package files `sql/001_schema.sql` through
`sql/006_current_state_and_surface_hardening.sql` form a standalone reference
chain. That reference chain uses the schema name `private`. The Written app
already has migrations `0001` through `0041`, and its existing `private` schema
contains unrelated push and collaborator objects. Do not copy the reference
files into the app migration directory under their current names, do not run
them unadapted against production, and do not let reference-schema grants touch
the app's existing `private` objects.

In the Written adaptation, map every reference `private.*` semantic object to
`semantic_private.*`. Keep `private.*` reserved for the app objects that already
use it. The reference name is retained inside this standalone package so its
tested chain remains coherent; the namespace translation is a mandatory part
of the app migration, not an optional style change.

At the reviewed head, use the next available contiguous range:

| App migration | Source/role |
|---|---|
| `0042_semantic_schema.sql` | Adapt reference 001; create `semantic_private`, ontology/core tables, and required extensions without recreating app `private` |
| `0043_semantic_rls_and_rpc.sql` | Adapt reference 002; install guards/RLS and exact grants on `semantic_private` only |
| `0044_semantic_seed.sql` | Adapt reference 003; install the versioned seed |
| `0045_semantic_product_surfaces.sql` | Adapt reference 004 |
| `0046_semantic_private_ingestion_fitness.sql` | Adapt reference 005 |
| `0047_semantic_current_state_surfaces.sql` | Adapt reference 006; install per-scope current-state heads, service-only terminal transitions, exact fact attestation/legacy retirement, canonical match epochs, and related invalidation contracts |
| `0048_semantic_legacy_bridge.sql` | App-specific ingestion-run bridge, shadow flags, legacy backfill metadata, and conversation/match authorization bridge |
| `0049_semantic_server_projections.sql` | App-specific discovery, Memories, match-profile, and chat surface RPCs plus authorization tests |
| `0050_semantic_cutover.sql` | Revoke legacy semantic writes/direct reads, disable the old icebreaker trigger, and retain legacy data read-only for rollback/audit |

If repository migration head is no longer 0041, shift this entire range. Keep
the order and roles; never reuse a number.

### Integration adaptations that are mandatory

- The existing app already owns `private.push_config`, `private.notify`, and
  `private.collaborators`. Never drop, recreate, revoke on, or change default
  privileges for the app's `private` schema as part of semantic installation.
- Translate reference `private` to app `semantic_private`, then replace
  schema-wide `grant ... on all tables` statements with explicit grants on new
  semantic objects. Do not change privileges on the existing push
  configuration or collaborator registry as an accidental side effect.
- Keep semantic user foreign keys anchored to `auth.users(id)`, as tested by the
  package. Join `public.users` explicitly only when a surface needs product
  profile fields.
- Validate the existing `extensions` schema and extension versions before
  creating `pgcrypto`, `vector`, and `pg_trgm` there.
- Prefer exposing only the audited `api` RPC schema through Supabase and update
  `PostgREST.swift` to send the required `Accept-Profile`/`Content-Profile`
  headers. If deployment constraints require public wrappers, each wrapper
  must be a minimal, audited security-definer function with a pinned empty or
  explicit `search_path`, explicit grants, and no caller-supplied user ID.
  Never expose `semantic_private`, the app's `private`, or `ontology` schemas
  to the Data API.
- Preserve existing chat/push functions and triggers unless a named cutover
  migration replaces them.
- Test every migration on a scrubbed clone of the current schema, not only an
  empty package database.

## 6. Preflight before writing migration 0042

Record and review:

1. Git commit and current migration head.
2. Existing schemas, extensions, object names, owners, grants, RLS policies,
   security-definer functions, and trigger dependencies.
3. Supabase exposed schemas and JWT role behavior.
4. Row counts and largest payloads for `distilled_records`, `health_signals`,
   `health_sports`, `discovery_cards`, `likes`, `conversations`, and `bans`.
5. Existing users with revoked connectors, deleted accounts, incomplete source
   runs, or YouTube retention deadlines.
6. Whether current clients still call each legacy table/function that the
   cutover will eventually revoke.

Fail the deployment if the baseline has drifted without review, an app
migration number collides, a package object collides with a different existing
object, or an adapted grant broadens access.

## 7. Backfill rules

Backfill is a provenance migration, not permission to invent current truth.

| Legacy source | Backfill rule |
|---|---|
| `distilled_records` | Import as `legacy_unverified` historical observations with original source/action/timestamps where reliable; never infer complete snapshot membership from latest-ever rows |
| Calendar rows | Move raw content into the encrypted owner vault if consent/retention remains valid; run only the current Calendar classifier; unknown/excluded rows emit zero evidence |
| `health_signals` / `health_sports` | Retain as legacy product history; do not promote to v0.3.1 fitness assertions without a fresh typed HealthKit distillation and purpose grant |
| YouTube | Enforce current retention/deletion and policy mode before import; never enable fusion or surfaces by migration |
| Legacy bans/removals | Create source-local legacy suppressions; do not create concept-level negatives without an exact assertion/exposure link |
| Discovery semantic JSON | Do not import as validated assertions; use it only for shadow comparison and user review |
| Conversation themes | Do not import as validated frames; preserve as read-only legacy history if already exposed |

A fresh source distillation should supersede uncertain backfill. The product
must distinguish “historical,” “currently observed,” “user confirmed,” and
“unknown because coverage was incomplete.”

## 8. Additive rollout

### Phase 0 — baseline and native dry run

- Freeze the reviewed commit/migration head.
- Adapt reference migrations 001–006 into app migrations 0042–0047 using
  `semantic_private`, then add the app-specific bridge/projection migrations.
- Prove clean install, current-schema upgrade, replay, and two-user RLS on a
  disposable native Supabase project.
- Ship no product behavior.

### Phase 1 — private ingestion and dual-write

- Add the typed envelope and authenticated ingestion endpoint.
- Continue the legacy write for current clients/UI.
- Write the new private run/vault path with independent retry/idempotency.
- Record old/new correlation IDs and compare record/source/action coverage.
- Do not publish new semantic outputs.

### Phase 2 — backfill and shadow computation

- Backfill under the rules in section 7.
- Run all source-specific classifiers/builders and the semantic worker.
- Compare old display terms against new assertions for diagnostics only.
- Review every Calendar/HealthKit promotion and a stratified sample of
  abstentions. Optimize precision and useful coverage, not agreement with the
  old substring model.

### Phase 3 — Memories cutover

- Read owner-only assertion snapshots through a narrow RPC.
- Make confirmation, addition, removal, and restoration assertion-specific.
- Keep public discovery, bio, and icebreaker on the old path.

### Phase 4 — server-owned discovery and matched profiles

- Enable the paginated discovery RPC for a small cohort.
- Route `DiscoveryService`, `MatchProfileService`, and any chat/profile lookup
  away from direct `discovery_cards` reads.
- Confirm block, eligibility, invitation/match state, grants, and current
  revisions on every request.

### Phase 5 — first-exposure icebreakers

- Create provisional typed frames from a current authorized dyad.
- Atomically revalidate immediately before first display.
- Freeze exposed frames as history; invalidate only unexposed frames.
- Stop reading legacy theme columns in the new client.

### Phase 6 — cutover and retirement

- Require a minimum supported client version.
- Apply the forward-only cutover migration: revoke legacy semantic writes/direct reads and
  disable `conversations_seed_icebreaker`.
- Retain legacy tables/columns read-only for the defined rollback/audit window.
- After that window and a verified backup, remove them in a separate future
  migration—not in 0050.

## 9. Rollback contract

Migrations 0042–0049 are additive. A runtime feature flag can return the app to
legacy non-semantic product operation while the new private data remains
isolated. Rollback must obey these rules:

- never delete new evidence or revision history merely to restore the UI;
- never copy new raw/private values into legacy public JSON;
- never reactivate Calendar substring mapping, broad HealthKit use, or the old
  creator-intersection icebreaker as a semantic fallback;
- use a neutral profile/icebreaker omission when a validated projection is
  unavailable; and
- do not reverse 0050 in place. Restore a previous database version only under
  incident procedure, or ship a new forward migration with an explicit policy
  review.

The minimum flag set is independently controllable for typed ingestion,
semantic shadow computation, Memories reads, discovery/profile reads,
icebreaker first exposure, and HealthKit fitness use. The emergency privacy
kill switch disables promotion and cross-user exposure without deleting the
raw audit trail. It must not depend on a new app binary.

## 10. Repository-specific acceptance gates

Release is blocked until all are true:

### Ingestion and current state

- Every typed row retains `connector_source` and `record_source`; cross-source
  rows cannot be restamped by a batch.
- Partial/truncated/delta runs may affirm or update seen items, including
  explicit provider deletions, but cannot infer absence from omission; failed
  runs change no current source state.
- A finalized complete full snapshot can expire a missing item without deleting
  history.
- Disjoint scopes have independent heads; an overlapping stale scope makes a
  multi-scope run superseded atomically. Clients and the service role cannot
  update terminal run status/current pointers outside the finalize/fail entry
  points.
- A connector revocation removes eligibility immediately and starts the
  required purge lifecycle.
- Client retries are idempotent and cannot duplicate evidence or recurrence.

### Calendar and HealthKit

- Raw Calendar/HealthKit values exist only in the owner-private encrypted path.
- Unknown, work, social/third-party, sensitive, generated, and cancelled
  Calendar records can be retained but contribute zero evidence.
- One verified ticket can create only its typed booked/scheduled predicate.
- Aggregate-only HealthKit produces zero fitness claims.
- Workout habits require the versioned recurrence thresholds and exact object
  lineage; sleep produces coverage only.
- Purpose/grant revocation invalidates future Health surfaces and purges as
  specified without rewriting exposed history.

### Authorization and surfaces

- Authenticated clients cannot select private/ontology tables or write semantic
  candidates, assertions, scores, bios, or icebreaker text.
- Discovery RPCs enforce mutual block, eligibility, rate limit, current
  revision, and surface permissions for two adversarial users.
- Match profile no longer remains readable merely because any historical like
  row exists; current invitation/match authorization is required.
- The client cannot accept/decline a like outside the allowed state transition
  or forge a match authorization. Server time sets the transition timestamp.
- No new client reads an unvalidated legacy conversation theme.
- First exposure is atomic under concurrent revision change and exactly-once
  under retry.
- Pre-attestation facts from an interrupted 0045/0046 rollout retire without
  fabricated score/revision provenance; linked ready bios and unexposed frames
  stale. Match participant identity is stable across contiguous authorization
  epochs, with only one active match ID per unordered pair.

### Migration, observability, and performance

- The standalone reference 001–006 chain and contract 006 pass on a disposable
  native Supabase/PostgreSQL environment.
- Clean 0042–0050 install and real 0001–0041 → 0042–0050 upgrade both pass on
  native Supabase, including replay checks where applicable.
- Existing push/chat/profile behavior remains green through 0048.
- Shadow metrics separate retained rows, typed rows, candidates, assertions,
  abstentions, corrections, and surface exposures by source/model version.
- Logs, traces, queue rows, errors, and analytics contain no raw Calendar or
  HealthKit payloads.
- Discovery and chat RPCs meet an agreed p95 latency under representative
  pagination and concurrency.
- A retention worker demonstrably purges expired ciphertext/object blobs and is
  idempotent under retry and account-deletion races.

## 11. Definition of repository cutover complete

The repository is integrated only when:

1. `DistilledRecord` is no longer a semantic authority.
2. All enabled connectors dual-write or exclusively write typed source
   envelopes with exact provenance and run membership.
3. Calendar and HealthKit can be captured broadly without generic semantic
   promotion.
4. Current assertions and all dependent product surfaces are revision-bound.
5. Discovery, matched profiles, Memories, and icebreakers are server-owned,
   purpose/surface authorized, and minimally projected.
6. The old `seed_icebreaker` trigger and client-authored discovery semantics are
   disabled for supported clients.
7. Legacy data remain historical/auditable without being silently blessed as
   current truth.
8. Native migration, RLS, deletion, retention, race, and performance gates pass.

Until adapted 0042+ migrations, app repositories/handlers, and the native
upgrade suite exist and pass, the ontology package is a standalone reference
and shadow-system design—not a claim that the production app has adopted it.

## 12. KMS, decryption, and deletion gate

`encrypted_payload` is a persistence shape, not proof that encryption has been
implemented safely. Before Phase 1, select and document an envelope-encryption
design with these minimum properties:

- a KMS/HSM-controlled key-encryption key never stored in the iOS binary,
  Postgres row, worker environment file, or source repository;
- per-user or narrowly scoped data-encryption keys, wrapped with a recorded key
  version, with rotation that does not change semantic identity;
- a separate secret for source-item/lineage HMACs so a database reader cannot
  test guesses or derive encryption keys;
- decrypt permission limited to the source-specific worker path, with audited
  calls and no plaintext in logs, traces, analytics, queue payloads, or durable
  errors;
- deletion across database ciphertext, object storage, retry/dead-letter
  artifacts, and backups according to the disclosed retention policy; and
- tested crypto-erasure/account-deletion and key-rotation recovery procedures.

If the worker cannot decrypt through this controlled path, server-side
reclassification is not implemented. If a general service credential can
decrypt every record without an auditable boundary, the privacy architecture
is not ready for production.
