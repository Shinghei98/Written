# Semantic pipeline — the working journal

**This is the record of how the semantic pipeline was built, not the rules it
runs by.** The rules live in `CLAUDE.md`'s *"The semantic contract"* section,
which is loaded into every session; this file is not, and is meant to be read
deliberately.

**Read it when:** a semantic component behaves in a way the rules don't explain;
you are adapting another reference migration; you are about to re-derive a
decision that looks arbitrary; or you want to know *why* a guard exists before
removing it.

Everything here was true when written and is dated where it matters. Where a
paragraph has since been overtaken it is marked **superseded** rather than
deleted — the reasoning is still worth having and the correction is the point.

---

## Phase 0 — installing the schema

### The clean replay, and what it corrected

**The hazard is the grant, not the revoke** — the obvious reading is wrong, and
it took a clean replay to find out. Reference `001` revokes `service_role`'s
usage on `private`; measured on a from-empty install, `service_role` never had
it (`has_schema_privilege` answers false), and push works anyway because
`private.notify` is `security definer` and runs as its owner. What bites is
reference `002` **granting** `service_role` usage plus `select, insert, update`
on every table in the schema — widening access to `push_config`, which holds the
shared push secret, and to `collaborators`, which was put in an ungranted schema
precisely so nobody could mark themselves. "An adapted grant broadens access" is
the integration plan's own failure condition.

**Which is also the argument for the replay itself.** Applying 41 migrations by
hand over weeks never proved they build a schema from nothing. Done once against
an empty project, the chain applied cleanly — and produced the measurement that
corrected this paragraph.

### The ledger, which was absent rather than empty

`supabase_migrations` was absent entirely — not empty, *absent* — because every
migration had been applied by hand, so `supabase db push` would have tried
`0001` against a full database. `supabase migration repair --status applied
0001 … 0041` came first, and `0042`–`0049` were deliberately left unrepaired
because they genuinely had not been applied.

**`0050` went the same day on `db push`** — one pending migration, one push, no
ledger work — and the checks came back right: RLS on with no policy, no client
role reaching it, zero rows, and the `private` ACL fingerprint identical either
side of the push. Nothing about the product changed at that deploy: all seven
feature flags were seeded off, nothing in Swift read the new schemas, and the
legacy path was untouched.

> **Superseded.** A later paragraph in CLAUDE.md continued to say *"this project
> has no migration ledger at all — `supabase_migrations` is not an empty schema,
> it is an absent one"* for weeks after the repair above made it false. It was
> the argument for deferring cutover. The deferral still holds on its other two
> reasons; the ledger one does not.

### What `0048` had to carry

Historical now — `0048` is long applied — but the reasoning is the model for any
future migration that joins the two worlds. `0042`–`0047` reference `auth.users`
31 times and legacy `public.*` tables zero times, so the semantic schema was
completely decoupled and `0048` was the single point where the two met. Its
load-bearing change was a foreign key: `0042:482-484` constrained
`(ingestion_run_id, user_id, source_code) → ingestion_runs`, which *encodes* the
provenance defect — an observation's source must equal its run's source, so a
`user` row inside an Apple Music batch is stored as Apple Music evidence.
`connector_source_code` and a repointed FK are what fixed it, and
`finalize_ingestion_run_v031` (`0047:526`) had to be replaced to partition by
record source.

---

## Phase 1 — capture

### Choosing AWS, and the argument that was half wrong

The recorded reasoning was that a Deno function on Supabase needs a long-lived
AWS key in its environment while a Lambda assumes a role and needs no credential
at all. The first half holds; the second does not. **A Lambda cannot reach
`semantic_private` either** — RLS is on with no policy and `authenticated` has no
usage on the schema — so a write needs a Postgres credential. Hosting on AWS does
not remove the standing secret, it changes which one it is, and the two are not
equivalent: a leaked encrypt-only KMS key writes rubbish into the vault and
decrypts nothing, while a leaked `service_role` key reads and writes every table
in the project. On that reading the edge function was the *safer* host.

**`0052` is what makes AWS right rather than merely chosen.** The endpoint gets
`semantic_ingestor`, a Postgres role that can call exactly one `security
definer` function and holds no table privileges. Leaked, it writes vault rows and
reads none of them back.

The cost of AWS is verifying Supabase tokens ourselves, which is smaller than it
sounds — the project publishes a JWKS (confirmed live, one `ES256` key), so any
JOSE library verifies an access token against a public key **with no shared
secret**, and the user id is its `sub`.

### Proven by connecting, and the route was the risk

The direct host `db.<ref>.supabase.co` has **no A record at all** — IPv6 only —
while Lambda's egress is IPv4, so the shared pooler is the only free route, and
Supabase documents its username as `postgres.PROJECT_REF` while saying nothing
about custom roles. That was the premise the whole design rested on.

Settled 2026-08-10 on the transaction pooler: `current_user` came back
`semantic_ingestor`, and reading `raw_source_records` came back **permission
denied** — which is the success case, and the entire argument for `0052` existing
rather than handing the endpoint `service_role`.

Two smaller things fell out: a project's pooler fleet is discoverable with a
*deliberately wrong* password, since Supavisor resolves the tenant before
checking it and the two failures otherwise look equally like an outage; and
transaction mode does not support prepared statements.

### `0053` — why the data key is per call

A structural gap rather than an oversight. Three correct facts left no way to
encrypt anything: ingestion holds `GenerateDataKey` and `Encrypt` and **not**
`Decrypt`, because §12 limits decrypt to the worker path; `0050` models one
*active* wrapped key per user, to be reused; and `0052` gives the role execute on
one function that cannot touch the key table. **A stored wrapped key is unusable
to the identity obliged to encrypt with it** — recovering it needs `Decrypt`, and
giving ingestion that would collapse the two-identity split that is the whole
point. `kms:Encrypt` on the payload is no escape either: it caps at 4 KB.

So the per-call data key is inherent to a write-only identity rather than a
choice — it cannot reuse what it cannot recover, and a Lambda is stateless.
`0050` already anticipated the shape: *"Retired is not deleted: rows encrypted
under it still name it."*

Two traps in that migration, both paid for. **`revoke ... on schema public` from
one role does nothing**: usage there belongs to the `PUBLIC` pseudo-role, and
revoking it from `PUBLIC` would take it from `anon` and `authenticated` too. The
property that matters is the *table* count, not the schema flag. And the
`security definer` function is what avoids adding `semantic_private`'s first RLS
policies — a posture of "RLS on, no policy, everywhere" states in one sentence
and a posture with two exceptions does not.

### `0054` — a value that changes every pass makes a check vacuous

Two findings from the second real run, both the same shape:

- **A pure-duplicate batch was still recording a key.** Re-sending the unchanged
  1,225 rows stored nothing and wrote three more wrapped keys; four of nine
  protected nothing. `0053` accepted that trade on the grounds it would be rare,
  and it is not — key rows would grow with how often somebody distils rather than
  with what they have. `0054` writes the key *after* the rows and only if any
  survived the conflict, which is free because the function is one transaction
  and there is no foreign key demanding the key exist first.
- **`ingestion_run_live_identity_idx` can never fire.** A unique index on
  `(user_id, source_code, input_hash, connector_version)` over live runs — the
  contract's guard against opening a second run for the same input. Our
  `input_hash` is a SHA-256 over the *encoded records*, which carry `observed_at`
  and `ingestion_id`, so it differs every run and the index has nothing to catch.
  Making it content-based is not a safe fix on its own while runs linger open.

### Bringing dual-write up

Apple Music went first, 2026-08-11: **1,225 rows in three batches**, 1.07 MB of
AES-GCM ciphertext, one ingestion run, three wrapped keys.

**Eight of ten data types matched the legacy count exactly.** The two that did
not are both the comparison's fault rather than the pipeline's:

- **`distilled_records` is append-only across every run**, so comparing against
  the table counted history. Read through `summary_*`.
- **The summary view is a *union of items across runs*, not a snapshot.**
  `recommendation` reads 266 there against 171 in the vault because Apple returns
  a different set daily and the union keeps them all.
- **The legacy path stores only *changes***, so this run wrote 118 legacy rows
  against the vault's 1,225 first-sight rows. Neither number is wrong and they
  are not comparable. The comparison that means something is the *second*
  distillation.

**Coverage against every row production has ever held: 6,148 of 6,148 derive**,
none unmapped. 6,082 carry an action the server weighs, 61 are structurally not
acts, 5 are `location/place`. The comparison is printed, not stored — there is no
consumer, and giving it a table would be building Phase 2 early in a codebase
whose standing defect is results nobody reads.

Calendar: 109 rows — 101 events, 8 calendars — event count matching the legacy
path exactly. HealthKit: 390 rows — 366 `activity_day`, 24 `activity_hour` —
matching exactly, no `workout` rows because no test device has an Apple Watch.

### The vault read back, and the `_0` defect

**1,227 payloads had been encrypted and not one decrypted**: if the crypto were
wrong the vault would be garbage and nothing anywhere would say so. Measured
2026-08-11 — KMS unwrapped the data key **with the encryption context**, which is
what proves the per-user binding rather than merely the cipher; AES-GCM
decrypted; the envelope parsed.

**And the first row ever read back showed a defect.** Swift's synthesised
`Codable` for an enum puts the associated value under `_0`, a *compiler* detail,
and that was the wire form in the vault. Three reasons it mattered: the reader is
Python and would have to know a Swift convention to find the payload; the vault
is append-only and the ingestion identity has no `Decrypt`, so a row's encoding
can never be rewritten; and if Swift changed that convention, old rows would
silently stop matching new code.

**It doubled the vault, and that was the price of the v2 wire form.**
`record_fingerprint` is computed over the payload, so changing the encoding
changed every fingerprint and the whole library re-stored as new rows — 1,227
became 2,441. Paid once, at 1,225 rows, which is the cheapest it was ever going
to be.

**The fingerprint no longer depends on the encoding, which is the actual fix.**
`fingerprintContent` unwraps the payload's discriminator and drops
`schema_version`. The near-miss inside that change is the part to remember: its
first version reduced any unrecognised payload shape to its first key, so
`{title}` and `{title, playCount}` hashed the same — a changed record skipped as
a duplicate and lost, which is the worst failure this function has.

### The HealthKit grant, before it existed

Kept because it is why `FitnessPurposeGrantService` exists.
`guard_raw_healthkit_grant` refuses an active HealthKit row unless
`healthkit_use_grants` holds an active grant, and there were none. Enabling the
source then would have had every batch refused and — because
`SemanticIngestionService` drops a permanent refusal — the data would have
vanished quietly. Writing a grant unasked would be fabricating consent, which is
exactly what that fail-closed guard prevents. It was a product decision before it
was a technical one. `0061` is the answer.

---

## Phase 2 — promotion

### Runs finalize, and finding out what that needed was the work

Before `0055`, production held 1,227 encrypted rows, seven runs all still
`running`, and `current_source_items`, `observations` and `ingestion_run_items`
all empty: capture was built and promotion did not exist, so nothing downstream
could tell that any row was *currently observed*.

`finalize_ingestion_run_v031` refuses a run with no **scope manifest**, counts
`ingestion_run_items` per scope, advances `source_state_heads`, updates
`current_source_items`, mints a revision and enqueues a worker job — and
`ingest_source_records_v031` wrote neither scopes nor items. `0055` adds both and
calls the finalizer on the batch the client marks `final`, **from inside** rather
than by granting it, so `semantic_ingestor` still reaches exactly one function.

**And `0055` could throw away a whole batch, which the first probe after it did.**
A run of entirely unpromotable rows has no scope, the finalizer refuses that, and
because finalization shares the insert's transaction **the rollback took the
captured rows with it** — production went from seven runs to seven and stored
nothing. Not a probe defect: every `user` distillation has that shape. `0056`
finalizes only when the run has a scope.

**Proven on a real distillation.** Apple Music finalized with 9 scopes, 9 heads,
1,224 run items, 1,224 `current_source_items` and one worker job — 1,224 against
1,225 captured. `user/apple_music_subscription` promoted **zero**, because a fact
about an account is not an act. The rule shows up as an integer.

### `partial` earning its keep on the first occasion it could

**An Apple Music distillation is sometimes partial and reports success either
way.** Two consecutive runs: 17:01 returned **four** data types and 17:08
returned all **nine**. Nothing was dropped in transit; the endpoint logged zero
refusals and the batch counts matched. The distiller simply returned less —
`distill` fires nine requests concurrently and every one is
`(try? await task) ?? []`, so a failed request is indistinguishable from a person
who owns nothing.

Three endpoints failing cost five data types, because two feed later work:
`library/songs` also carries `rating`, and `library/playlists` also carries
`playlist_item`. Why those three failed is still unproven — the error was thrown
away — but the shape points at throttling rather than a permission state, since
two library endpoints succeeded while three did not.

**Had those scopes been declared `complete`, finalizing the 17:01 run would have
expired five entire data types from current state** — 714 items, silently. §10's
"partial runs cannot infer absence from omission" is not a formality; it is the
difference between a bad afternoon for one connector and somebody's library
disappearing.

### The worker, and moving projection out of it

`0057` gives it `semantic_worker`: `bypassrls` and an enumerated grant list.
Policies would have been the wrong tool: RLS here is keyed on `auth.uid()`, which
a batch processor with no JWT can never satisfy, so a policy for this role could
only be `using (true)`.

`aws/worker` is the **vendored package**, not a reimplementation: `SemanticWorker`
and `PostgresJobQueue` come from `written_ontology`, with its lease tokens,
attempt limits and fail-closed unhandled-job behaviour already tested.

**`project_user` was removed from the handler in Phase 2**, which is the second
half of `0059`: `guard_observation_ingestion_run` takes a `for key share` lock on
the run, needing `update` on `ingestion_runs` on top of `select` — and a worker
that could update a run could mark somebody's capture complete. The privilege was
the visible half; the real one is that an observation belongs to the run that
captured it. It failed every invocation with `42501` and took the whole job down
with it, which is how it blocked the fitness snapshot behind it.

**Two packaging traps, both paid for.** `typing_extensions` must be named
explicitly — psycopg 3 needs it below Python 3.13 and pip drops it under
`--platform`, surfacing as the package's own *"install the postgres extra"*
message, which swallows the real `ImportError`. And wheels must be resolved for
`manylinux2014_x86_64`, or an Apple machine bundles arm64 binaries that fail at
*import* in a way that reads like a typo. `build.sh` now checks the staged tree
for every expected module, so both fail at build rather than at invoke.

### The zombie runs, and how they were drained

Twelve runs left `running` with zero scopes, holding 1,232 rows, the oldest from
2026-08-11. `0099` stops the leak; `0100` drains what it left, **every one closed
through `close_unpromotable_ingestion_run`** rather than by an `update` — the
function refuses a run that has a scope, and writing the same status by hand
would bypass the one check that makes it safe.

**The apple_music run holding 1,225 rows lost nothing.** Its rows are the v1
payload encoding; every one was re-captured under v2 when the wire form changed,
so the content exists twice and only those copies are inert.

### Phase 2's four bullets

§8 asks for four things. All four closed 2026-08-12, on two accounts.

| | |
|---|---|
| backfill | **a no-op, by doing rather than arguing.** §7 prefers a fresh distillation to an import, the only account with legacy rows and no vault presence was Demo, and Demo distils from the same device. Re-distilled instead: 2,583 rows, 7 sources. |
| classifiers and worker | running for both accounts, all sources |
| shadow comparison | `tools/shadow_compare.sql` |
| the human review | the owner read every Calendar promotion; all right |

**The phase's outputs moved three times in the hour it closed.** Spheres, scenes
and composer periods landed after the shadow comparison was run, so its 16/44/37
split describes a scoring model two versions old.

Where it started, for scale: measured 2026-08-11, **2,518 observations and every
table downstream of them zero**.

### HealthKit classifies, and correctly produces nothing

`fitness.py` records what it found in `fitness_feature_snapshots`: 390 accepted,
**0 rejected**, 366 activity days, 24 hours, no workouts, coverage
`aggregate_only`. Zero habit candidates is what §10 requires of aggregate-only
HealthKit, because every `activity:*` and `routine:*_workouts` concept is derived
from *typed workout sessions*. `rejected = 0` is the load-bearing number:
`_parse_activity_day` refuses a row it recovered nothing from, so 366 days
surviving proves the adapter's keys were read rather than silently absent.

**`first_move` never reached the vault, and it was provable without decrypting
anything.** `HealthKitDistiller` writes `first_move=06:00` and `FitnessPayload`
read it with `extraInt` — `Int("06:00")` is nil, on all 366 days. The chronotype
signal, dropped at the envelope boundary with nothing saying so. `extraHour`
parses it now. The check worth repeating is the one that found nothing else:
every other numeric extra is written as a plain integer.

### The Calendar review

**Reviewed by the owner on 2026-08-12, and every promotion was right.** All nine
promotions across both accounts — five flights and one tour booking, four of the
flights duplicated by Google Calendar — were confirmed, and the sampled
abstentions were confirmed as correctly refused in every stratum: work meetings
and webinars, public holidays and birthdays, and five surgical and outpatient
entries under `excluded_sensitive`.

101 events, 101 observations, 5 candidates — 4 `travel_itinerary`, 1
`public_ticket`. The 68 `excluded_unknown` is the allowlist working rather than a
gap.

**Reading it needed a tool, because the vault cannot answer the question.**
`observations.normalized_payload` is four keys and no title, and
`source_item_hmac` is salted with a KMS key only the classifier's role may use —
so *"review every Calendar promotion"* is unanswerable from stored evidence, by
design. `tools/calendar_review.py` re-derives each decision from the legacy row
with the same classifier and the same four offline catalogs, and a test pins the
constructor arguments because a missing catalog would silently reclassify.

**It counted history on its first run**, reporting 9 promotions against the
vault's 5: `distilled_records` is append-only, David's 106 events are 158 rows,
and four flights were classified once per distillation. Demo matched at 9 and 9
on the same broken code because its duplicate rows happened not to be promotable,
so **only running both accounts caught it**.

### `0064`'s two mistakes

**The whole row speaks the schema's language, and that was learned twice.**
`0064` was written against `0060`'s eleven-argument body after `0062` had added a
twelfth, so `create or replace` **overloaded** rather than replaced. Worse, its
premise was wrong: `guard_ingestion_run_item_v031` requires

    raw_row.data_type           = scope_row.data_type
    observation_row.data_type   = scope_row.data_type
    observation_row.action_type = scope_row.action_type

so an observation cannot hold a vocabulary of its own. A calendar row has to say
`calendar_event` **from the device onward**.

**Renaming a `data_type` re-stores every row and orphans its current items.**
`data_type` is part of the fingerprint, so the 101 events stored again as new
rows and `current_source_items` holds **202** for `apple_calendar` — the old
`event` items still `present` beside the new `calendar_event` ones. They carry no
observations and no scope the device still sends, and a `partial` scope licenses
no expiry, so nothing removes them. Inert history, the same class as the v1
payload rows, and it will read as double counting to anyone coming to that table
cold.

---

## The first assertions, and the four faults between capture and them

**542 `concept_scores`, 81 `user_assertions`, and 13 concepts reaching two
independence groups** — measured 2026-08-12, on the first run that produced any.
Nothing in this system had ever had more than one group, and `motif_rules`
requires two as a check constraint, so until this every motif rule was
unsatisfiable by construction.

`creator:le_sserafim` at strength 0.684, breadth 2, three sources: listened to on
Apple Music and watched across **nine separate repost channels** on YouTube. That
is the shape the whole exercise was for — `apple_music`, `music_library` and
`spotify` all carry the `music` group by design, so no music source can ever be
the second witness.

**Music resolution was blocked on content, not on code.** `ontology.concepts`
held 45 rows and **not one of them was musical**, so resolving the 2,417 music
observations would have abstained on essentially all of them. Concepts have to be
authored before a resolver is worth running.

### The scorer could raise a claim and could not withdraw one

Its eligibility test sat *before* the assertion lookup, so `UPDATE_ASSERTION` was
reachable only with state `eligible` — and the comment above it, *"an assertion
that stops being evidenced becomes `inactive`"*, described something the control
flow made impossible. Found by making hubs never assert, deploying, re-scoring,
and watching three hub assertions come back `eligible` from a run that had not
touched them.

Two statements fix it, because only one of the two ways a claim stops holding is
iterated: scored-and-no-longer-eligible is demoted in the loop, never-scored-at-
all is swept afterwards. Its first application withdrew 27: three hubs plus **24
classical performers the album-breadth change had disqualified weeks earlier and
been unable to retire**.

`score_user` had no unit test because it wants a database, which is why this
survived. It has one now, and what it asserts is **which statement ran** rather
than what was scored — the bug was never in the arithmetic.

### The four faults, each of which hid the next

- **A 500 that should have been a 400.** A projection refusal is the *caller*
  sending a forbidden shape, and `SemanticIngestionService` classifies permanence
  by status code. So one Calendar batch, staged by a build predating
  `semanticDataType` and carrying `event`/`entered_by_user`, was re-sent on every
  distillation for thirteen hours at the head of a FIFO queue, starving three
  YouTube distillations behind it. Nothing could see it: the queue drains only
  when new work arrives, and that actor deliberately shares no error state.
- **A trigger error that named no row.** `private observations require an exact
  closed projection` is raised by a guard, so the operator got a bare 500.
  `projectionDiagnostic` reports each rejected row's *shape* — field names,
  payload keys, presence rather than value, deduplicated with a count — and named
  the cause on its first run. **It found in one line what four rounds of reading
  code had not.**
- **Fuzzy matching nobody reads.** `resolve_alias` falls back to a
  `SequenceMatcher` against every alias for any term with no exact hit. Music
  never noticed — its terms are curated aliases. Uploader tags are arbitrary free
  text: ~5,500 on one library, almost none matching, each scanning 1,512 labels.
  **≈8.3 million comparisons a run, the entire 300-second Lambda timeout** — and
  every result was already discarded, since the fuzzy path returns only
  `CANDIDATE` or `REJECTED`. `exact_terms_only` drops those terms: 300s to 9s,
  removing no mapping that was ever written.
- **Row-at-a-time inserts** through a transaction pooler, now `executemany`.
  `pg_stat_statements` blamed the `semantic_runs` insert at 116s max, which was
  really later jobs blocking on `semantic_run_live_identity_idx` while the first
  held its transaction open — **parallel invocations manufacturing the contention
  being diagnosed.** Invoke the worker serially.

### Five migrations found five grants by watching five invocations fail

`0086`–`0090`, after `0063` and `0070`–`0073`. Each cost a deploy and a run to
learn a fact that was static the whole time. `0090` stopped guessing: read
`pg_trigger` for the tables being written, follow what each trigger calls, grant
the set. One caution from `0089`, whose first draft asserted so broadly it
demanded privileges for Phase 4's dyad and surface paths and correctly rolled
itself back — a check broad enough to demand privileges nobody asked for is an
argument for granting them.

### `prepare_threshold=None`

psycopg 3 auto-prepares a statement after five executions, and Supabase's
transaction pooler hands each transaction to whichever backend is free — so the
*second* of two back-to-back invocations tries to `PREPARE` a name the first left
behind and fails `42P05`. It failed for one account and succeeded for the other,
which reads as bad data rather than a driver setting. This had been asserted
since the pooler was chosen; nothing implemented it, and nothing had ever run
five times on one connection until the scorer's demotion statement arrived.

---

## Music ontology

### Classical performers

**A performer is weighed by how many distinct albums they appear on, not how many
rows.** Pygmalion has 276 rows — the most of anyone in the library — across *one*
album, the St Matthew Passion counted once per movement. Perlman has 47 across
six, Hadelich 97 across three, the Berlin Philharmonic 100 across thirteen.

The final state, after the owner's review asked for it:

| kept | | dropped | |
|---|---|---|---|
| Bach 0.95, Mozart 0.73 | composers | Pichon, Pygmalion | 0.187 |
| Hadelich 0.82, Perlman 0.66 | soloists | Gardiner, Monteverdi Choir, EBS | 0.078 |
| Berlin Philharmonic 0.70 | 13 albums | Gilels, Podger | 0.078, 0.027 |

**A flat weight could not have done this**: `strength` saturates as `w/(w+6)` and
that curve is nearly flat where these concepts sat, so a 70% cut moved Pichon
0.92 → 0.85. `0.02` is chosen *against the 0.35 eligibility bar*, not picked: 69
units become 1.4, which saturates to 0.19.

**Two escapes cost three rounds each, and both were found by grouping mappings on
`evidence_weight`** rather than by reading code — 138 rows at 0.02 beside 68 at
1.0 pointed straight at the cause both times:

- **`genres: null` on 68 of 276 rows** of one recording. `_is_classical` read the
  genre and never the title, on the principle that a stated label beats a derived
  one — correct when a label exists, silent when there is none.
- **`"Part II"` matched `Part`, an ASCII alias for Arvo Pärt.** The false composer
  stripped the title's prefix, `classical_work` then found no catalogue number,
  and 92 Monteverdi Choir rows read as non-classical. Fixed as a class rather
  than an instance: a composer prefix must *be* the prefix, since `Glass`,
  `Reich`, `Berg` and `Ives` were the same hazard waiting.

Three tests caught the first attempt, using Hilary Hahn as the fixture, who is
one of the performers the change exists to protect.

### Eras, spheres and scenes

**A decade means nothing on its own, and this was measured before it was
believed.** `era:1970s` at 0.403 rested on ABBA, Stevie Wonder, Frankie Kao's
姑娘的酒渦 and Fritz Kreisler — anglophone pop, Mandopop and a violin recital,
three unrelated worlds under one assertion. The owner's reading: *"eras strongly
interact with language sphere — 1970 UK music vs 1970 cantopop is very
different."*

That **implements** the owner's earlier *"80s German music would be a strong
personality"* rather than reversing it: that example is itself a scene, and the
composite did not exist when the era had to carry it alone.

Three mistakes worth keeping:

- **A marked genre silences the unmarked ones on its row.** Apple writes both —
  Frankie Kao's rows are `Mandopop|Music|Pop`. Read as equals, a Taiwanese singer
  produced `sphere:anglophone` and his five 1970s rows became evidence for
  `scene:1970s_anglophone`, which then carried **all thirteen** of `era:1970s`'s
  mappings: the composite spanning exactly the worlds it was built to separate.
  Every anglophone figure fell when this landed, which is how you see it work.
- **`0095` minted 35 concepts that could never resolve**, and its own assertions
  passed: it counted concepts and edges, and counting the right number of
  unreachable things is what a structural check gets wrong. The resolver matches a
  term against `normalized_label`, and `era:1970s` carries an `alternate` label of
  exactly `1970s` — prose labels never meet suffix terms. `0096` asserts
  *resolvability* instead, and its first draft stored the underscore form that
  `normalize_text` turns into a space, reintroducing the same silent failure
  inside its own fix.
- **That check then flagged `era:classical_period` and was wrong.** It stores
  `classical period` and resolves correctly. **The data was right and the check
  was wrong**, which is the more useful half of the lesson.

**The classical era distortion this started from does not exist.** `takes_decades`
gates decades to `DECADE_GENRES`, `Classical` is absent from it, and the 2022 Bach
recording never contributed to `era:2020s`. The real gap was the opposite shape:
Apple files the passions as plain `Classical`, so `classical_eras` returned
nothing, classical rows got **no era at all**, and the six period concepts had sat
since `0044` with zero assertions. `COMPOSER_PERIODS` reads the period off the
composer. `era:baroque` scores 0.958 on 417 mappings now, `era:classical_period`
0.853 on 100.

---

## Phase 3 — the Memories surface

**Built 2026-08-12, and the server half already existed.** `0048` had shipped the
whole narrow-RPC surface §8 asks for — `api.list_assertions`,
`confirm_assertion`, `add_assertion`, `suppress_assertion`, `restore_assertion`
and `record_assertion_exposure`. Phase 3 was pointing the app at them.

`0102` is what made the flags decide anything at all — they had existed since
`0048` with **zero callers**, and `emergency_privacy_kill_switch` described
itself as a master stop and stopped nothing.

**The `api` schema had to be exposed by hand**, which no migration can do:
Settings → API → Exposed schemas. Until it was, every RPC answered `PGRST202`
naming **`public.list_assertions`** — which reads as a missing function rather
than an unexposed schema. Found with one request from outside the app, before any
Swift was written, precisely so it would not be diagnosed from inside it.

### Three defects, all the same shape, each hiding the next

The recurring one — *a call that can fail, a result nobody reads*:

- A **required exposure passed as `NSNull`**. `suppress_assertion` ends with
  *"matching assertion exposure is required"*: an answer must name the exposure it
  answers. `record_assertion_exposure` was never called at all.
- The exposure then **requested and unparseable**. A `uuid`-returning function
  answers `"a1b2-…"`, a top-level JSON fragment, which `JSONSerialization` refuses
  by default — so the id read as nothing and the answer never ran. The request had
  succeeded; only the reading of it had not.
- **Both invisible**, because the failure was stored on the service and drawn
  nowhere. A refused removal looked exactly like an accepted one: the row vanished
  optimistically, returned on the next load, and nothing said why.

Every confirm and suppress failed from the moment they were written until the
owner tapped remove and asked whether it had stuck. **A probe proved the reads and
nothing proved the writes**, and the surface was called "behaving" on the strength
of the half that could be seen.

### What the page shows

The owner drew the line: *"These blanket terms serve internal processing, but
serve no purpose for user edit — the terms shown should be well defined enough to
strike off or understand, either artists like Shiina Ringo or ABBA, or franchises
like Re:Zero and Footloose."* So `0108` filters `list_assertions` to `creator`,
`work` and `activity`, and the page went from 65 rows to 36.

**It filters one page and nothing else, which is worth stating because `0108`'s
own comment overstates it.** That comment says suppressing a blanket term *"would
quietly change how everything else is weighed"*. It would not:
`assertion_preferences` is read by the six `api` functions and two Calendar
guards, and **the scorer never reads it**.

> **Superseded by `0111`–`0116`.** The scorer *does* read suppressions now —
> `withdraws_assertions` and `suppression_transfer` are scorer parameters as of
> v0.7.0, and striking off a named role moves its weight to the other named roles
> on the same row. The paragraph above describes the state at `0108` and is why
> the correction was needed.

The migration is left as the record of what was deployed —
`supabase_migrations.schema_migrations` stores each migration's statements, and
editing an applied file is the `ARCHIVED-YOUTUBE` drift one layer down.

**The work bar is 0.25 and is a judgement, not a measurement.** A creator
accumulates across everything they touch — Bach is on 417 mappings — while a work
is attested only by the songs belonging to it, so the same strength means more
evidence. Set from the owner's reading of three of their own: Footloose in at
0.266, BanG Dream! out at 0.237, Re:Zero out at 0.047. It went in at 0.20 first,
deliberately below both of the first two; **what was missing was a label on the
second row, not a finer threshold**. One library and one reviewer.

---

## The migration record

`0049`–`0065`, the phase where the numbering diverged from the integration plan's:

| | |
|---|---|
| `0049` | `public.rls_auto_enable()`, a Supabase dashboard event trigger that existed in production and in no file |
| `0050`–`0051` | the wrapped-key registry, and aligning its `key_version` vocabulary with `0046`'s |
| `0052`–`0054` | the ingestion identity; binding the data key to the rows it protects; writing it only when something was stored |
| `0055`–`0056` | scopes, run items and finalization — and making finalization conditional, so capture cannot be rolled back by promotion |
| `0057`–`0059` | the worker identity, its grants, and moving projection into ingestion |
| `0060`–`0062` | a JSON `null` is not a SQL NULL; the fitness purpose grant; run coverage metrics |
| `0063` | worker grants for the fitness snapshot |
| `0064`–`0065` | the Calendar projection vocabulary, and the two mistakes it took to get right |

`0066`–`0090` are the music concepts, the YouTube vocabulary and policy, the
scorer and its grants.

**`0091` onward are not written up here.** Each migration file carries its own
reasoning in its header comment, which is where that record now lives — see
`0099`–`0100` (zombie runs), `0101` (assertion reviews), `0102`–`0103` (the
surface flags gating something), `0107` (resolver 0.3.0), `0108` (Memories shows
nameable things) and `0109`–`0116` (scorer 0.4.0 → 0.7.0 and the suppression
feedback loop).

### The one character worth keeping

`0050` admitted a colon in `key_version`;
`raw_source_records.encryption_key_version`, which *names* that version, does not
— so a key could be created, used to encrypt, and then be unstorable on the very
row obliged to name it, with the refusal arriving at ingestion time one service
away from the mistake. It is this codebase's own *two columns that accept the
same words* defect with the sign flipped: two columns that must accept the same
words accepting different ones. `0046` wins, because it is adapted from the
contract and `0050` invented something. `0051` **asserts the two patterns match,
reading them out of the catalog at migration time** rather than trusting its own
comment — proven by perturbing the other side and watching it refuse.

### Reading the plan's numbers

**The plan's three reserved numbers were overtaken entirely.** It allocated a
bridge, then server projections, then cutover; sixteen migrations of real work
landed instead, so **projections and cutover have no number and should take the
next free one.** §5 permits it: never *reuse* a number, skipping one is fine.

**Its §-quotes are written in the plan's numbering.** §10's gate reads *"existing
push/chat/profile behavior remains green through 0048"* and §9 says *"do not
reverse 0050 in place"* — the first still means our `0048`, the second now means
our `0055`. Read a number in `WRITTEN_REPOSITORY_INTEGRATION.md` as a **role**,
not as a filename; `application_migrations` in the baseline manifest carries the
mapping.

## 2026-08-19 — The grammar that compiled and did not bind

**The lane's first invocation was blocked by three stacked defects, and every
one was found by measuring the live endpoint rather than reading code.** The
full record is this entry; the rules it bought are in the schema's own
descriptions and `mention_extract_v2.py`'s comments.

- **xgrammar 0.2.3's token matcher leaks on `pattern`-constrained strings.**
  The grammar is correct at the string level — `_is_grammar_accept_string`
  rejects every violation — but the per-token mask admits token paths outside
  the string language and then admits schema-illegal continuations downstream.
  On the endpoint this read as the model emitting enum-illegal families and
  running to the 4096-token cap; locally it reproduced token-by-token with the
  real tokenizer. Removing the two `pattern`s closed the leak entirely and,
  unexpectedly, also restored `maxItems` enforcement. The not-all-whitespace
  and no-control-character guards moved to `mention_extract_v2`, the layer for
  what the schema cannot safely express. **A grammar backend is believed when
  a matcher has been fed a violating document and refused it — compilation
  succeeding proves nothing, and neither does an abstention-shaped answer,
  which never exercises the mention definitions.**
- **xgrammar cannot compile `if/then` inside `allOf` (silent loosening) and
  crashes on negated character classes with non-ASCII members** (`bitset` at
  position 128). The schema's conditionals became `anyOf` variant objects —
  `item_extracted`/`item_abstained`, `mention_text`/`mention_tag` — proven
  language-identical over 530 adversarial documents, with every deliberate
  loosening covered by the second layer (the equivalence run asserts zero
  uncovered).
- **The prompt taught the v1 shape.** `prompt.output.aboutness_example` still
  showed `evidence_fields`/`lookup_queries`/`relation_hypotheses` — fields v2
  removed — so under a *binding* grammar the model either collapsed to
  abstention or fought the mask to the token cap. The example is now a full
  v2 envelope; prompt `qwen_extractor_v6`, grammar `semantic_grammar_v4`.
- **The offset repair (owner decision):** the model names the right entity
  and miscounts code points. Where the emitted surface occurs exactly once in
  the cited field, `repair_offsets` recomputes the span — deterministic and
  honest; absent or ambiguous surfaces stay refusals, so it can never invent
  a span. Bounds are checked before the slice equality, because Python
  slicing clamps and a clamped slice can equal the surface while `end` is out
  of bounds. Repairs are counted in the gateway's answer, never swallowed.
  Acceptance: 21/21 live-endpoint cases green, including a deliberately
  repetitive title whose correct outcome is abstention.
- `mention_extract_v2.py` joined `GATEWAY_SOURCES`: the repair changed which
  answers survive without touching a line of `gateway.py`, which is the
  definition of release-significant.
