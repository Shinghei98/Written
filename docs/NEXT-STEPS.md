# What happens next: the dyad, and the distillation it is waiting on

**Written 2026-08-14. Every number below was measured on that date rather than
remembered.** Delete a section when it stops being true — this file is a plan,
not a record, and the record is `semantic/JOURNAL.md` and `git log -p`.

## AWS is not running (2026-08-24)

**Access ended at free-tier expiry on 2026-08-22, mid-repair** (`346fc85`'s
note; the owner's direction is not to recharge it for now). CLAUDE.md says
whether AWS is running is a status and lives here — this is that line, and it
was missing for two days. Consequences, all observed in the database:

- **No worker job has been claimed since 2026-08-21.** Jobs queue and sit —
  17 across all types as of the 24th, including one `process_mint_requests`.
- The keep→mint route is therefore paused: a keep files its request and
  nothing drains it until the worker runs again, anywhere.
- The measurement lane is RIS (`docs/RIS-DEPLOYMENT.md`); the AWS lane stays
  in the tree and stays correct, per CLAUDE.md's standing entry.

Delete this section when the account is recharged and a worker invocation has
been observed claiming a job.

## Where things actually stand

| | David | Timi | Demo |
|---|---|---|---|
| live assertions | **99** | **0** | 66 |
| observations | 6,311 | 944 | 2,085 |
| sources in the vault | apple_calendar, apple_music, google_calendar, music_library, outlook_calendar, spotify, youtube | apple_calendar, google_calendar, youtube | apple_calendar, apple_music, google_calendar, music_library, youtube |
| last ingestion run | 2026-08-14, `ios-1.0+49` | 2026-08-13 | 2026-08-12 |

The only authorised pair in the system is **David–Timi**: she liked him on
2026-08-14, he accepted, and `public.conversations` went from zero rows to one.
That match is the expensive part and it already exists.

The one dyad run so far is `stale`, `general_social`, **0 alignment pairs** —
correct rather than broken, because Timi has no assertions to align.

## 1. Waiting on one tap

**Timi has not installed 49.** Her newest run is the 13th and carries no
`spotify`, which is the whole reason her page is empty: `dualWriteToVault` gates
on `AppConfig.semanticIngestionSources`, Spotify entered that set at `a3a4c9c`
on 2026-08-13, and her binary predates it. Her 593 Spotify rows are safe in
`public.distilled_records` — append-only — but they have never reached the
vault.

**She has installed 50 and tapped, and the vault still received nothing.**
Measured 2026-08-14 17:00: she distilled Spotify at **16:53:45** — the legacy
path recorded it (`source_connections.spotify.last_distilled_at` moved, and
nothing appended, the 593 rows being unchanged) — and the vault has no
`spotify` ingestion run, no `raw_source_records`, and **944 observations,
unchanged**.

**The fact that narrows it: no ingestion run has ever been stamped
`ios-1.0+50`, by anybody.** `connector_version` is
`ios-<CFBundleShortVersionString>+<CFBundleVersion>`
(`SemanticIngestionService.swift:194`), the highest recorded is `+49` from
David at 15:04 on the 14th, and Timi's newest is `+47` from the 13th. So either
the binary is not 50, or a build-50 dual-write is failing before it reaches the
endpoint. `reportCoverage` is `#if DEBUG` print-only, so a refusal leaves no
server trace to read.

**The next move is one launch, not one tap.** A transiently failed batch
persists in `PendingEnvelopeStore` and `flush()` retries on the next launch. So
ask her to open the app and nothing else:

- an `ios-1.0+50` spotify run appears → it was transient and she is unblocked;
- nothing appears → the batch was refused permanently (a 4xx is dropped by
  design) or the binary is not 50, and the next thing needed is a console log
  from her device rather than another tap.

**`AppShell`'s `.task { viewModel.purgeArchivedSources() }` must stay commented
out** (`Views/AppShell.swift:209`). It is, and has been since `f63f338` on the
10th. Live, it wipes each Spotify distillation moments after it lands.

**Then confirm it landed**, which is now answerable from the database rather
than inferable:

```sql
select connector_version, source_code, started_at, status
from semantic_private.ingestion_runs
where user_id = '7046df73-…'
order by started_at desc limit 5;
```

Expect `ios-1.0+49` or later and `spotify`. Builds 47 and 48 were both
ambiguous — 47 named two different codebases and 48 never appeared in any
ingestion run nor in any commit — which is why 49 exists.

Then let the worker drain: the EventBridge rule `written-semantic-worker-drain`
fires every two minutes and is confirmed firing, so her assertions should appear
without anybody invoking a Lambda.

### The risk worth naming before it is measured

**944 observations and zero assertions is not only a Spotify problem.** Her
vault is calendar and YouTube, and neither can carry a claim alone: Calendar
promotes a handful (5 of 101 for David — the `excluded_unknown` majority is the
allowlist working), and YouTube may raise a concept's strength while never being
the only reason it crosses to another person
(`concept_has_non_video_witness`).

So Spotify is what should give her a first witness — and **whether her music
resolves at all is the open question.** The creator vocabulary was minted from
one Apple Music library, David's, and when her account was first measured the
resolver hit 3 of 152 uploader tags. If her taste overlaps his she will resolve
well; if it does not, she may gain few concepts and the dyad may still be thin.

**That is a finding either way**, and it is the other half of what `0134`
settled: *vocabulary was never the binding constraint, evidence was.* This tests
the sentence from the other end.

## 2. Testing the dyad

`produce_dyad` is worker-only and revoked from every client role, so it is run
from a migration's `DO` block — MCP cannot execute it and neither can the app.

```sql
select semantic_private.produce_dyad(
  'eb769605-…'::uuid,   -- viewer
  '7046df73-…'::uuid,   -- subject
  'icebreaker'
);
```

**What to check, in order:**

- the run reaches `succeeded` rather than `stale`, and writes alignment pairs;
- `explanation_path` names a bridge and a term on either side;
- David's assertion count stays at 99 — nothing else moved;
- **`specificity` × `information_value` puts a specific creator above a
  container.**

That last one is the real test and the reason to look at the numbers rather than
the count. A bridge on `genre:asian_music` is nearly free — anyone who likes
K-pop *or* J-pop *or* Cantopop shares it, and it scores 0.942 as a parent of four
genres it also scores alongside. **If a container outranks a named artist, the
provisional formulas in `0164` need replacing before a single frame is
rendered from them.**

### The three questions the spec left open

`semantic/docs/ICEBREAKER_FRAMES.md` is the full specification. Three decisions
in it are still unmade and all three want real pairs to decide against:

1. **What makes a bridge worth saying?** `information_value` is the column and
   nothing computes it. A bridge four people in five share is not a
   conversation.
2. **How far may a bridge sit from a term?** One `broader` hop is *"you both
   like anime"*; four reaches `hub:music`, which is true of everybody with a
   library. `graph_distance` is recorded and the cap is undecided.
3. **May both sides bridge on the same term?** The sentence shape assumes a
   difference, and identical terms are exactly the case the legacy path handled
   by collapsing — which is what made it dull.

**A fourth is not open and must be honoured:** a bridge is shown to the *other*
person, so III.E.3.b applies and `concept_has_non_video_witness` has to gate it,
the same rule `matching_terms` follows rather than the looser one Memories gets
as the owner's own page.

## 3. Then Phase 5 and Phase 6

- **Phase 5 — the frame builder.** Ingredients in SQL, language in Swift: the
  producer does set intersection and knows no English, and the renderer picks
  the verb. *"You both like Italy. Timi likes Italian food, ask her about it!"*
  Provisional until seen and **frozen once exposed** — a frame somebody has read
  is what they were told, and rewriting it later would make the record of a
  conversation disagree with the conversation.
- **Phase 6 — the cutover**, where the server-owned surfaces replace the legacy
  ones and `api.discover_profiles` comes out of the dark. **It is already out
  of it**: `discovery_profile_reads` was piloted to one account on 2026-08-13
  and enabled globally on **2026-08-14 19:30 UTC**, verified against
  `semantic_private.feature_flags` on 2026-08-23 with the kill switch down and
  the single per-user override also true, so the flag resolves true for every
  account. The RPC answers and the client is no longer falling back. **The
  asymmetry is still the safety property**: flag off falls back to the direct
  read, flag on and failing does not, because a fallback on error would quietly
  restore the unauthorised path. What remains of Phase 6 is retiring the legacy
  readers behind it, not turning the flag on.

## 4. The blocked decision, if she cannot install

Getting her rows into the vault without her device is `tools/snapshot_distillation.py`
for the reading half — committed and working — and then a way to write them,
which is blocked on **one decision rather than on code**.

Ingestion takes `user_id` only from a verified ES256 token carrying
`role: authenticated`, and **both accounts are phone-only**, so no token can be
minted for them (admin `generate_link` is email-only). The two ways in:

- **a second auth door on ingestion**, gated on `private.collaborators` — the
  shape `functions/push` already uses with `x-push-secret`; or
- **temporarily attaching an email** to the account.

The first is the one I would build, because it is reusable and the second is a
change to somebody's identity made for our convenience. **It has not been
decided and nothing should be built until it is.**

**This whole section is a symptom of the standing rule** (owner, 2026-08-14):
the team has consented to their data being used for training and **nobody
re-distils for us**. Four changes in two days were paid for by asking somebody
to open the app, and one of them silently did not work for a week. A change that
needs data re-projected is ours to solve server-side; *"ask them to distil
again"* is a bug report about us.

## 5. Two things that must not be forgotten at launch

Neither is next, and both are one line each, which is exactly why they are easy
to miss.

- **Spotify comes out of `AppConfig.semanticIngestionSources`.** It is live for
  the data-collection prototype only. IV.2.1.a forbids ingesting Spotify Content
  into any model and IV.2.5 closes the consent route explicitly — *"even if a
  user consents"* — so a collaborator's agreement can never make it available
  for training. Removing it is one line there; **deleting what was already
  captured is separate and deliberate.**
- **`AppShell`'s `.task { viewModel.purgeArchivedSources() }` is commented out**
  and must be restored in the same breath, or it wipes each Spotify
  distillation moments after it lands.

## 6. The mint runs, 2026-08-15

`0176`–`0179` are applied, the worker carries the `mint_vocabulary` handler, and
`APPLE_MUSIC_DEVELOPER_TOKEN` is set. **First successful mint: 599 identifiers
looked up, 285 creators minted, 78 linked, 4 refused, ontology `0.22.1`
published.** `ontology.external_entities` went from zero rows — it had never held
one — to 931.

**Provenance is being recorded and the skew is the launch plan's problem, not a
bug**: 773 identifiers were named by Spotify and 160 by Apple Music. `0178`
exists so that stays knowable; the plan of minting from Apple and only *reading
against* it with Spotify needs those 773 to be reachable another way, and today
they are not.

Three things that fell out of getting there, none of them fixed by the fact that
it now works:

- **`APPLE_MUSIC_DEVELOPER_TOKEN` expires 2027-02-11.** It is a static ES256 JWT
  minted from MusicKit key `AZ69CPT7DG` against team `947DHTL37S`. **An expired
  token raises, where a missing one declines** — by design, since silently not
  enriching is the failure this work removed — so expiry day is a day mint jobs
  start dying. Minting per invocation from the `.p8` in Secrets Manager, the way
  `DB_SECRET_ID` already works, removes the cliff and is a small change to
  `catalogue.py`.
- **`ComposerService.isrcsPerRequest` is 100 and Apple's cap on `filter[isrc]`
  is 25.** `tools/apple_catalog.py` had the same value, took a `40005` on every
  batch, and is fixed. The app asks the same filter on the same endpoint, so the
  composer pass is very likely taking the same 400 on every real library.
  **Unverified on device** and it needs a build to check.
- **`SemanticWorker` records the literal string `handler_error` and discards the
  exception** — right for a durable row that may hold no plaintext. `handler.py`
  already compensated for `recompute_user` with `_diagnostic`, which logs type,
  sqlstate, constraint name and the two messages that are safe to quote; the
  mint had no such wrapper and its failures read as nothing at all. It uses the
  same helper now. **The first version printed `traceback.format_exc()`**, which
  is what `_diagnostic`'s own comments forbid — a traceback carries the failing
  statement and psycopg quotes the offending value, and here that value is
  somebody's decrypted library.

### Hearthstone landed, after three walls

Confirmed 2026-08-15 on David's account: `Hearthstone`, `work`, eligible, from
Kripparrian's channel keywords — `memories` open, `matching`/`bio`/`icebreaker`
shut. Build 52 was necessary and, on its own, insufficient; three separate
things stood behind it, each hiding the next.

- **`0182` — a veto cost the whole run.** `guard_youtube_assertion_evidence`
  raised on a YouTube-witnessed assertion holding `can_select` on a shared
  surface, aborting the transaction and freezing every assertion the account
  had. It shuts the permission instead now, which is `0128`'s own principle one
  table further along. **`work:hearthstone` is the first assertion this system
  has ever had whose only witness is YouTube**, which is why it was the first to
  reach that trigger with the permission still open.
- **`0183` — the guard could not shut what it could see.** A trigger runs as its
  caller and `semantic_worker` deliberately holds no `update` on
  `assertion_surface_permissions`. The guard is `security definer` now; the
  worker's grants are unchanged, asserted both ways.
- **`0184` — the alias could never have matched.** `0149` stored each concept's
  key as its own alias verbatim, so `work:hearthstone` sat where the resolver
  computes `work hearthstone`. **All three game works have been unmatchable
  since `0149`** and nothing reported it. Of 31 active colon-bearing labels
  exactly three were wrong, which is how they were found.

### The guard that had never run

`0179` is worth reading before anything else touches `publish_version`. Fourteen
`broader` edges written by `0076` claimed `provenance_type = 'external'` with no
external entity to resolve — in a table that had never held a row — and were
carried into every version since 0.4.0. **`publish_version` had been called twice
in the repository's history** (`0044` and `0177`); thirty-five migrations set
`status = 'published'` directly. So the mint was the first thing to ask the guard
a real question, and it answered correctly.

**The repair could not be an `update`.** `guard_published_version` makes a
published version immutable, correctly — it is what everything was scored
against. So the fix is a version: `0.22.0` copies `0.21.0` forward with the
fourteen retyped `curated`, published through the guard, at the cost of a
recompute for every account that an in-place edit would not have charged.

## 7. AWS is shut down, and what that strands (2026-08-24)

**The owner's decision, 2026-08-24: AWS is off permanently for now — it was
never paid for past the free tier.** RIS is the only lane. Measured against
production the same day, here is what that actually costs.

**Nothing that blocks the pipeline.** RIS reads `public.distilled_records`,
which is plaintext at rest and holds the complete distillation — **6,788 rows,
intact**. It is *more* complete than the promoted projection, so extraction,
scoring and the dictionary are unaffected.

**What is stranded, and it is not small.** `semantic_private.raw_source_records`
holds **22,361 rows, of which 6,392 are encrypted** under ~155 per-account data
keys. Those keys are wrapped by a KMS key that is now unreachable, so **those
6,392 payloads can never be read again.** That is an unintended mass crypto
erasure: the mechanism worked exactly as designed — *"deleting one wrapped-key
row makes that person's evidence permanently unreadable"* — applied to everyone
at once by losing the key above them. The 17,758 observations derived from them
survive, because those were promoted before the vault closed.

**A deferred repair became permanent.** `ris_link_observations.py` refuses
ambiguous pairings rather than guessing, and its residue — 832 Spotify rows
sharing a title and performer, 298 calendar events differing only in a stripped
field — was documented as fixable by *one* KMS `GenerateMac` call, which would
recompute every `source_item_hmac` and join exactly. **That call is no longer
possible.** The residue is now the final answer, not a to-do.

**The app will now fail its dual-write, quietly and by design.**
`AppConfig.semanticIngestionSources` still carries `apple_music` and `spotify`,
and the ingestion Lambda they post to is gone. Refusals are counted rather than
swallowed and a permanent refusal is dropped rather than retried, so the app
keeps working and the legacy `distilled_records` path is untouched — but nothing
new reaches the vault. Last write: **2026-08-23 15:43 UTC**. Decide whether to
empty that set, which would stop the attempt rather than let it fail every time.

**What does not change.** The AWS code stays in the tree and stays correct; the
published privacy policy still describes the AWS path as the one real users' data
flows through; and third-party terms still bind. None of those lapse because the
account did.

## 8. Known gaps

**Moved out of `CLAUDE.md` on 2026-08-24**, where they had been sitting under a
heading dated 2026-08-13 that said *"Delete an entry when it stops being true"* —
in a rules file that has no mechanism for noticing when something does. They are
a plan, so they live here. Every entry below was **re-checked against production
on 2026-08-24**; three had changed and are marked.

Ordered by what hurts soonest.

### Live now

- **Every account's Memories page is blank, and this is the recompute gap in its
  finished form.** Measured 2026-08-24: all three accounts have **0 active
  assertions**, inferred *and* declared, against CLAUDE.md's standing claim of
  "65 active assertions per account" from 2026-08-12. One account sits at
  **revision 665**. Nothing enqueues a recompute when somebody answers a claim,
  so a suppression correctly stales every inferred assertion and the page stays
  blank until the worker is run by hand — and nobody has. **The fix is one job
  per *user*, keyed on the revision and the three analysis ids, not one per
  tap.** Until then the main surface is empty for everyone.

- **Live drift: the app offers two archived sources.** Verified 2026-08-24 and
  still true: `Modality.swift:147` returns `youtube` and `:198` returns
  `google_calendar`, directly beneath `ARCHIVED-YOUTUBE` and
  `ARCHIVED-GOOGLE-CALENDAR` markers saying both were removed for the App Store
  build. Anything shipped from this tree offers a reviewer both, and both 403 for
  accounts off the Testing allowlist. **Close it deliberately, in one direction
  or the other, before any upload.**

### Advanced since the list was written

- **Notifications on production: half proven.** The first half is now done —
  **2 `device_tokens` rows read `production`** (2026-08-24), where the entry was
  written when there were none. What remains is the second half: send one message
  and check the face still arrives. `sent: 2` with `["ok","ok"]` to somebody with
  two devices is the only proof both environments work.

- **~~`birth_date` has never been observed reaching Postgres~~ — resolved.**
  All **3 of 3** accounts carry a `birth_date` (2026-08-24). The age gate reaches
  the database. Entry closed.

- **`semantic_private.discovery_requests` is still unswept**, but the table holds
  **0 rows**, so it is a missing sweep rather than a growing one. Cheap to add
  before it matters; not urgent until the surface has traffic.

### Standing

- **Nothing lists a suppressed assertion**, so restoration is reachable only as an
  undo in the moment and a mis-tap is permanent. It wants a server decision — a
  second RPC or a parameter — and the question underneath is what somebody is owed
  over their own profile. There are **8 active suppressions** today.
- **Exposures are recorded when an answer is given, not when a row is drawn**, so
  `assertion_exposures` cannot answer *"what was shown and not acted on"*, which
  §10 lists among the shadow metrics.
- **Connecting Google Calendar on a phone that already has the Google account
  duplicates every event, and it has happened.** The guard behaved as designed and
  its design has the hole: `hasGoogleAccountOnDevice()` returns false when calendar
  access has not been granted, and that is exactly the person being offered Google
  Calendar. Decide it after Apple Calendar is connected, or re-decide once access
  exists.
- **The assertions have been read down the strong end and not to the bottom** —
  confirmed to 0.362, the concept nearest the 0.35 bar; the middle is unread. One
  thing to check: **`genre:asian_music` is a container in all but name**, parent of
  four genres it scores alongside, and the hub rule cannot catch it because its
  kind is `genre`.
- **Whether HealthKit habit candidates are within the grant is unanswered**, and
  moot until a device records workouts.
- **App Store privacy labels are not filled in.** **The three answers that must
  agree are `PrivacyInfo.xcprivacy`, `web/en-us/privacy/` and the questionnaire**,
  and none of the three checks the others.
- **Identity linking is unbuilt** — three sign-in methods mean one person can hold
  three accounts. Decide before launch.
- **A failed record upload is recorded but undrawn** (`syncFailure`).
- **A declined Workouts toggle is indistinguishable from no workouts.**
  `health_sports` being empty is otherwise settled and correct. One line in the
  distiller's `Trail` would settle the rest.
- **A clean-device sign-in writes nine duplicate `user` rows, and
  `append_source_records` cannot prevent it.** `flirt_level` and `response_time`
  are each pushed **three times in one batch**; because the batch shares a
  transaction timestamp, each row is compared against the *pre-existing* latest and
  none of them sees its siblings, so all three insert. The function is behaving as
  designed — **the fix belongs on the device, which should not send the same record
  three times.** Contained: 9 rows out of 2,650, nothing outside `source = 'user'`.
- **A slider's exact position does not survive a new device, only its band.**
  `public.users` stores `flirt_level = 'Medium'` and `response_time = 'Allegro'`;
  the continuous position lives only in a `distilled_records` row, so a clean device
  re-derives it from the band's default and pushes a different number (0.309 became
  0.375). Harmless for the four-band reading everything downstream actually uses,
  and a real change to a value somebody set by hand.
- **CAPTCHA is off for phone sign-in**, with the 10/hour SMS limit standing in.
- **`SourcePayload+Legacy.swift` is scaffolding and is meant to be deleted.** Still
  present at `Written/Models/SourcePayload+Legacy.swift`.
- **Apple Podcasts ships with its central question unanswered: does it
  auto-download episodes of followed shows?** Settle it by following a show on a
  device, downloading nothing, and looking again. **An empty source that looks
  connected is worse than none.**
- **Outlook Calendar is absent, not disabled, until `AppConfig.microsoftClientID`
  is real**, and is on the legacy `distilled_records` path only until exercised
  against a real tenant.
- **The contacts toggle promises more than it does.** `importContacts` takes names
  only, so *"people you already know cannot see you"* is true of nothing. Closing
  the gap means uploading contact identifiers, which needs `PrivacyInfo.xcprivacy`,
  `web/en-us/privacy/` and the App Store questionnaire moving in the same commit.
  **`block_by_phones` is deployed with no caller** for exactly that reason.

### Deferred by decision

**Google OAuth verification, deferred until the hubs exist** — submitting earlier
means shooting the demo video against a pipeline about to be replaced, and the same
form carries the derived-metrics request. **Nothing about that defers the policies
themselves.** Two traps: Search Console must be verified as a **Domain** property
signed in as an Owner of the Cloud project (verifying as the wrong account is the
standard rejection and Google does not say so), and the consent screen must carry
the two URLs **character for character**, matching `SignInView.swift` — not
`/privacy`, which 301s, and a redirect is not agreement.

**The Disconnect control has never been exercised against a real Google account**,
and the published privacy policy makes a 7-day claim resting on it. That has to
happen before YouTube comes back.

**Bringing YouTube back needs three things, each weeks rather than days:** extended
quota (requesting it triggers an audit), OAuth verification (Testing allowlists 100
users and expires refresh tokens after 7 days; publishing needs a Search Console
Domain property, a scope justification and a demo video), and — for the ontology
stage — Google's **Content Categorization and Tagging** amendment, applied for on
the same form. **Do not apply while running the unlicensed version of the thing
being applied for.**
