# Aggregate v0.3.1 review of a historical Written export

This note records the current v0.3.1 adapter result for one legacy eight-column
export, at aggregate level only. It is a mechanics fixture, not a population
evaluation or the authoritative product-surface contract. Use
[`ENGINEERING_SPEC.md`](ENGINEERING_SPEC.md) for implementation. The supplied
user-level CSV and all raw routes/events are excluded from the project,
fixtures, logs, and archive.

This is an aggregate adapter audit, not a database-upgrade proof. Repository
integration is pinned to Written commit
`8203353532dffd5f608df92861fd8a631dc7b7d4` at migration head `0041`. The SQL
files `001`–`006` are a standalone reference sequence; Written still needs
adapted migrations beginning at `0042`, with reference `private.*` internals
translated to `semantic_private.*`. Until that real upgrade exists and passes,
it remains an integration gate.

## Shape

The finalized export contains 2,539 rows in the expected eight-column format.

| Source | Rows | Ontology treatment |
|---|---:|---|
| Apple Music | 1,154 | Behavioral/catalog evidence after action filtering and lineage deduplication |
| Local music library | 320 | Same `music` independence group as Apple Music |
| YouTube | 550 | Provider topics/actions with stable channel-role separation and default-false cross-source/public gates |
| Apple and Google Calendar | 116 | Reclassified by exclusions, ownership, and structured commercial allowlists |
| Health | 389 | Private typed quantitative ingestion; `aggregate_only` coverage and no habit candidate in this export |
| Explicit user and location | 10 | Route to existing private profile/connection state, not inference |

Podcast is absent. Missing connector state must remain unknown unless a
separate coverage manifest distinguishes not-connected, empty, denied, error,
stale, and revoked states.

## What survived the v0.3.1 adapter gates

- 1,830 semantic observations survive action, privacy, ownership, and
  exact-record gates.
- Music contributes 1,313 observations after one exact duplicate is removed.
  They collapse to 731 content lineages. Apple Music and the local library are
  one `music` independence group.
- YouTube contributes 508 observations and 508 lineages: liked videos and
  subscriptions with provider topics. Uploader channel, represented creator,
  publisher, and content subject remain separate; unapproved evidence may keep
  a source-local score but cannot add breadth, synergy, convergence, bio, or
  icebreaker content.
- Provider topic/genre fields use both pipe and comma delimiters. The adapter
  splits and deduplicates those controlled lists before mapping.
- One immutable source-policy catalog supplies the adapter and mapper with the
  same layouts, reliability values, and exact source/action allowlists.
  Source-incompatible actions are rejected before an observation is created,
  and standalone reference migration 004 installs the matching SQL policy.
- Calendar contributes 9 sanitized private observations in 5 lineages. Eight
  mirrored flight rows collapse to four canonical legs, and the fifth lineage
  is one typed booked activity. Journey reconstruction finds one complete
  round trip and zero recurrence or possible-base candidates. Connector
  mirrors never manufacture volume, breadth, or additional journey votes.
- The eight explicit profile facts, one location fact, and one Apple Music
  subscription-state row are routed separately. Their values never enter term
  mining, embeddings, online resolution, or cross-source scoring.
- All 389 Health rows pass the closed legacy aggregate contracts and are
  retained as private typed quantitative records. Because the file has no
  structured workout or sleep sessions, coverage is `aggregate_only` and the
  fitness-habit candidate count is zero.
- Online resolution is disabled for every row in the standalone export. An
  export cannot prove trusted catalog provenance; production connectors must
  supply verified provider identity through the minimized verifier boundary.

These are adapter diagnostics, not calibrated model results.

## v0.3.1 interpretation

- A single strongly structured travel or leisure ticket can produce a private
  `scheduled_travel_to`, `booked_activity_at`, `booked_event`, or
  `scheduled_dining` Memories candidate. It needs no evidence from another app,
  but it does not prove completion, attendance, preference, recurrence, or a
  home connection.
- Private recurrence review uses distinct journeys and requires at least two
  journeys in two months over 90 days. Public "often returns" state requires
  at least three journeys, two complete round trips, a 180-day span, explicit
  user confirmation, and the relevant permission. Neither state licenses
  machine-inferred `hometown` or `lives_in`.
- Birthdays, medical events, funerals/memorials, friends' events, private
  social events, and work/school/meeting events are excluded before any vendor
  or booking recognition. Unknown Calendar entries fail closed.
- Capture and inference are different decisions. The connector may retain a
  complete event in the user's private source store for sync and local
  classification, but retention does not license semantic use. Of 116 Calendar
  rows in this export, only 9 sanitized observations in 5 lineages survive the
  allowlist-first typed boundary. No Calendar observation enters the generic
  mapper; only a current typed travel/booking candidate may be promoted, and raw
  titles are not sent wholesale to a generic substring classifier.
- Exact dates, routes, flight numbers, booking references, hotels, contacts,
  and future itinerary context remain private and cannot enter a bio or
  icebreaker.
- YouTube channel identity, official creator, publisher, topical, fan/repost,
  and unknown roles remain separate. Evidence that is not approved for
  cross-source fusion can retain a source-local score but is excluded by the
  implemented scorer from breadth, synergy, and convergence motifs.

## Health rows: privately ingested, then correctly abstained

The final file contains 365 `health|activity_day` rows and 24
`health|activity_hour` rows. They summarize daily steps/active energy/first
recorded movement and one 24-bin step distribution. They contain no structured
workout type, workout duration, or sleep sessions. All 389 can be retained as
private typed quantitative inputs, but daily/hourly aggregates alone are not
allowed to nominate running, gym use, a sleep routine, or any other semantic
habit. The resulting coverage class is exactly `aggregate_only`, with zero
fitness-habit candidates.

Written's permitted product purpose for this lane is concrete and narrow:
activity and workout data may help users find people with compatible exercise
routines and support shared exercise and sustained fitness habits. Structured
sleep may be retained only as typed-private coverage; v0.3.1 never promotes it to
a semantic candidate or makes it eligible for matching, naming, explanation, or
another public/product surface. Apple
limits HealthKit and Motion & Fitness APIs and their data
to health, motion, or fitness services and restricts unrelated use-based data
mining:

- Apple Developer Program License Agreement, section 3.3.3(H):
  https://developer.apple.com/support/terms/apple-developer-program-license-agreement/
- App Review Guidelines 2.5.1, 5.1.2(vi), and 5.1.3(i):
  https://developer.apple.com/app-store/review/guidelines/

This interpretation is a product and engineering constraint, not a guarantee
of App Review approval. Written must present and implement the fitness service
consistently in its permission text, UI, privacy disclosures, storage,
derivation, and deletion behavior.

Broad private capture may retain a user-authorized HealthKit payload in the
encrypted raw-source vault under consent, retention, and deletion metadata.
That does not make it semantic evidence. The feature lane recognizes the
canonical aliases `health`, `healthkit`, Apple Health, and Motion & Fitness and
accepts only these closed typed projections:

- a date plus bounded steps and/or active energy, with optional first-movement
  time;
- an hour plus bounded steps and/or a bounded share;
- an allowlisted structured workout type plus a start and either duration or a
  later end; and
- structured sleep stage/start/end under `sleep` or `sleep_session`, with a
  bounded derived duration and coverage-only semantics.

Unknown actions, malformed/non-finite values, free-text labels, routes,
heart-rate/medical measurements, and other unapproved fields fail closed or
are discarded before derivation. Nothing from this lane goes to online
resolution, global term mining, generic embeddings, population-factor models,
advertising, general desirability scoring, or unrelated dating profiling.

The preliminary, versioned abstention thresholds are deliberately strict:

- aggregates alone: `aggregate_only`, no semantic habit;
- exercise type: at least four same-type workouts in 42 days across at least
  three distinct weeks;
- workout daypart: at least six workouts, at least 70% in one coarse daypart,
  and at least three represented weeks.

There is no v0.3.1 sleep-promotion threshold. Repeated or stable sleep records
remain private `sleep_typed`/`mixed` coverage and emit no semantic candidate.
The reserved `routine:consistent_sleep_schedule` ontology seed does not change
that rule.

Any workout-derived candidate that clears those gates retains HealthKit
provenance and the `fitness_connection` purpose. An active fitness-service grant
permits private owner review. `allow_fitness_matching`, `allow_bio_naming`, and
`allow_icebreaker_naming` are independent, default-off choices; controlled
explanation requires its additional grant and the applicable naming grant. Both
users must have active matching grants for Health-based dyadic comparison. User
confirmation cannot broaden that purpose. Revocation removes future eligibility and invalidates
dependent provisional output; an already exposed icebreaker remains immutable
historical message content. Manual Sports & Movement entry remains the fallback
when HealthKit is unavailable or declined.

## Profile and privacy routing

The explicit profile lane contains age, bio, education, flirt level, gender,
gender preference, occupation, and response time. These remain authoritative
self-reports in Written's existing private profile store. They are not
ontology nodes or model features.

- Gender and gender preference must never be converted into sexual orientation.
- Location is a coarse current-location/filter fact, not cultural affinity,
  nationality, ancestry, ethnicity, or hometown.
- Education and occupation are explicit facts, not evidence of interests,
  intelligence, or socioeconomic class.
- Bio remains user-authored private text and is not globally mined or sent to
  an online resolver by default.
- Flirt level and response time are versioned ordinal self-reports, not measured
  behavior.
- Apple Music subscription is connector/coverage state, not a profile trait.

Deleting an explicit profile value is an authoritative profile mutation, not a
negative semantic training label.

## Export contract corrections

1. `source + item_id` is not a unique semantic event. Keep separate record and
   content-lineage identities.
2. Standalone reference migration 004 stores keyed segment and journey lineage HMACs plus explicit
   primary/mirror source links. Production connectors must compute those
   signatures without persisting a raw normalized title.
3. Standalone reference migration 004 historically allowed an eligible classified Calendar row into
   generic `observation_mappings`; reference migration 005 supersedes that behavior and
   blocks all generic Calendar mappings. Promotion is available only through a
   current typed travel/booking candidate.
4. Standalone reference migration 005 retains legacy typed Calendar rows for private audit, but its
   revision bump makes them non-current and ineligible while reclassification
   and typed-candidate rebuild are pending. It also replaces legacy free-text
   presentation values with server-controlled predicate templates and canonical
   active ontology labels.
5. Exact duplicate imports are idempotent. Playlist membership context may
   differ while still sharing one content lineage.
6. The exporter still emits legacy `removed_reason` keys on four calendar rows.
   Stop exporting that field; the adapter ignores its value.
7. Semicolon-packed `extra` cannot safely represent values that themselves
   contain semicolons. Replace it with typed JSON or normalized columns in the
   production ingestion contract.
8. Provider recommendations and subscription metadata are not user affinity.
9. Missing values and missing sources are unknown, never negative evidence.
10. This export has no authoritative run-scope completeness manifest. It therefore cannot
    establish which provider items are current merely by selecting the latest
    row ever seen. Reference migration 006 requires finalized per-run membership
    and reserves inferred absence for a complete full snapshot.

## Consequence for preliminary modeling

This audit is useful for adapter normalization, action weighting, controlled
term parsing, privacy gates, and lineage deduplication. Only v0.3.1-allowlisted
typed Calendar receipts may participate in private semantics, and YouTube
evidence may participate in cross-source convergence only when its enforced
fusion gate permits it. HealthKit data may participate only in the
purpose-limited fitness lane after the documented sufficiency gates. Generic
source-row mapping is fully closed for Calendar and HealthKit; only a current
typed Calendar candidate or exact validated workout-candidate projection may
cross its dedicated promotion boundary. Typed-private sleep is coverage-only in
v0.3.1, and this aggregate-only participant contributes no fitness-habit
candidate. A single user cannot validate population correlations, model
calibration, subgroup behavior, or generalization. It also cannot validate the
app-native API, KMS envelope-encryption path, dual-write divergence controls,
shadow comparison, cutover, or safe rollback.
