# What happens next: the dyad, and the distillation it is waiting on

**Written 2026-08-14. Every number below was measured on that date rather than
remembered.** Delete a section when it stops being true — this file is a plan,
not a record, and the record is `semantic/JOURNAL.md` and `git log -p`.

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
  ones and `api.discover_profiles` comes out of the dark. It ships behind
  `discovery_profile_reads`, which is false, and **the asymmetry is the safety
  property**: flag off falls back to the direct read, flag on and failing does
  not, because a fallback on error would quietly restore the unauthorised path.

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
  exception** — no message, no traceback, not even to stdout. Two failures that
  night were invisible until `mint_vocabulary` was made to print its own
  traceback before re-raising. Every other handler still has that hole.

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
