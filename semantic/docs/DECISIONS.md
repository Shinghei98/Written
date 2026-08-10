# v0.3.1 consolidated design decisions

This is a concise decision ledger. The complete executable contract is
[`ENGINEERING_SPEC.md`](ENGINEERING_SPEC.md); when wording differs, that
specification controls.

## Fixed now

1. The ontology is a typed directed graph. A concept may sit under multiple
   broader concepts; associative edges do not imply hierarchy.
2. Broad hubs are curated. Local subhubs and long-tail terms may be learned,
   but global promotion requires evidence and review.
3. Raw observations, mappings, user assertions, and surface decisions are
   separate records with separate versions.
4. Source views are fused after within-source normalization and saturation.
5. Missing permission, unavailable connector, no observations, and confirmed
   absence are distinct coverage states.
6. A removal has no reason field. It is an ambiguous negative for surfacing and
   a deterministic user-specific suppression.
7. An addition is a positive assertion. It becomes a mapping label only when
   the user links it to source observations.
8. External knowledge and embeddings generate candidates. Neither can directly
   publish profile language.
9. Sensitive and identity-like concepts cannot be inferred from consumption.
10. Inference paths and feedback are replayable under frozen ontology/model
    versions.
11. `supports_cultural_affinity_candidate` is a curated motif-evidence edge.
    Generic origin, country, language, or narrative-location facts cannot fire
    a user-affinity assertion.
12. Mapping agreement and evidence quality are reported separately. Neither is
    presented as a calibrated probability.
13. HealthKit and Motion & Fitness are an optional, purpose-limited fitness
    service lane. `health`, `healthkit`, Apple Health, and Motion & Fitness
    aliases canonicalize to one private source. Broad user-authorized capture
    belongs in the encrypted raw-source vault and does not itself create
    evidence. The HealthKit feature lane accepts only closed contracts for
    typed daily aggregates, hourly bins, workouts, and sleep sessions; raw rows
    do not become ontology terms. Daily/hourly aggregates alone produce
    `aggregate_only` coverage and no habit candidate. Exercise routines require
    at least four same-type workouts in 42 days across three weeks; daypart
    routines require six workouts with at least 70% in one daypart across three
    weeks. Sleep sessions are accepted only as private `sleep_typed`/`mixed`
    coverage and never create a semantic candidate or surface eligibility. The
    reserved `routine:consistent_sleep_schedule` seed remains for ontology
    compatibility but does not license HealthKit promotion. Every derived fact
    remains locked to `fitness_connection`, cannot enter advertising, general
    desirability, unrelated dating profiling, online/global mining, generic
    embeddings, or population factors, and requires separate matching and
    display grants.
14. Explicit profile facts, coarse location, and connector state are routed to
    separate private product stores. They are not behavioral ontology evidence.
15. Mirrored calendar rows may remain separate observations but must share one
    private content lineage across connectors.
16. One strong structured flight or leisure ticket may create a private
    scheduled/booked Memories candidate without evidence from a second app.
    Its predicate cannot imply attendance, preference, or completed travel.
17. Recurrence gates apply only to recurrence language and possible-base
    review prompts. They do not gate a single scheduled/booked candidate, and
    recurrence never proves hometown or residence. Private review requires at
    least two journeys in two months over 90 days. Public "often returns"
    state requires at least three journeys, two complete round trips, 180 days,
    explicit confirmation, and the relevant permission.
18. Machine inference cannot create `hometown` or `lives_in`. Those relations
    require an explicit user assertion. A recurring route may at most prompt a
    private question using a weaker candidate predicate.
19. Calendar exclusions run before commercial recognition. Birthdays, medical
    events, funerals/memorials, friends' events, private social events, and
    work/school/meeting events cannot enter semantic evidence. Unknown entries
    fail closed. Private connector capture and semantic eligibility are
    separate: retaining a whole event for user-owned sync does not authorize
    passing it to generic ontology classification. Only a minimized,
    allowlisted classifier result may become evidence.
20. YouTube uploader channel, represented creator, publisher, content subject,
    and featured entity remain separate roles. Stable channel ID and an exact,
    reviewed resolution are required before creator transfer; fan/repost and
    unknown channels abstain.
    `cross_source_fusion_allowed=false` is enforced by scoring: such evidence
    may retain a source-local score but contributes no breadth, synergy, or
    convergence motif. SQL persists default-false gates per semantic run,
    requires a current durable approval, and prevents evidence or surface
    permission from laundering a disabled gate.
21. Each assertion has separate Memories, matching, bio, and icebreaker
    authorization. Within each surface, selection, naming, and explanation
    form a strict lattice. Raw Calendar/itinerary evidence is never publicly
    explained, and unconfirmed Calendar evidence cannot enter matching.
22. Directional dyad, bio, and icebreaker outputs snapshot both users' current
    revisions. Either user's change invalidates provisional dyads, bios, and
    unexposed icebreakers. Immediately before first exposure, an icebreaker also
    requires active directional match authorization and current dependencies.
    Once exposed, it is immutable historical message content rather than a
    silently rewritten live view.
23. Recency is versioned by domain, source, and action. Temporal weight and
    timestamp quality stay separate; each run pins one `as_of` clock and
    records rule, status, and policy provenance. Video behavior may decay
    quickly, enduring subscriptions more slowly, and future events use
    anticipation followed by post-event decay. There is no universal
    half-life.
24. Reference migration 004 normalizes typed booked activities/events/dining, keyed
    segment and journey lineage, mirror sources, terminal-only scheduled
    destinations, recurrence state, and all product-surface objects. Its JSON
    firewall is recursive and size bounded; private tables remain default-deny.
25. One immutable source-policy catalog drives the Python adapter and mapper.
    Reference migration 004 applies the same reliability/action policy and historically
    allowed a Calendar mapping only when the observation had an eligible
    allowlisted classification. Reference migration 005 supersedes that compatibility
    path and blocks all Calendar observations from generic
    `observation_mappings`; a current typed travel/booking candidate is the only
    semantic route. Legacy typed rows remain as private audit history, but the
    revision bump makes them non-current and ineligible until versioned
    reclassification and typed-candidate rebuild. Calendar labels are canonical
    and server-controlled, generated from controlled predicate templates and
    active ontology labels, never from raw or client-authored text.
26. HealthKit purpose is an authorization boundary, not a scoring weight.
    An active fitness-service grant permits private owner review.
    `allow_fitness_matching`, `allow_bio_naming`, and
    `allow_icebreaker_naming` are independent, default-off choices; controlled
    explanation is an additional grant and requires the applicable naming
    grant. Health-based dyadic comparison requires active matching grants from
    both users. Revocation invalidates future eligibility
    and dependent provisional output but does not rewrite exposed historical
    messages. Confirmation cannot launder provenance into a broader purpose.
27. Reference migration 005 separates broad private capture from semantic use. Raw source
    rows carry encryption/object-store location, keyed identity, consent
    purpose, retention, and deletion state. Only minimized, versioned Calendar
    or HealthKit projections can enter their respective classifier/builders;
    raw capture is never a generic mapper input. Generic source-row mapping is
    fully closed for both sources. Calendar promotes only through current typed
    candidates; HealthKit permits only the exact closed projection of an already
    validated workout candidate. Typed sleep stops at private coverage and never
    maps.
28. `Shinghei98/Written` commit
    `8203353532dffd5f608df92861fd8a631dc7b7d4`, migration head 0041, is the
    reviewed connector/product-shell baseline. Its flat ontology, latest-ever
    summaries, client-authored discovery JSON, and match-time overlap trigger
    are present legacy paths to adapt or replace; they never constrain the
    semantic contract.
29. Reference migrations 001–006 are a standalone namespace. They are not the
    app's migrations 0001–0006. At the pinned app head, adaptation starts at
    0042+ and maps reference `private.*` to `semantic_private.*`, leaving the
    app's existing `private` schema and privileges untouched.
30. Reference migration 006 makes finalized per-run membership and server-owned
    current projections explicit. Finalized partial, truncated, and delta
    scopes may affirm or update items they actually report, including an
    explicit provider deletion. Only a complete full snapshot may infer
    absence from omission; failed runs and all other omissions remain unknown.
31. App rollout is additive: typed dual-write, shadow computation, conservative
    `legacy_unverified` backfill, owner Memories, canary discovery/profile,
    first-exposure icebreakers, then forward-only legacy revocation. Agreement
    with the old label is diagnostic, not a promotion rule.
32. Rollback is fail-closed and surface-specific. Calendar substring inference,
    broad HealthKit use, client-authored semantic JSON, and the legacy
    creator-overlap icebreaker are never rollback targets. A server-side
    privacy switch must stop promotion and cross-user exposure without an app
    release; omission is the safe fallback.
33. Production raw retention requires KMS/HSM-backed envelope encryption,
    separately keyed lineage HMACs, audited narrowly scoped worker decrypt,
    rotation, and deletion across database, object storage, queues, telemetry,
    and backups. A ciphertext column alone does not satisfy this decision.
34. Prefer an audited exposed `api` schema with explicit PostgREST profile
    headers. Public wrappers, if unavoidable, are minimal security-definer
    functions with pinned search paths and exact grants. Neither
    `semantic_private`, app `private`, nor `ontology` is a client-exposed schema.
35. Current-source ordering is per `(user, source, scope_key)`. A disjoint scope
    cannot supersede another scope, while a multi-scope finalizer locks all
    heads before changing state. Only service-only finalize/fail functions own
    idempotent terminal run transitions; even the service role cannot update
    run status or current pointers directly.
36. A surface fact is an immutable attestation to an exact user revision and,
    for inference, exact score version. Reference 006 retires pre-attestation
    facts without inventing historical provenance and stales their linked ready
    bios/unexposed icebreakers. Regeneration creates a new fact; exposed history
    is never rewritten.
37. Match authorization is a terminal epoch ledger. Participants are immutable,
    epochs are contiguous, and at most one epoch per product match and one match
    ID per unordered pair may be active. Renewal uses a successor epoch;
    revocation and first exposure serialize on the same authorization row.

## Not implemented or intentionally deferred

The remaining items are runtime, deployment, policy, model, or product-shape
choices rather than known packaged persistence gaps.

- The final hub registry and names.
- The production embedding model and dimensionality.
- Learned threshold values beyond the documented preliminary defaults.
- Production connector repositories, all eleven job handlers, adapted
  server-owned cross-user RPCs, and typed iOS wiring. Current UI/RPC shells are
  present legacy components rather than proof of v0.3.1 integration.
- Adapted Written migrations 0042+, clean-install and real
  0001–0041-upgrade contracts, dual-write/shadow metrics, canary cutover, and a
  rehearsed safe rollback. The standalone reference chain does not satisfy this.
- The selected KMS/HSM provider, envelope-key hierarchy, worker-hosting
  environment, decrypt audit sink, rotation schedule, and backup-erasure
  procedure.
- Native Supabase deployment/authentication validation and licensed,
  versioned provider catalogs.
- A scheduled, idempotent retention worker that expires and purges raw-vault
  payloads at `retained_until`; the database field is not an automatic TTL.
- Written approval for the exact YouTube capability configuration; persistence
  support is not the approval itself.
- Native HealthKit permission UX, production purpose-grant integration,
  end-to-end revocation handling, and review of the shipped
  fitness-connection flow.
  Conformance to the documented purpose does not guarantee App Review approval.
- Deterministic renderer integration and presentation-fidelity validation.
- Whether user-local subhubs are displayed in the same UI as global concepts.
- Arbitration when two different model configurations finish against the same
  unchanged user revision. Production scheduling must designate an
  authoritative run purpose before both configurations are enabled.
- Population-factor methods such as MOFA+, which should wait for a larger
  genuinely multi-view cohort.

## Two-head feedback model

Semantic validity and surfacing acceptance must be trained separately.

| Event | Semantic mapping head | User affinity | Surfacing head |
|---|---:|---:|---:|
| Confirm inferred assertion | Positive | Positive | Positive |
| Add existing concept | None unless linked | Strong positive | Positive |
| Add term linked to observations | Strong positive | Strong positive | Positive |
| Remove inferred assertion | No automatic global negative | Unknown | Ambiguous negative + local suppression |
| Restore assertion | No change | Unknown | Removes the local suppression |

The database stores enough context to train a more sophisticated model later.
The packaged feedback learner uses transparent Beta diagnostics for surfacing
only, requires exposure-normalized rejection rates for curator review, and is
never the authority that controls visibility.
