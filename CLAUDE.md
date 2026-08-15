# Written — project guide

Written is an iPhone dating platform. Two coined terms carry the product:

- **Distillation** — extracting a user's digital footprint from the apps on
  their phone, identifying keywords via ontologies, and plotting
  preferences/interests/personality on an embedding space. The MVP covers the
  extraction stage only; the ontology and embedding stages consume its output.
- **Dynamic prompting** — bios/prompts whose content changes depending on who
  is reading them, in contrast to the static bios every dating app ships today.
  If a violin-inclined user views someone with many interests including violin,
  that profile surfaces violin first. Distillation is what makes the commonality
  computable.

**This file is the rules. The long-form record — the measurements, the evidence
and the postmortems each rule was bought with — is `docs/PROJECT-CONTEXT.md`.**
Read that before removing a guard or concluding a rule looks arbitrary; where the
two disagree, this file controls. The semantic pipeline's build history is
`semantic/JOURNAL.md`, each migration's reasoning is in its own header comment,
and anything cut from either file is in `git log -p`.

**What happens next is `docs/NEXT-STEPS.md`** — the dyad test, the distillation
it is waiting on, and the two one-line things that must not be missed at launch.
It is a plan rather than a record: an entry is deleted when it stops being true.

## The prime design constraint: minimum friction

Data extraction must feel like a **one-button experience** per app. OAuth is the
preferred mechanism; in-app browser login with automated download is the
fallback, to be discussed per app and never a default. When adding a source,
"how many taps and does the user type a password?" outranks how much data the
integration could theoretically reach.

Every Apple source is one tap and no password (MusicKit, HealthKit, EventKit —
one system sheet, no login), and that is the standard the OAuth ones are measured
against rather than an accident of what was easy. OAuth sources buy zero-tap
re-distills only once the app is published: a consent screen in Testing expires
every refresh token after 7 days.

## The extraction rule: if it can be distilled, distil it

**Take whatever is technically possible, whether or not it looks useful at first
glance.** The ontology and embedding stages decide what matters, and only about
data that was kept; a field dropped at the parse cannot be recovered without
re-distilling everybody.

Within one already-granted permission, take everything: extra fields on a
response already fetched, extra `part=` on a request already being made, a second
query against a library already open.

Three things this rule does **not** license:

- **Asking for more permissions.** "Technically possible" means with the consent
  already given — Health's sheet lists only the types actually read.
- **Widening the list of what leaves the device.** That list is kept short and
  complete on purpose, and `PrivacyInfo.xcprivacy` has to keep agreeing with it.
- **Working out what a source already states.** *Keeping* a field and *inferring*
  one are different acts under different rules, and for YouTube the second is
  prohibited outright. Add `part=topicDetails` to reach one more field; do not
  compute a label the source would have given you for the asking.

**And an absence is not a refusal.** Distil what is reachable and explain what is
missing — never stop because one route came back empty. **But do not assume the
other route saves you**: the device library is not a fallback for Apple Music.

## Supported apps and what each yields

Scope comes from `written_api.xlsx`; consult it before adding a source.
**`grep -rn "ARCHIVED-"` is what actually ships** — a marker means "held back or
on its way back", and only the code around it says which.

**Live drift to close before any upload:** `Modality.swift` returns `youtube`
(`:147`) and `google_calendar` (`:175`) while their `ARCHIVED-` markers say they
were removed. Anything shipped from this tree offers a reviewer both, and both
403 for accounts off the Testing allowlist. Close it deliberately, in one
direction or the other.

- **YouTube** (`YouTubeDistiller`) — subscriptions, liked videos, playlists and
  contents. Watch history is **not** reachable. `channels.list` asks
  `topicDetails,statistics` in one call, quota being per call rather than per
  part; the subscriber count is the one field III.E.4 lets outlive thirty days,
  being a *statistic*. **It dual-writes to the vault and resolves.** It may not
  infer: `provider_topic` and `uploader_tag` are reads and permitted,
  `written_title_tag` is a guess and is gated.

- **Apple Music** (`AppleMusicDistiller`) — library songs/albums/artists/music
  videos, playlists + contents, recently added, recently played, heavy rotation,
  recommendations, ratings.
  - **A person without an Apple Music subscription gets no music from this app at
    all**, from either source. The cloud flag cannot tell owned music from
    downloaded, so **never filter `MusicLibraryDistiller` on it**.
  - **On a subscriber's phone both sources return the same library with different
    ids**, so `MusicHighlights.deduplicatedSongs` must collapse on **title and
    artist**, never on id, and only **within the Apple pair** — reaching across
    to Spotify discards single-artist tracks and double-counts featured ones.

- **Spotify** — **live for the data-collection prototype, removed before the real
  launch.** **Two edits turned it on and both must be reversed**: the string in
  `Modality.sources`, and `AppShell`'s `.task { viewModel.purgeArchivedSources() }`,
  now commented out — that task deletes Spotify rows from memory, cache and
  Postgres on every launch, so left running with the source live it wipes each
  distillation moments after it lands.
  - **Why it comes out again: IV.2.1.a** forbids ingesting Spotify Content into
    any ML/AI model, and **IV.2.5 closes the consent route** — derived and
    aggregate data count *"even if a user consents"*. **And it cannot leave
    development mode**: 5 users, extended quota organisations-only.
    (IV.3.1.a is a *limit*, not a prohibition, and IV.2.5 permits Postgres.)
  - Its `creator` is **pipe-joined across every credit** and it stamps no
    `subject=`, so subjects go through `Ontology.musicSubject`, which stamps the
    first credit. `top_track`/`top_artist`/`followed_artist` must stay in
    `MusicHighlights.songTypes`/`artistTypes` or the strongest listening signal
    either source returns counts for nothing.

- **Apple Podcasts** (`PodcastDistiller`) — `MPMediaQuery.podcasts()`, one
  `MPMediaLibrary` permission, no login. **It is the whole of the Media branch
  while YouTube is archived** (`Modality.isOffered`). **It returns downloaded
  episodes only and there is no play history** — `playCount`, `lastPlayedDate`,
  `genre` and the rest come back empty; `bookmarkTime` is the only behavioural
  fact. A category would have to come from the iTunes Search API by show name.

  **Unresolved, and it decides whether the source is worth having: does Apple
  Podcasts auto-download episodes of followed shows?** Settle it by following a
  show on a device, downloading nothing, and looking again. **This ships
  unanswered**, and an empty source that looks connected is worse than none.
  Ruled out and not to come back: MusicKit podcast types, iCloud sync, Now
  Playing metadata, `DeviceActivity`, the privacy.apple.com export,
  `JournalingSuggestions`.

- **Apple Calendar** (`CalendarDistiller`) — the ticketing bookings and the typed
  entries nothing else reaches. `url` and `organizer` are kept because they are
  what tells the two apart (`booked=1` in `extra`).
  - **Events are stored whole and synced**, unlike HealthKit, because the titles
    *are* the signal — and `PrivacyInfo.xcprivacy` says so.
  - **Windows are five years either side** (`AppConfig.calendarLookbackDays` /
    `calendarLookaheadDays`, capped by `maxCalendarEvents`); a ticket bought
    today for November only exists ahead of now. One occurrence per recurring
    identifier, marked `recurring=1`.
  - **`predicateForEvents` silently returns nothing across more than four
    years** — chunk the fetch by year, and **walk the chunks outward from
    today**, or the cap is spent on old standing meetings.
  - **On iOS 17+ `requestAccess(to:)` grants write-only**, which looks exactly
    like an empty calendar. Use `requestFullAccessToEvents`, and keep the legacy
    `NSCalendarsUsageDescription` alongside the modern key for the 16.0 target.
  - **Three exclusions, three mechanisms, because no one of them reaches the
    others.** `isGenerated` tests the calendar's *type* first and its *name*
    last (holidays via Google/Exchange are `caldav`, and the name list will
    always be incomplete). `PublicHolidays` catches holidays copied into a
    *primary* calendar as ordinary events, matched **by token, not whole name**.
    Titles carrying `birthday` or `meeting` are **not drawn** — a reading
    decision; every such row is still collected, synced and sent on.
  - **A row with no `cal_type` is not drawn**, and one re-distill fixes it.
  - **The card ranks events by what made the entry, never by date.**

- **Google Calendar** (`GoogleCalendarDistiller`) — **offered only where the
  phone has no Google account**, since one added in iOS Settings arrives through
  EventKit as `caldav` and `append_source_records` dedupes only *within* a
  source. `hasGoogleAccountOnDevice()` tests the `EKSource`, not calendar names,
  and both `SourceAvailability` and `DistillViewModel` guard it, because a hidden
  row is a drawing and not a rule. Two narrow scopes rather than
  `calendar.readonly`; birthdays go by Google's own `eventType`. Archived because
  the consent screen is in Testing, so a reviewer 403s *after* a successful login.

- **Outlook Calendar** (`OutlookCalendarDistiller`) — Microsoft Graph `v1.0` on
  the shared PKCE machinery (an `OAuthProvider` case, never MSAL), `common`
  authority.
  - **`Calendars.ReadBasic` is not available to personal Microsoft accounts**,
    and the refusal is a **401 with no body and no `WWW-Authenticate` header**
    naming no scope. The grant is `Calendars.Read` — wider than what is read,
    since `$select` names twelve fields and never `body`, `attendees`,
    `attachments` or `webLink`. That is minimisation our code performs, not one
    the permission enforces. Never `.ReadWrite`.
  - **It stamps no `booked=1`** — the `$select` asks for neither organiser nor
    url, so its events map to `scheduled` alone. Adding `organizer` is possible
    and is a decision, not a consequence.
  - Its rows overlap Apple Calendar's; dedupe where it is *shown*, by title and
    start, and derive that set from **`Modality.plans.recordSources`** rather
    than writing it out — that set decides both which rows reach the card and
    which dedupe against each other.
  - **A tenant can refuse after a successful sign-in**; say so in words
    (`CalendarError.tenantRefused`). **The row is absent, not disabled, until
    `AppConfig.microsoftClientID` is real.** **Legacy `distilled_records` path
    only** until exercised against a real tenant.

- **Google Health is not possible on iOS**, settled rather than deferred. Fit
  REST is closed to new signups and dies end of 2026; Health Connect is
  Android-only; `fitness.*` was restricted and meant a CASA assessment.

- **Apple Health** (`HealthKitDistiller`) — `age`, `biological_sex`, `workout`,
  `activity_day` (≤365) and `activity_hour` (**24 rows for the whole window**,
  because the question is which hours somebody is active in).
  `DistillViewModel.healthKeptTypes` excludes nothing and is kept as a list
  precisely because it is the gate a *new* HealthKit type has to pass. Two
  windows (`healthWorkoutLookbackDays`, `healthActivityLookbackDays`) kept apart
  because workouts are sparse and quantity samples dense.
  **Only the types actually read are requested** — reading a type never requested
  answers `errorAuthorizationNotDetermined`. **A declined read looks exactly like
  no data**, so an empty distill is surfaced as a failure rather than silently
  growing a branch.

### A calendar missing from the private-source list is permitted, not unhandled

**Never name a calendar source by literal in `semantic_private`.** Six functions
decide how a calendar observation is treated and four are *prohibitions*
(generic mapping lane, mention/feedback lane, evidence under a public surface
grant, the sanitised projection). A source registered in `sources` but missing
from those literals is not *unhandled* — it is **permitted**, with nothing
reporting the difference. **The failure mode of a deny-list is silence.**

`0133` replaced all five literals with
`semantic_private.is_private_calendar_source` and `is_private_lane_source`, and
asserts **no function outside those two names a calendar by literal**, so a sixth
written later fails the next replay rather than shipping a hole.

- **They are pure literal arrays, not table lookups.**
  `private_observation_projection_is_valid_v03` is `immutable` and backs a check
  constraint on `observations`; a helper reading `sources` could not be
  immutable, and a table would let a row quietly change what is enforced.
- **A predicate is not believed until it has been seen answering both ways** over
  real data — a title-carrying payload refused, a sanitised one accepted.
- Every calendar shares the `calendar` independence group: two calendars agreeing
  is often one diary reached twice, and `minimum_independence_groups >= 2` would
  otherwise be satisfiable by a duplicate.

### HealthKit's permission sheet, which is not HealthKit's

It hosts a remote view from `com.apple.HealthPrivacyService`, so if anything else
owns the screen or that process is cold it gives up rather than reporting a
refusal. Five rules:

- **No other permission alert near this one** — anything asked on
  `.task`/`.onAppear` is gated on that tab's `isVisible`, since `AppShell` mounts
  every tab.
- **One retry is not optional.** An error from `requestAuthorization` is always
  infrastructural, since a denied read is reported as success with no data.
- **`stageTimedOut` is the only terminal error.** `stage` wraps everything else
  as `stageFailed`, so a retry guard refusing `stageFailed` refuses the one error
  it exists for.
- **`authorizeTimeout` is 180s; `stageTimeout` stays 20** — the callback does not
  fire until the user answers the sheet.
- **Ask nothing of HealthKit while a sheet of ours is dismissing.**
  `waitUntilActive` cannot see it, so use `.sheet(item:onDismiss:)` rather than a
  guessed delay.

**Its Allow button is disabled until a category is switched on**, which reads as
a frozen app — hence the Health row's second line and
`SourcePickerSheet.privacyNotice` under the rows. **It only happens to people who
have never been asked, so testing Health on your own phone proves nothing**
(`xcrun simctl erase`, or Reset Location & Privacy).

Three rules from the same hunt, none about the sheet. **A failure must be drawn
against the branch that was attempted**, not against `nextModality`. **A
`withThrowingTaskGroup` cannot impose a timeout on a call that never returns** —
that needs an unstructured task deliberately abandoned. And **a Release build may
say what failed**: `BuildKind.isBeta` prints the diagnostic in Debug and
TestFlight only, since `stageFailed` and `stageTimedOut` render identically. The
detail is the whole run, not its last line.

### Where each source can be tested

**YouTube and Calendar work in the simulator. HealthKit's sheet and API do too**,
but its database starts empty, so add samples or every distill comes back empty.
**Apple Music requires a physical iPhone** signed into Apple Music, a paid team
and MusicKit on the App ID — MusicKit mints its developer token from the signing
identity, so ad-hoc-signed simulator builds fail with "Failed to request
developer token".

On device HealthKit needs the entitlement to survive packaging, and it silently
may not: with no `DEVELOPMENT_TEAM` Xcode strips it, and **`CODE_SIGNING_ALLOWED=NO`
does the same to a simulator build**. It reports as `Missing
com.apple.developer.healthkit entitlement` in `log show` and as an ordinary
authorization failure on screen. `xcodebuild test` signs correctly; building with
that flag and hand-installing from DerivedData does not.

## YouTube: the policy position, for when it comes back

**Read the clauses, never a summary of them** — three confident readings from
summarised fetches have all been wrong.

**III.E.3.b — Authorized Data goes to nobody but its owner.** *"Must not display
or allow access to Authorized Data to anyone other than the authorizing user."*
**The two-part test for anything added to `discovery_cards` is "is it something a
sentence can be about" *and* "do the source's terms allow a stranger to see
it".** Nothing in the schema asks the second.

**III.E.4.h — the derived-data prohibition, and why `Ontology.classify` is never
called on YouTube data.** Its don't-list includes *"infer or estimate the content
category/type of a video or channel"*; the remedy is its heading, ***"only offer
metrics that are available via YouTube's API services"***. So the category is
**read**, through `Ontology.domain(youTubeTopics:creatorTags:categoryID:)`, most
specific first: `topicDetails.topicCategories` (subscriptions carry none, hence a
second `channels.list`), then `snippet.tags` **matched whole and lowercased
against a small controlled vocabulary, never as substrings**, then
`snippet.categoryId`. **Check the source before calling `classify`.**

**`refusedTopics` drops Religion, Politics, Health, Military and Society whatever
YouTube says**, and categories 25 and 29 are absent from the id table: a content
tag is how a protected characteristic arrives without anybody deciding to collect
it.

**Retention: 30 days.** `0016`'s daily `pg_cron` sweeps run over
`distilled_records`, `discovery_cards.interests` and `raw_source_records`.
`shared_posts` is deliberately unswept — that video id came from a public URL
somebody pasted, not an authorised API call.

**Settled 2026-08-13: a channel name that has become ontology vocabulary is not
API Data**, so `ontology.youtube_channels.canonical_title` and the `creator:*`
labels are unswept. Three things it does **not** license:

- **The three sweeps stay** — those tables hold titles as *user data*.
- **It does not put titles back in the projection.** A title in
  `observations.normalized_payload` is *unremovable*: the payload is frozen by
  trigger and `ingestion_run_items` references observations `on delete no
  action`, append-only. Any plan resting on "no trigger fires on delete" is wrong
  — foreign keys do.
- **It does not make deriving a title into a term unnecessary.** The pattern that
  works is read-derive-discard, from the catalogue rather than stored evidence.

**Revocation.** Revoked at Google, 30 days (the sweep covers it). Revoked in-app,
or on request, **7 days** — which the sweep cannot cover, hence **Disconnect
all**. `deleteYouTube(revoking:)` takes the server first and the local copy only
if the server agreed. **`disconnect()` is not revocation.** `revoke()` POSTs the
*refresh* token and treats **400 as success**; its local half runs regardless.

**Bringing it back needs three things, each weeks rather than days:** extended
quota (requesting it triggers an audit), OAuth verification (Testing allowlists
100 users and expires refresh tokens after 7 days; publishing needs a Search
Console **Domain** property, a scope justification and a demo video), and — for
the ontology stage — Google's **Content Categorization and Tagging** amendment,
applied for on the same form. **Do not apply while running the unlicensed version
of the thing being applied for.**

**What that amendment does and does not license.** Three levels, only the middle
turning on it: **reading YouTube's own labels onto our vocabulary** is permitted
today and already built; **assigning our own sub-genres to videos and channels**
is what §3 licenses (*"additive and distinct from YouTube's video categories"* —
that is `written_title_tag`, gated by `allow_title_tags`); **aggregating those
into a claim about the viewer** is **absent**, all six categories concerning
channels and videos, so acceptance would not grant a viewer-level claim. Two
conditions sit around it: the **use-case gate** (*"must reflect an analytics use
case on YouTube"*) is undefined in the document, so neither pre-refuse nor assume
it; and the **storage relief excludes what this product wants**, titles and
creator names still following the 30-day policy. **The amendment covers
III.E.4.b/c/d only, so III.E.3.b is not in scope** — showing one user's
YouTube-derived channels to another stays prohibited whatever is accepted.

`youtube.readonly` is *sensitive*, not *restricted*, so no CASA assessment. The
YouTube contribution must be **separable and reversible** and **must not become
load-bearing**. **The day the ontology layer is enabled for YouTube,
`web/en-us/privacy/` moves in the same commit.**

**Two things ruled out.** Takeout — legally fine, but a ZIP emailed days later
breaks the one-button rule. And there is **no general prohibition on merging
YouTube data with other sources**; the actual clauses are narrower (III.E.2.a
aggregation **across channels**, III.E.2.b insight into **YouTube's own**
business, III.C.5 **search-result** mixing).

**The DNS trap on `written-stl.com`:** `www` is a **proxied** `A` record to
`192.0.2.1` (TEST-NET-1) answered by a dynamic Redirect Rule — the request
terminates at Cloudflare and the address is never contacted. Grey-cloud it and
the browser hangs. **Not a CNAME to the apex**, which is a Worker custom domain
(Error 1000). The rule must stay dynamic, because Google's reviewer follows deep
links.

## Output pipeline

```
Distiller (per source)  →  [DistilledRecord]  →  CSVExporter  →  CSVDocument
                                                                      ↓
                                                        .fileExporter (Files app)
```

- Every source normalizes into the **same** `DistilledRecord` schema:
  `source, data_type, item_id, name, creator, detail, extra, collected_at`.
  `extra` is a `key=value;key=value` string — **put platform quirks there rather
  than widening the schema**.
- `DistillViewModel` replaces records per-source on re-distill
  (`replaceRecords(from:with:)`), so distilling twice must not duplicate rows.
- **Everything leaving the device is on this list, and the value of the list is
  that it stays short and complete:**
  - **Postgres, keyed to the account** — the distillation via `SyncService`, the
    profile, the ban list and derived health signals. **Health takes the same
    path as every other source.** Keep the `pushConnection` fallback: `push`
    returns early when rows existed and *every* one was withheld, which for
    Health is a real shape.
  - **Lyrics providers** — one artist and one title to lrclib.net, then
    music.163.com. No user id, no library, cached.
- **`health/biological_sex` is refused at the wire** by
  `SyncService.localOnlyTypes` — a per-`source/data_type` list, because the unit
  of that decision is a row rather than a source. It is a protected
  characteristic, nothing downstream asks for it, and `public.users.sex` already
  means the gender somebody *chose*. `localOnlySources` survives, empty, for the
  next source that may not be stored at all.
- **The server is the source of truth; the device keeps a cache.**
  `RestoreService.hydrate()` is the read half.
- **Nothing in Postgres is ever deleted, and only changes are stored.** The
  device *replaces*; the server *appends*. Two things make
  `append_source_records` work and both are easy to break: the comparison is
  against the **latest** version, not any historical one, and it **excludes
  `collected_at` / `distilled_at` / `updated_at`**.
- **Three deletion exceptions, all obligations:** account deletion, the YouTube
  sweep, and `SyncService.deleteSource(_:)`. **`markedRemoved` cannot stand in
  for a deletion somebody is owed.** Build such a request with `URLComponents` —
  `appendingPathComponent` escapes the `?` and asks for a table named
  `distilled_records?source=eq.youtube`; the unlucky failure is a DELETE with no
  filter.
- **Anything that removes a person's data has two halves, and one of them is
  easy to forget.** *Disconnect all* emptied four tables in `public` and named
  none of the ones Memories reads, so every term stayed on the page after the
  sources behind it were gone — it deleted the copy the user could see and kept
  the one they could not, which is the worse of the two arrangements. The vault
  half is `api.forget_distillation`; **the rule is that a deletion control names
  both schemas or it is not finished.**
- **In the vault an erasure *redacts*: `lifecycle_state = 'deleted'` with both
  payload columns nulled, never a row delete.** `ingestion_run_items` refuses
  every operation that is not an `INSERT` and references observations and raw
  rows `on delete no action`, so a delete either raises or destroys evidence the
  policy permits keeping. `sweep_youtube_vault_retention` and
  `invalidate_healthkit_use_on_revocation` are the two precedents, and
  `raw_source_records_payload_location_check` is what stops the state and the
  redaction disagreeing. **A deletion cannot be checked by inspection** — the
  first version of `forget_distillation` walked nine tables in correct
  foreign-key order and raised on its first statement.
- **Retiring is not deleting, and inferred claims are retired.** `machine_state
  = 'inactive'` is what `api.list_assertions` filters on, and the scorer writes
  whichever state a run computes — so reconnecting and distilling revives a
  term rather than needing a repair. **`explicit_addition` survives a
  disconnect**, being the same fact as a `source = 'user'` row: what somebody
  typed is not what was read off their phone.
- **Read through the `summary_*` views, never the tables.** They return the
  latest row per item across runs — a union, deliberately **not** a sum. They are
  `security_invoker = on`; without it a view runs as its owner and bypasses RLS.
- **Signing out erases the device**, and **local state must be cleared before the
  session is dropped** — `AccountScope` reads the stored user id, and after
  `signOut()` it resolves to `local` and would clear the wrong account's files.
  `HomeView` is the only place wired for this; `GrowProfileView` deliberately has
  no `onSignOut`.
- `PrivacyInfo.xcprivacy` must agree with that list.
- **A connection is a snapshot, not a subscription**, and **a connection is not
  the same fact as a row.** Never infer connectedness from record volume —
  everything reads `branches`, and `ConnectionStore` is the local half of
  `source_connections`. It matters most for **Podcasts**, where zero is the
  normal result; for Calendar and Health an empty answer and a refused permission
  are the same answer, so both keep failing loudly on nothing.
- Exports are git-ignored — they are personal data and must never enter history.

## Signing in: three routes, but only one of them creates an account

**All three routes open a session; only phone creates an account.**
`supabase/functions/resolve-signin` refuses any Apple or Google session whose
`public.users` row has no phone and deletes the orphan Supabase just made — the
`id_token` grant signs up and signs in with one call, so "there is no account for
this identity" is only knowable *after* one has been made. **`AuthError.noLinkedAccount`
is correct behaviour, not a bug**, and **a reviewer cannot create an account by
any route they control**.

**A button that does nothing is worse than an absent one** — and "the account
doesn't exist" is a hypothesis worth eliminating before any machinery downstream
of it.

- **Apple** — native `ASAuthorization`, identity token traded for a session.
- **Google** — the same PKCE machinery as YouTube, asked a different question:
  `openid email profile` into `grant_type=id_token`. No SDK, no client secret;
  the client ID must be in **Authorized Client IDs**, since Supabase validates
  `aud` against that list. Two deliberate refusals: it does **not** persist
  Google's refresh token (it would be filed under `AccountScope.current`, still
  `local`), and `interactiveIdentityToken` never reuses a cached or refreshed
  token — reuse is right for reading a library and wrong for proving identity.
- **Phone** — Twilio Verify. `sendOTP` / `verifyOTP`, sharing `adopt(_:)` with
  the other two; two copies would be two places to forget the `UserDefaults`
  write that `AccountScope` reads.

**Route from the step, never from a constant** — `route(for: onboardingStep)`.
**E.164 is built once** (`PhoneNumberView.e164`) and used for both calls, or a
correct code fails against a number never messaged.

### What phone costs, and why it is not charged for

~$0.058 a verification in the US, **~$0.12 in Hong Kong**. It cannot be passed to
users on iOS: in-app charges for digital services must go through IAP, whose
price points start around $0.29.

**The exposure is fraud, not traffic** — SMS pumping. Four controls, in order of
how much they buy:

- **Twilio Verify geo permissions, Hong Kong / Taiwan / US only** — Console →
  Verify → Settings. **Separate from Messaging geo permissions**, which look
  identical and do nothing for Verify traffic.
- SMS Fraud Guard on.
- Supabase SMS rate limit at **10/hour, project-wide** — *not* per-user, so five
  testers in an hour is half the budget.
- **CAPTCHA deliberately not enabled**; revisit the day that rate limit is
  raised.

Twilio gates sending behind **Trust Hub KYC** — an unapproved compliance profile
sends no SMS at all. An Individual profile is enough for Verify.

## Launch routing: the first frame must already be the right screen

`RootView` picks one of five screens from a single `Route`, never a set of
booleans that can disagree.

- **Decide synchronously.** Anything the first frame depends on must be
  answerable without a network call (`hasStoredSession` reads the Keychain,
  `restoredStep` reads `UserDefaults`). `restoreSession` corrects a route rather
  than choosing the first.
- **Onboarding steps are routes, not covers.** A `fullScreenCover` draws
  `SignInView` underneath, reintroducing the flash the rule above removes.
- Anything that moves the mirrored server facts — `upsertProfile`, `loadProfile`,
  `markPhotoStepSeen` — must call `cacheOnboardingStep()`, and `signOut` must
  clear it with `firstName` and `hasSeenPhotoStep`, or the next account inherits
  the last one's answers.
- **`loadProfile` is the correction, and it is the whole of how a new phone skips
  onboarding.** It runs inside `restoreSession` before the route is recomputed,
  reads all six facts `onboardingStep` branches on, and `adopt(_:)` fills missing
  local stores **one direction only** — the local answer wins where it exists.
- **Anything added to `onboardingStep` needs a column and a line in that
  select.** A `distilled_records` row cannot stand in: records arrive with
  `hydrate()`, which needs `AppShell`, which needs the route.

`-route …` opens a screen directly (DEBUG only); `-birthday confirm|error` seeds
a *state* rather than a screen, since `simctl` can send no taps.

## Encoding: every generated file must support every language

**Any file this project writes must be UTF-8 with a BOM (`\u{FEFF}`), not just
UTF-8.** Users' libraries are full of Korean, Japanese, Chinese, Cyrillic and
emoji, and without the BOM Excel falls back to a legacy Western encoding — so the
bug only appears for the person opening the file. `CSVExporter` prepends it;
apply the same rule to any new export format. For pandas, read with
`encoding='utf-8-sig'`. CSV escaping is RFC 4180 — titles genuinely contain
commas and quotes, so don't hand-roll a simpler join.

## Setup that lives outside the code

Client IDs are in `AppConfig.swift` and are committed deliberately: iOS OAuth
client IDs are not secrets (they ship in the binary; PKCE is what secures the
flow). No client secret belongs in this app.

Portal-side setup — Google Cloud (YouTube Data API v3 + iOS OAuth client + test
users on the consent screen), Apple Developer (MusicKit on the App ID) — is
documented step-by-step in `README.md`. Google gates unverified apps to an
explicit tester allowlist; a 403 after a successful login almost always means
the signed-in account isn't on it.

## Conventions

- SwiftUI + async/await, MVVM: `Models/`, `Services/`, `ViewModels/`, `Views/`.
  Xcode 16+ synchronized folders — new files under `Written/` need no pbxproj
  surgery.
- New OAuth sources: add an `OAuthProvider` case rather than another auth
  service. Google *sign-in* is a second case on the same client, with
  `persistsRefreshToken: false`.
- **`web/` is the website and is not part of the app target** — static, no build
  step, deployed as a Cloudflare Worker serving `./web`. **Every file in that
  directory is published**, `_headers` and `_redirects` being the two exceptions
  that make it easy to believe otherwise. **Anything added there that is notes
  rather than site goes in `web/.assetsignore` in the same commit.**
- **A dashboard toggle can add a third-party script to the site without touching
  the repo.** The CSP's `connect-src` in `_headers` is what held that promise
  when Web Analytics did it. When checking for a beacon, key the request on
  `Accept: text/html` — injection does, and a User-Agent-keyed check answers 0
  unconditionally. **Run any such check while the thing is still switched on
  before trusting its zero.**
- Pagination is capped by `AppConfig.maxPagesPerEndpoint` /
  `maxPlaylistsExpanded` / `maxSongsRated`. **A per-item fetch that can't be
  capped is a red flag.**
- **Independent fetches within a distiller run concurrently** —
  `AppleMusicDistiller.distill` is the shape to copy: one `async let` per
  independent endpoint, dependent passes through `inParallel`, which keeps five
  requests in flight rather than all of them.
- **`Array.sort` is not stable in Swift** — break ties on `id`. `now()` is the
  *transaction* time in Postgres, so a batch inserted in one statement shares it.
- **Version a cache file when its model gains a field whose absence means
  something** (hence `written-chat-v2-`). **An optional that decodes to nil is a
  value, not a gap.**
- Per-source failures surface in that source's card (`SourceStatus.failed`) and
  never abort the other sources.
- **A call that can fail, a result nobody reads, and the symptom surfacing
  somewhere else** is this codebase's recurring defect — eleven instances so far,
  several written *after* this entry existed. **The fix is the type, never
  another boolean**: return `nil` for *could not ask* so the caller is `if let`.
  A `Bool` in one file guarding an early return in another is a convention, not a
  guard.
- **A shared `lastError` is not a record of what failed** — whoever writes it
  last wins, so a later success erases an earlier failure. Anything that needs a
  reason takes the returned `String?`. **Every `return false` on a push path sets
  `lastError` first**, or a dead session reports itself as a network problem.
- **Never guard a request on the stored `accessToken`** — it is a cache, and a
  cold launch has none until `restoreSession()` has been round the network. Call
  **`SupabaseAuth.currentUserID()`**, which awaits the token *then* reads the id;
  reading `userID` first reports "not signed in" for a session merely not
  restored yet. `loadProfile` is the one deliberate exception.
- **`public.users.sex` means the gender somebody *chose*, and nothing else.**
  `pushDemographics` sends only `birth_year`; HealthKit's biological sex would
  otherwise overwrite a chosen gender silently, repeatedly, and worst for exactly
  the people it matters most to. **Two columns that accept the same words are one
  column with two meanings.**
- **A published contact channel is a claim; test it with a round trip rather than
  a lookup.** `hello@written-stl.com` was on all five site pages while the domain
  had no MX record. **Records resolving is not delivery working.**

## Iterating on the garden illustration

**Five illustrated stages, one per connected modality plus bare soil**
(`TreeSkeleton.make`, 0-4 sprout→canopy). Stage 4 has art because falling through
to generated geometry there reads as the drawing breaking rather than as growth.

- **Drive stages from the launch line, never by patching the source** —
  `-route home -stage 3`, or `-stages all`, which is how shared geometry
  (`leafTilt`, `leafletTilt`, `LeafSpine`, the blade profile) is checked, since a
  sign error in one silently distorts stages nobody was editing.
- **Measure, don't eyeball**; one build per batch of changes, one cropped
  downscaled screenshot per iteration. Reference measurements live beside the
  constants they set.
- **Animate from a clock, not `repeatForever`** — any other explicit transaction
  touching a badge permanently replaces a repeating animation. One clock, no
  phase offset, paused when the tab is not visible.
- **Movement goes into `.position`, never `.offset`.** An `.offset` moves the
  pixels and leaves the layout frame behind, and the tutorial cuts its hole from
  `anchorPreference`, which reports that frame. **Nothing may sit between
  `.tutorialTarget` and the pixels that moves the drawing without moving the
  frame** — the arrival `.scaleEffect` is the other one, handled by making the
  mark wait for the spring (`badgeSettle`).
- **Badge positions come off `leafLift`, never `displayedSkeleton`** —
  `SeedlingArt.shoots(by:)` *blends* shoots toward their canopy shape past stage
  3, so reading the discrete stage lands that blend outside any transaction.
- `-tutorial badge` + `tools/badge_hole_check.py` measures the coach mark against
  the badge, and refuses a screenshot taken during the mark's fade.
- Rapid screenshot bursts and headless boots crash `backboardd`:
  `killall Simulator && xcrun simctl shutdown all`.

## The layout audit: what proves nothing overlaps

    ./tools/run_layout_audit.sh          # 5 iPhone widths x 2 text sizes
    python3 tools/layout_audit.py out/layout/*/

Accessibility frames plus geometry, because a screenshot only proves a screen
looked right where somebody looked.

- **`-solo 1` is required.** `AppShell` mounts every tab and hides the rest with
  `opacity(0)`, `allowsHitTesting(false)` and `accessibilityHidden(true)`, and
  **XCUITest honours none of the three**.
- **Never `descendants(matching: .any)`** — it kills the accessibility server.
- **The dumps come out of the result bundle** (`xcresulttool export
  attachments`); a UI test runner's `print` never reaches `xcodebuild`.
- **`tools/layout_allowlist.json` is judgement, not bookkeeping** — this app
  overlaps on purpose, so `--update-allowlist` without reading the diff is how
  the next real overlap gets buried.

Widths 375–440 catch geometry; the accessibility text size catches that **this
app mixes two font systems** — `BrandFont` scales, `.system(size:)` does not.
Discovery is not covered: it needs a real signed-in session.

## The two halves of the app

**Onboarding is a line; regular use is a tab bar.** Onboarding runs sign in →
birthday → name → gender → interest → communication style → photos → grow the
plant → "People you will see", and ends the moment **Explore** is tapped there.

**The birthday is first, and the ordering is the argument** — everything after it
is data the app may have no business collecting until that question is answered.
`minimumAge` is 18, enforced in `DistillViewModel.setBirthday`, again in
`BirthdayEntryView` (the page runs two screens ahead of any view model), and a
third time in `HealthKitDistiller`. Reviewers test it by typing a birth date.

**Continue raises a card that reads the date back in words** — the one answer in
onboarding that cannot be corrected later without a support request. It is an
**overlay, not a `.sheet`**, so the keyboard does not drop and return; **the
three refusals never reach it**, since drawing "You're 4" over a confirmation
would read a refusal back as an acceptance; and **`confirming: Date?` *is* the
presentation state**, so the card and the date it names cannot disagree.

**Gender is one answer and who you date is several, and the control says so.**
`Purpose.isSingleChoice` drives both arity and shape — radios for one, checkboxes
for many — because that shape is the only thing telling somebody whether a second
tap will replace their first, and single-choice rows *replace* rather than
toggle. The two pages **name the same three cases differently** and both are
right: "Male" is what you are, "Men" is who you would date. **"Everyone" is a
fourth row and not a fourth case.**

**Every step writes its local copy first and pushes in a detached `Task` whose
result nobody reads** — but `needsBirthday` and `needsGender` are answered from
those *local* copies, so a failed push is never retried and never re-asked.
`repairIdentityPush` is the backstop, run on every launch and guarded on the
server actually disagreeing.

**The communication step is two sliders**, flirt level and response time, because
both are *boundaries* and a boundary set after the fact has already failed —
which is why it comes before anything can message anyone. Continuous under the
finger, one of **four bands** to everything else: nobody can honestly place
themselves at 0.62 of a flirt. Flirt level carries **two vocabularies** — the
stored `rawValue` is flat, the dashboard shows `Platonic`/`Mild`/`Flirty`/`Freaky`
— because one is good to read about yourself and the other good to sort by.

**The flirt dial's geometry is fixed by one constraint, not chosen**: the
captions sit on thirds of the card and the arc's legs stand above them, so
`halfOpening = asin((0.5 - 1/3) / (diameter/2))` — **shrinking the dial widens
the gap**. `FlirtGauge` owns its captions and cancels `DashboardView.cardInset`,
because thirds of *the card* is not thirds of its content. Measure on a
screenshot showing the **whole** card (`-scroll photos`).

Two traps:

- **Adding a step re-opens onboarding for everyone who finished it** — the cached
  `restoredStep` said `done` for the steps that existed when it was written. It
  must match what `onboardingStep` computes live, and on finishing the next route
  is **asked for** rather than hardcoded.
- **The answers are collected before a view model exists.** They go to
  `CommunicationStyleStore`, which is *also* what `needsCommunicationStyle`
  reads, so having an answer and having been asked cannot disagree — unlike
  `hasSeenPhotoStep`, which needs its own flag because that page finishes whether
  or not anything was picked. `adoptStoredCommunicationStyle` runs after
  hydration and is idempotent, being also the repair.

Through onboarding the tab bar is absent: a bar would offer four exits from a
sequence whose whole point is that it has one. The garden keeps an arrow and a
pull-up gesture instead.

**That pull-up is a reveal**, and `AppShell.page`'s `opacity` hiding — right for
a bar — is wrong for a drag, since *two* pages are on screen while `tab` still
names the one being pulled away. `isDrawn` is the fix: *a layer needed during a
transition, gated on a flag that only moves at the end of it.* **Z-order matters
too** (the dashboard is built before the garden), hit testing stays on
`tab == which`, and `gardenLift` returns to **zero at rest**. `-reveal 0.5` /
`-reveal 1` is **the only way to screenshot Memories from a script**.

Regular use is the reverse: the bar exists, the garden gives up the arrow and the
pull-up, and the dashboard drops "Garden" and gains sign-out and delete — both
hidden during onboarding, since offering to destroy an account beneath the button
that carries on making one invites ending it by accident.
`OnboardingStep.exploring` marks the boundary; `AppShell` owns the flag and every
screen reads it.

## The tab bar, and why it must never inset

Four tabs: Explore, Chat, the garden, Memories. Wish is `ARCHIVED-WISH` —
`MainTab.wish` and `BottleIcon` stay commented in place. Nothing persists a
`MainTab`, so its raw values may shift when it returns.

**It overlays. It never takes layout height.** `promptsReserve` is what the
garden is measured against, so anything consuming height at the bottom of the
screen moves the plant — a regression this project has paid for four times.
Everything the bar needs comes *out* of the reserve, and `MainTabBar.overlayHeight`
is derived from the bar's own height plus its inset rather than guessed alongside
it. The garden's icon is drawn rather than named: SF Symbols has no potted plant
on iOS 16.

## Discovery: the only two tables one user may read about another

Every policy in `0001` is `auth.uid() = user_id`, which made a feed of other
people impossible rather than merely unbuilt. **Two tables open that up and no
more should without the same argument** — `bookmarks` is not a third: it names
another user in a column, but only the owner may read the row.

- **`discovery_cards`** — a name, an age, a district, six photo seeds and derived
  `{domain, subject}` pairs. Deliberately **not** a view over
  `distilled_records`: enough to write a line, and nothing that could reconstruct
  a distillation. **Subjects only** — things a sentence can be *about*.
- **`shared_posts`** — a video id and a sentence somebody chose to publish.
  `sharer_name` is denormalised because `public.users` is `auth.uid() = id` and
  opening it for a byline is not a trade worth making.

Both split read from write. **Re-run the 2026-07-29 probe from a real signed-in
session if these policies are ever touched** — a table opened for read is the one
place in this schema where a mistake is silent.

**Every card must have a writer.** For a long time only the six synthetic seeds
existed, because nothing in the app ever wrote one and every real signup was
invisible — the policies had been there from the start and only the caller was
missing. `DiscoveryCardService.publish` is it, called from `DistillViewModel.sync`.
**The viewer is excluded in the query** (`user_id=neq.…`), so it never crosses
the wire.

**A match profile is two reads and only one of them was ever guarded** — the
gated function returned school and bio while the name, age, district and
photographs came from a direct read of a table any signed-in user may read.
`public.match_card` sits under the same condition, and that condition is factored
into **`private.may_see_match` — one function called twice**, because a copy
would be the third place to edit and the first to be forgotten.

**`api.discover_profiles` is the server-owned replacement and ships dark**
(`assert_surface_allowed('matching')` requires `discovery_profile_reads`, which is
false). It exists because the rules currently live in the client, and **a
courtesy is not a rule when another client holds the same anon key**.

- **It returns terms beside each card**, since §10's gate asks for revision and
  surface permission, which are properties of an assertion rather than a card.
  Inferred assertions must also pass `concept_has_non_video_witness`; declared
  ones are exempt, having no observations.
- **The matching surface may *use* a term and may never *name* it** — naming
  somebody's term to another person is the **`bio`** surface. `matching_terms`
  gates on `bio.can_name`.
- **A derived claim needs no purpose grant** (product decision, 2026-08-13):
  terms are profile content like a photograph, Explore shows whoever fits the
  viewer's dating preferences, and the one lever a person has is Settings. **No
  consent screen, because what one would have bought already exists** — Memories
  lists the same terms and suppressing one there already removes it from
  `matching_terms`; what was missing was a line of copy saying so.
- **Back-fill row by row inside its own exception block, never one `update`** — a
  bulk statement meets the first guarded row, raises, and rolls back every grant
  behind it. And **carry `SQLERRM` out**, since the triggers it is natural to
  blame all early-return without their evidence type.
- **The client routes on the flag, and the asymmetry is the safety property.**
  Flag off falls back to the direct read; **flag on and the call failing does
  not** — a fallback on error would let an outage quietly restore the
  unauthorised path.
- **Rate limit is 60 calls an hour**, and **nothing sweeps
  `semantic_private.discovery_requests` yet.**
- **It filters on eligibility, which nothing did before, and that will read as a
  regression** — both production users correctly see nobody.
- **The two gender columns speak different vocabularies, which `lower()` does not
  bridge.** `users.sex` holds `Male`/`Female`/**`Non-binary`**;
  `users.interested_in` holds `male`/`female`/**`nonbinary`**. A casefold
  comparison **silently drops every non-binary person from every feed in both
  directions**. `private.gender_key` is the one place that maps them and returns
  null for anything unrecognised, so it fails closed. **The real fix is for the
  two columns to share a vocabulary.**

### Bookmarks

**A private note to yourself, and the privacy is the design** — one table, one
policy (`auth.uid() = user_id`), so the person bookmarked cannot read the row, is
never notified, and no trigger fires.

- **It is a real delete.** "Nothing in Postgres is ever deleted" describes the
  distillation record, not a list somebody curates.
- **Bookmarking does not remove anybody from the feed**, unlike a like — so
  `bookmarked` is a set the card draws from and never a filter, and it stays live
  on a card already liked, because the heart and envelope are one invitation
  spent once while this is not.
- **`bookmarkedIDs()` answers `nil` for *could not ask*.**
- `BookmarksView` draws `DiscoveryCard` through a real `DiscoveryFeed` so the
  photograph and line selection are Explore's code — but **one round only**,
  since a saved list is finite and repeating it would make four read as forty.

Reached from a bookmark icon **inboard of the cog** on the Memories header,
because Settings is the last thing on every bar in every app. Hidden during
onboarding. The old paper plane is deleted rather than disabled: an inert glyph
that looks pressable is worse than an absent one.

### Blocking

A block is mutual, server-side, and **the blocked person is told nothing**: no
notification, no error naming it, refusals borrowing wording the app already uses
for a deleted account. Both ways in the feed; a pending invitation is **revoked**
(a fourth `likes.status`, because *"I answered no"* and *"this was withdrawn"*
are different facts); an existing conversation stays **visible and frozen** —
blocking ends future contact rather than erasing history both took part in.

**Because it must be invisible, it cannot be enforced by an RLS policy.** A
policy runs as the caller, so it would need `authenticated` to hold execute on
the check — and anything a client may call, a client may probe.
`is_blocked(me, them)` is the one question the blocked person must not be able to
ask. Enforcement lives in **`security definer` triggers and RPCs**, and `blocks`'
select policy is `auth.uid() = blocker_id`, so the row is invisible to its
subject **structurally** rather than by a screen remembering not to draw it.

**Blocking is by phone number, resolved server-side.** `block_by_phone` returns
**void whether or not it matched**, because a distinguishable answer would make
the safety screen an oracle for *"is this person on Written?"*;
`block_by_phones` returns void for a stronger version of the same reason.

**Revoke from `anon` by name.** Supabase installs *default privileges* granting
every new `public` function to `anon` and `authenticated`, so `revoke … from
public` — which names the pseudo-role — leaves a direct grant untouched.

**Blocking is deliberately absent from `ProfileActionsSheet`.** It lives in the
block list, because it is the only one of these that can be undone and a control
you can undo wants a screen where you can see what you have done. A match offers
**Unmatch** and Report — irreversible, and the word says so.

**The contacts toggle promises more than it does.** `importContacts` takes names
only, on a documented refusal — uploading an address book collects data about
people who never agreed to anything — so *"people you already know cannot see
you"* is true of nothing. Closing that gap means uploading contact identifiers,
which needs `PrivacyInfo.xcprivacy`, `web/en-us/privacy/` and the App Store
questionnaire moving in the same commit. **`block_by_phones` is deployed with no
caller** for exactly this reason.

### The feed's rotation

`DiscoveryFeed` shows a person repeatedly with different photographs and lines —
two of each, drawn without replacement, on independent cycles.

**The round order is fixed, and that is not laziness**: five profiles between one
person and their next means `q >= p` for everyone simultaneously, which only the
identity permutation satisfies, and a repeated permutation gives `n - 1` every
time — the most any ordering can offer.

**A like removes that person from the feed on the next scroll, not on the tap.**
Removing their cards instantly takes the post out from under the reader's thumb
and hides the one piece of feedback the gesture has, so `like` touches nothing
but `liked`.

**`DiscoveryModel` filters the *output*, in three places that have to agree** —
`load` builds from the unliked, `extend` purges liked people from `items`, and
`extend` drops them from each new batch; miss the last and they return the moment
the list grows. The purge sits **above** `extend`'s near-the-end guard, removes
only indices **strictly after** the one that appeared, and the top-up loop is
**bounded**, or it spins forever once everything left has been liked. **An
all-liked feed is not a failure** — leave `failure` nil so the empty state shows.

Shared videos are interleaved every fourth item rather than mixed into that
machinery, since the separation rule is about people. Their ids carry an
**appearance number**, as profiles' do: duplicate `ForEach` ids hung the app.

## Embedding YouTube, which took six attempts

**The player will not run in a document with no origin, and an app-built page has
none.** A base URL is not an origin, an `origin` player var is a claim, a
top-level `youtube.com/embed` load gets 153, and **Supabase cannot host the
page** — edge functions and Storage rewrite HTML to `text/plain` with
`default-src 'none'; sandbox`. What works is `loadSimulatedRequest`, naming a
**third-party** origin rather than claiming to *be* youtube.com.

`EmbedWebView` forwards `console`, `window.onerror` and player errors through
`onLog` — nothing draws them, and the next blank player will want them back.

Playback follows the card nearest the middle, **muted** (WebKit blocks unmuted
autoplay outright), one at a time. Sound is a preference of the *reader*, so
unmuting one video unmutes the feed, and resets on launch.

## The share extension

`ShareToWritten` is the second of three targets. (`NotificationService` is the
third and deliberately carries *neither* the App Group nor the keychain group —
its image URL arrives pre-signed and it needs no session.) `ShareToWritten` needs
three things on **both** targets: the App Group, a shared keychain group, and
matching bundle ids. **Verify entitlements in the *signed* binary, not the
`.entitlements` file.**

It is **deliberately self-contained**, repeating the host, the anon key, the
keychain read and the link parsing rather than sharing files — synchronized
folders scope everything under `Written/` to the app target, and sharing means
the pbxproj surgery that arrangement exists to avoid.

Three things the template gets wrong: its `TRUEPREDICATE` activation rule offers
Written for photos and contacts it cannot use; its compose sheet pre-fills the
text view with the shared item, publishing the URL as the caption; and
**`INFOPLIST_KEY_*` build settings beat the `Info.plist` file**, so the display
name has to change in `project.pbxproj`.

## Likes and chat, and the upsert that column grants forbid

**`resolution=merge-duplicates` cannot be used on `likes`, `conversations` or
`messages`.** It compiles to `on conflict do update`, and Postgres checks
privileges when it *plans* — so it demands `update` on every column inserted,
whether or not the row exists. `0009` revokes update on all three and grants back
only the narrow columns each side may answer with (`status, responded_at`;
`read_at`), precisely so a recipient cannot rewrite `liker_id` and forge a like.
The failure is **42501 on every attempt**, and it shipped silently because the
heart fills optimistically. Use `ignore-duplicates`. Every other table keeps its
default privilege, so `SyncService` and `SupabaseAuth` are fine.

**There is a second precondition, and it is a policy rather than a privilege.**
`on conflict do update` must be able to *see* the row it might update, so **a
table with RLS enabled and no select policy cannot be upserted into at all**,
even when empty. That reads as a wrong `user_id` and is nothing of the sort. So:
**`merge-duplicates` needs update privilege *and* a select policy.**

**Names and photographs come from `discovery_cards`, not from a denormalised
copy.** `likes.liker_name` copied onto a conversation made a profile read one
name in Explore and another in the chat header. The stored columns remain as the
fallback the insert policy needs at creation. **The same gap existed on the two
single-conversation fetches**, so a thread opened from a notification drew the
generated portrait and the frozen name.

**One invitation per person, and it is either a heart or a note** — whichever was
used is filled, the other fades, both go inert.

**`23503` means the person deleted their account.** Every foreign key leads back
to `public.users`, and a discovery card outlives the account because the feed is
built once and scrolled. `PostgREST.Failure` carries the error code rather than
folding it into the message, and the feed says "That profile is no longer
available."

**Two accounts are needed to test any of this**, because RLS makes each half of a
conversation invisible to the other; `tools/chat_e2e.py` plays the second person
over REST. A simulator cannot be the first person. **Read the database after
every step rather than trusting the screen.**

## Notifications: a like, a match, a message

Three events, sent from the database rather than a phone — the person to be told
is by definition not the person making the request. `likes`/`messages` trigger →
`pg_net` → `functions/push` → APNs.

- **`pg_net` is fire-and-forget**, so a dead APNs cannot make a like fail — but
  it records every response in **`net._http_response`**. **Anything the function
  needs to say should travel in the response body**, not only to `console`.
- **The URL and shared secret live in `private.push_config`**, a table in a
  schema nothing is granted on — not a GUC, not a literal. The function is
  deployed with **JWT verification off**, which is mandatory rather than lax:
  triggers carry no Authorization header, and the toggle demands a JWT signed by
  the disabled legacy secret. `x-push-secret` is the auth instead.
- **A successful install proves nothing about push** — automatic signing issues a
  profile carrying `aps-environment: development` whether or not the App ID has
  the capability. Apple's **Push Notifications Console** and a *distribution*
  profile are what check.
- **It is a `.p8` key, not a certificate, and it must be created as "Sandbox &
  Production"** — the page lets you create one that is not, and a single-
  environment key answers **403 `BadEnvironmentKeyInToken`** against the other
  host, so it delivers every Xcode build's notification and refuses every
  TestFlight one. That reads as *lateness*, not failure. **`sent: 2` with
  `["ok","ok"]` to somebody with two devices is the only proof both environments
  work.**
- **The token's environment is not bookkeeping** — two hosts, two namespaces,
  both kinds of token here at once. `device_tokens.environment` records it and
  `#if DEBUG` decides it.
- **iOS allows the permission question once, ever**, so **`NotificationPrimer`
  asks first** — the app's own sheet, naming what arrives; only *Turn on* is
  passed to iOS, and a "not now" spends nothing and returns in three days. Fired
  on reaching Explore or Chat, 900ms after the transition, and nowhere near
  Health. **A refusal is said out loud**, with a route to Settings — left unsaid,
  every notification reports `{"sent":0,"note":"no devices"}`, a *success*.
  `-push ask` exists because testing this otherwise means arranging to be liked.
- **`SUPABASE_` is a reserved prefix** and a secret using it cannot be created;
  the function reads the platform-injected `SUPABASE_SERVICE_ROLE_KEY`, which
  carries the `sb_secret_…` value despite the stale name.
- **`create or replace function` does not replace a function whose *signature*
  changed — it overloads it**, leaving an ambiguity Postgres refuses with `42725`
  *from inside a trigger*, where the like fails rather than the notification.
  **Changing parameters means `drop function` naming the old signature in full.**

### The banner is a person, not an app

`NotificationService` turns each notification into a communication notification:
the sender's photograph on the left, their name where the app's name would be.

**A `UNNotificationAttachment` cannot do this.** It needs **three things in three
places, each silently inert on its own**:
`com.apple.developer.usernotifications.communication` in the entitlements,
`INSendMessageIntent` in `NSUserActivityTypes`, and an `INSendMessageIntent`
donated from the extension then `content.updating(from: intent)`.

**That plist key needs a real file, because `INFOPLIST_KEY_` ignores names it
does not know** — it wrote nothing, no error, no warning. `Written-Info.plist`
sits at the repo root rather than under `Written/`, since that folder is a
synchronized group and a plist swept into Copy Bundle Resources ships twice.
**Read the built `Info.plist`, never the setting.**

**`updating(from:)` renames the title to the sender's display name**, so the
headline must travel in `subtitle` — otherwise the banner announces somebody
called "Marco likes you".

**The photograph is signed server-side**, because authenticating inside a process
with a thirty-second life would mean the shared keychain and a refresh, for a
picture. **Everything in the extension falls back to the plain banner** — a
notification that arrives looking ordinary is enormously better than one that
does not arrive. `INPersonHandle` is `.unknown`, or iOS matches against Contacts
and puts somebody's saved contact photo on a stranger's profile;
`INInteraction.direction` must be `.incoming`, or Siri learns that *you* messaged
everyone who has ever messaged you.

## The semantic contract, and what it supersedes

**`Written-Semantic-System-v0.3.1` is the authority for semantic design, and this
app is not.** *"When the current Swift/SQL implementation and the v0.3.1 contract
disagree, the v0.3.1 contract controls."* Its governing rule is **capture broadly
in an authorized private vault, promote narrowly into semantic evidence, expose
only purpose- and surface-authorized projections** — four separate decisions
where the legacy path has one.

| Named as superseded | Becomes |
|---|---|
| `Ontology.swift`, `mix`, `terms`, `classify` | Server-owned classification and mapping; legacy behind a flag during shadow |
| Client-authored `discovery_cards` semantics | A server-owned RPC enforcing block, eligibility, revision and surface grants |
| `summary_distilled_records` as current state | Ingestion runs with membership, coverage, tombstones and validity windows |
| `seed_icebreaker` (`0036`) | Revision-bound frames requiring active match authorization |
| Title-keyed `BanList` removals | Assertion-specific no-reason RPCs; a title ban never becomes a concept-level negative |

Everything below about the ontology, the dynamic profile, Memories and the
icebreaker is **still true of the shipping code and is now the legacy path**.

**Migration head `0200`.** `db push` deploys; `supabase/DEPLOY.md` is the
procedure. **Each migration carries its own reasoning in its header comment**,
and that is the record — this section carries only what a later change could
violate. **Read `semantic/JOURNAL.md` before removing a guard, adapting another
reference migration, or concluding that something looks arbitrary.**

### The second real account, and what it proved (2026-08-13)

**The creator vocabulary is one person's Apple Music library and does not
generalise** — a second account with seven sources produced zero assertions with
nothing failing. **Vocabulary was never the binding constraint; evidence was**:
publishing a wider ontology halved the unresolved terms and still produced no
eligible assertion, because that whole vault is 50 YouTube observations.

**Never add rows to `seed_*.csv`** — `test_seed_consistency` asserts those three
mirror `0044_semantic_seed.sql` field for field. New vocabulary goes in its own
CSV family; `tools/seed_from_csv.py` reads `FAMILIES` and **does not emit the
recompute enqueue**, which is hand-added.

### YouTube channels are terms, and the flags that decide it

- **`ontology.youtube_policy_approvals` is a row of booleans, and a new row
  supersedes rather than an edit.** `initialize_youtube_run_policy` copies the
  most recently approved onto the run, so the older determination stays history.
- **The trigger looks up `model_key = 'youtube_uploader_tag_resolver'` by
  literal.** A differently-named resolver leaves that lookup empty and the
  trigger falls to its deny-all branch — every future run silently denied,
  nothing failing. Assert it rather than assume it.
- **Channel titles come from `distilled_records`, not the API** — liked-video
  rows carry `channel_id` in `extra` and the title in `creator`, and a
  `subscription` row *is* the channel. No key, no quota, no network call.
- **A payload field must be read from every shape that carries it.**
  `VideoPayload` read `channel_id` from `extra` only, so every subscription
  reached the vault with a null channel — the stronger signal, silently dropped
  until something gave channel ids a use.

### Three levers force a re-score, and a policy is not one of them

A run's identity is `(user, revision, ontology version, resolver, scorer)`.
**A policy grant is not in it**, and `enqueue_recompute_on_analysis_change` only
enqueues where no run exists for that tuple — so **a behaviour change needs a new
model version**, and a model version that lags its code makes `semantic_runs`
state something untrue.

**Read the grants first, not sixth.** `semantic_worker` is `bypassrls`, and that
is **not a grant**. `information_schema.table_privileges` shows only what the
*querying* role can see and answers empty for `ontology`; ask
`has_table_privilege`.

### Where the informative fields actually are

On YouTube repost rows the channel name is meaningless, the topics are
containers, the uploader tags are null — and the **title** carries everything.
**The projection keeps the fields carrying nothing and excludes the one carrying
everything**, because III.E.4 requires titles deleted or refreshed within 30 days
and the payload is frozen. The guard prevents *updates*, and no trigger fires on
delete — but foreign keys do.

**Live defect:** scorer 0.7.0's co-attestation rule reads
`bool_or(subscription) and bool_or(liked)` across all mappings for a concept,
promoting concepts outright on incidental tags from *unrelated* channels. Fixed
in the repository to intersect on channel id; **not deployed**, and the
assertions are still eligible in production.

### The schema, and who may reach it

- **Every semantic object is `semantic_private`.** The reference chain uses
  `private`, which this app already owns (`push_config`, `notify`,
  `collaborators`). **No executable statement in an adapted migration may name
  `private`** — the hazard is the grant, not the revoke.
- **`semantic_private` has RLS on and no policies anywhere.** Access is decided
  by role grants and `security definer` functions. Adding the first policy costs
  that sentence, so it needs an argument.
- **Two identities, and neither may become the other.** `semantic_ingestor` can
  call exactly one `security definer` function and holds **zero table
  privileges** — leaked, it writes vault rows and reads none back.
  `semantic_worker` is `bypassrls` with an **enumerated** grant list, nothing
  outside `semantic_private`, asserted from the catalog at migration time.
- **`on all tables` binds at execution time**, so every table a later migration
  adds gets no grant unless that migration grants it explicitly.
- **When a migration needs a grant, read `pg_trigger` for the tables being
  written and follow what each trigger calls.** That is the first move, not the
  sixth.

### Keys and crypto

- **Ingestion gets encrypt-only; the worker gets decrypt.** The thing exposed to
  the internet can write into the vault and cannot read it back.
- **The data key is per *call*, inherent rather than chosen** — a write-only
  identity cannot reuse what it cannot recover, and a Lambda is stateless.
  "Active" means the key the latest ingestion used.
- **The key and the rows travel in one statement.** Two calls have a failure mode
  where ciphertext exists and the key to read it does not, indistinguishable from
  data loss and unrecoverable by retry. Reusing a version with a *different*
  wrapped key is refused outright: refusing costs a retry, accepting costs the
  data. The key is written *after* the rows and only if any survived the conflict.
- **Crypto erasure means deleting the user's wrapped-key row, never the KMS
  key** — one is a routine deletion request, the other erases every user at once.
  Account deletion cascades the keys to zero. `semantic/docs/KMS_DESIGN.md` is
  the design.
- **`key_version` must match `raw_source_records.encryption_key_version`'s
  pattern**, asserted from the catalog by `0051` rather than trusted to a
  comment.

### The device half

- **Dual-write runs on its own detached task and shares nothing with the legacy
  push** — not the task, not `syncFailure`, not `lastError`. **A shadow path that
  can break the live one is not a shadow.**
- **It applies `SyncService.isLocalOnly` before deriving anything.** A second
  upload path is precisely how `health/biological_sex` never leaving the device
  stops being true without anybody deciding to break it. The rule is *asked for*
  rather than reimplemented.
- **Refusals are counted, never swallowed** — an unmapped `data_type` otherwise
  shows up as a batch quietly smaller than the distillation it came from.
- **A permanent refusal is dropped, not retried; 401 is transient.** **A
  projection refusal is a 4xx**: sent as 500 it is retried forever at the head of
  a FIFO queue.
- **Enabled per source** (`AppConfig.semanticIngestionSources`), never per build:
  a disagreement found in one source is a diagnosis, in nine a shrug.
  **Dual-write excludes YouTube and Spotify on licensing grounds.**
- **Two translation seams, and only two** — `appSourceCode` maps `health` →
  `healthkit`, `semanticDataType` maps calendar rows to
  `calendar_event`/`scheduled` — pinned by a test that asserts **nothing else is
  translated**. Renaming either side would rewrite history in an append-only
  table.
- **The vocabulary is checked from both ends, because neither end can see the
  other**: `test_ios_envelope_contract.py` reads the distillers, and
  `tools/replay_contracts.sh` asks the *built* schema whether each claimed action
  is one that source weighs.
- **`actionsByDataType` has three answers, and the middle one is the point**: an
  action the server weighs, a real signal it does **not** weigh yet, or
  structurally not an act. Collapsing the middle into the last is how the list of
  things still owed a decision disappears.
- **`SourcePayload+Legacy.swift` is scaffolding and is meant to be deleted.**

### Capture against promotion

- **Capture must not depend on promotion.** Finalize only when the run has a
  scope; otherwise leave it `running` and inert rather than rolling back a
  captured batch.
- **A scope is `(source, data_type, action)`, because `action_type` is
  `not null`.** A row with no action belongs to no scope, gets no run item and is
  never promoted. *Capture broadly, promote narrowly* falls out of the schema
  rather than being imposed on it.
- **`partial`, never `complete`.** Only `complete` licenses expiring an item that
  went missing, and every read is capped — claiming a complete snapshot would be
  inferring absence from omission, which §10 forbids. It is the difference
  between a bad afternoon for one connector and somebody's library disappearing.
- **A duplicate still needs a run item.** The insert is `on conflict do nothing`,
  so resolve ids by lookup, not only from `returning` — a head that missed a
  seen item reads as the item having gone away.
- **Evidence is written by ingestion, not by the worker, and the schema decided
  that.** `guard_observation_ingestion_run` refuses any observation whose run is
  not still `running`, while finalization enqueues the worker *after* the run
  closes. No grant fixes it, and a worker that could update a run could mark
  somebody's capture complete.
- **A run that promoted nothing is finished, not running** — every `user`
  distillation produces one. Close it with
  **`close_unpromotable_ingestion_run`**, never an `update`: a migration that
  knows better than the guard is how the guard stops meaning anything. It raises
  its own flag, so any trigger exempting the finalizer's must be taught this one.
- **The whole row speaks the schema's language** — raw row, observation and scope
  `data_type` must be equal, so an observation cannot hold a vocabulary of its
  own. **Renaming a `data_type` re-stores every row and orphans its current
  items**, since a `partial` scope licenses no expiry.
- **The fingerprint must not depend on the encoding.** `fingerprintContent`
  unwraps the discriminator and drops `schema_version`. **Never reduce an
  unrecognised payload shape to a subset of its keys** — `{title}` and
  `{title, playCount}` hashing alike means a changed record is skipped as a
  duplicate and lost.
- **`schema_version` is `written-source-envelope-v2`, v1 rows exist forever, and
  a reader must handle both.** The vault is append-only and the ingestion
  identity has no `Decrypt`, so an encoding can never be rewritten.

### Reading the vault

**Read `current_source_items`, never `raw_source_records`.** Nothing supersedes a
prior revision — a row whose payload changed is captured beside the old one and
both stay `active` — and `ingest_healthkit_rows` quarantines **both** sides of a
lineage whose fingerprints disagree. Same rule as reading through the `summary_*`
views, one layer down.

**Comparing the vault against the legacy path compares two different things.**
`distilled_records` is append-only, its summary views are a union across runs,
and the legacy path stores only changes. The comparison that means something is
the **second** distillation.

### The revision, and what may move it

**`api.list_assertions` withholds every *inferred* assertion whose score was not
computed at the account's current revision** — the difference between a claim
about somebody and a claim about who they used to be, and why **the Memories page
goes blank rather than stale**.

**The revision means *"which version of the inputs were these scores computed
against"*, so it moves when the scorer's inputs move — not when state changes.**
Three migrations were needed to get that sentence right, each the same shape: **a
trigger fired on something that looked like a change and was not, and the cost
was every score the person had.** A declared assertion has no observations and is
**exempt from the currency check by construction**.

| action | bumps | why |
|---|---|---|
| `suppress` / `restore` | **yes** | redistributes weight; the score really changed |
| `confirm` | no | nothing reads it yet |
| `explicit_add` | no | no observations, no mappings, never scored |

**The revision is monotonic and is never walked back** — the repair is always to
re-score at the revision that now stands.

### Classification and scoring

- **The Calendar classifier is its own Lambda**, vendored rather than ported.
  **Titles go in and do not come back**: the stored payload is at most four keys,
  and a test asserts no fragment of a title, address, organiser or email domain
  survives into it. Its IAM role holds `kms:GenerateMac` on the lineage key and
  **nothing else**, and the lineage signer is **salted per user**, because
  `content_lineage_hmac` exists to be joined on and an unsalted digest would be a
  cross-account correlation handle. **A classifier failure must never fail a
  distillation**; `CALENDAR_CLASSIFIER_ARN` unset is a deliberate off switch.
- **An event is excluded unless positively recognised** — the allowlist is the
  design, not a gap. `_FLIGHT_TITLE_RE` matches the canonical title and nothing
  else.
- **Deploying resolver or scorer code re-scores nothing.** The run identity has
  no code version in it, so **three levers force a fresh run**: a new
  distillation, a new ontology version, or a new model id. Parameters live on the
  model row where a later reader looks, not in a commit message.
- **Retire the old version in the same migration; never leave two active.** The
  finalizer picks the newest *active* model, so leaving both works by ordering,
  which is a coincidence rather than a statement. **Retirement is not deletion.**
- **A model version and the recompute it implies belong in one migration**, and
  **a migration that publishes an ontology version or activates a model ends with
  `semantic_private.enqueue_recompute_on_analysis_change`** — ingestion is the
  only other thing that enqueues and cannot see a model publish.
- **A rule that only withholds arrives too late for exactly the rows it was
  written for.** A scorer that refuses to assert hubs leaves standing hub
  assertions untouched.
- **A suppression is an `ambiguous_rejection`, and redistribution is
  disambiguation rather than a negative.** Nothing asserts a dislike;
  `user_suppressions` stays empty and is where a real negative would live.
  **Freed weight goes to a *different named role on the same row*** — `creator`,
  `composer`, `source_work` — apportioned by existing weight, **never to the same
  role** and **never to genre, era, scene or sphere**. **Conservation rather than
  a constant**, applied before saturation. Writing it in the resolver's *roles*
  rather than in `concept_kind` is what makes classical and pop one rule.
- **A scene's decade and sphere must come from the same row**, or an artist-level
  era reaches a scene twenty-eight years off. **An era is an axis; a scene is the
  claim** — `era:*` and `sphere:*` are scored and never asserted, through
  `NEVER_ASSERTED_KEY_PREFIXES` rather than by kind, all three families being
  `concept_kind = 'topic'`. **A marked genre silences the unmarked ones on its
  row** while the union across *rows* survives, so a bilingual act keeps both.
  **Classical periods are never crossed with a sphere.**
- **Match labels are `alternate`, not `preferred`** — the resolver emits the bare
  key suffix, so a prose `preferred` label never meets it.
- **Mint no vocabulary from `recommendation` rows** — `action_weight` 0.000,
  Apple's suggestion rather than the person's act.
- **Authored vocabulary is minted whole, not on demand**, or the concept set
  differs per install. `EmergentTermMiner`'s five-user floor governs *emergent*
  strings only.
- **A fallback key must not be able to collide** — a constant fallback merged
  nine artists into one concept. (`unicodedata.normalize("NFKD")` decomposes
  Hangul into jamo, so a `가-힯` character class strips Korean names to empty.)
  **Correcting such a merge does not rewrite history**: the old concept keeps its
  id and mappings, is deprecated with its labels withheld, and the assertion
  resting on it is retired `inactive`.
- **Invoke the worker serially**, and run psycopg with
  **`prepare_threshold=None`** — the transaction pooler makes an auto-prepared
  statement fail `42P05` on the second of two back-to-back invocations.
- **`exact_terms_only`: no fuzzy matching.** The `SequenceMatcher` fallback
  consumed a whole 300-second Lambda timeout and every result was discarded
  anyway, the fuzzy path returning only `CANDIDATE` or `REJECTED`.
- **`strength` saturates as `w/(w+6)` rather than summing**, since a hard cap
  would tie every strong concept at 1.0. **`stability` is 0.0 on a first run and
  that is a refusal.** The curve is nearly flat at the top, so **a percentage cut
  cannot demote anything**; weights are chosen against the 0.35 eligibility bar.
- **The scorer withdraws as well as raises.** Scored-and-no-longer-eligible is
  demoted in the loop; never-scored-at-all is swept afterwards. Both `inferred`
  only — no absence of evidence overrules what a person said about themselves —
  and **the sweep is guarded on the run having scored something**, since a
  fallen-over resolver must not read as somebody who likes nothing. A unit test
  asserts **which statement ran**.
- **A classical performer is weighed by distinct albums, not rows**, weighed
  `0.02` below two albums rather than dropped, since the term still has to exist
  for `EmergentTermMiner`. **`_is_classical` falls back to a catalogue number
  only when no genre is stated at all**, and a composer prefix must *be* the
  prefix.
- **Assert resolvability, not counts** — counting the right number of
  unreachable things is what a structural check gets wrong.

### The surfaces

- **Two switches, and they are not redundant.**
  `AppConfig.semanticSurfacesEnabled` decides whether the app *asks*;
  `memories_reads` decides whether the server *answers* and is §9's rollback
  contract, throwable without a release.
- **The `api` schema is exposed by hand** — no migration can do it. Unexposed,
  every RPC answers `PGRST202` naming **`public.list_assertions`**, which reads
  as a missing function. **`PostgREST.callFunction` sends both `Content-Profile`
  and `Accept-Profile`**, because an RPC is a POST that reads and setting one
  sends half the calls to `public`.
- **An answer must name the exposure it answers** — "I disagree" refers to a
  particular label at a particular rank computed by a particular score version.
- **`list_assertions` is an allowlist of `concept_kind`** (`creator`, `work`,
  `activity`, `topic`), so a new kind is withheld until somebody decides it
  belongs: an internal kind appearing on a profile is worse than a nameable one
  being missed, because only the first is invisible to whoever added it. **A
  user's own term always survives it**, having no concept and therefore no kind.
  - **`topic` is admitted less three key prefixes**, and the exclusion is the
    whole of the change: `era:`, `sphere:` and `scene:` are *also*
    `concept_kind = 'topic'`, and every topic assertion in the database is one
    of them, so widening on kind alone would have restored exactly the set
    `0108` removed and added nothing. **The kind cannot separate the axis from
    the claim** — `score.py`'s `NEVER_ASSERTED_KEY_PREFIXES` says the same from
    the scorer's side. `genre` and `place` stay out.
  - It admitted nothing on the day it shipped: the 14 `subject:*` concepts it
    exists for score 0.054 at best against a 0.35 bar. **It is a precondition
    for imported vocabulary, not a release of withheld terms.**
- **YouTube may raise a concept's strength and may never be the only reason it
  crosses to another user.** "Concepts are ours so anything goes" is the wrong
  answer — a concept only YouTube witnesses still discloses YouTube data.
  `concept_has_non_video_witness` is the test: if a non-YouTube source attests
  it, the identical row would be published with YouTube disconnected. It requires
  `mapping_state = 'accepted'`, a candidate being a fuzzy near-miss the scorer
  discards. **YouTube still supplies the second independence group, which no
  music source can**, and no gate is opened — `allow_bio`, `allow_icebreaker`
  and `allow_cross_source_fusion` stay false.
- ***A check that can be skipped will be skipped exactly when it is needed***,
  because the condition that makes it skip is usually the bug. Demand the
  predicate answer **both true and false over real data** rather than guarding
  the assertion on a table being non-empty.
- **The work bar is 0.25 against creators' 0.35, and it is a judgement** — a
  creator accumulates across everything they touch while a work is attested only
  by its own songs, so the same strength means more evidence.
- **The flag check lives inside `assert_surface_allowed`**, not beside it; a
  parallel check is how two tests that must agree stop agreeing. It is **`stable`,
  never `immutable`** — an `immutable` guard may be folded at plan time, meaning
  evaluated once and never again. The kill switch comes free.
- **A check on a function's source text is not a check on its behaviour.** Flip
  the flag, call the guard, assert the answer changes in both directions and with
  the kill switch down, then restore every flag and prove that too — inside the
  migration's transaction, so it re-runs on every replay.
- **Rewriting a reader to add a guard drops what is at the bottom of it** — a
  pasted body lost its `order by`, and **Memories draws in the order it is
  given**, so an unordered read named somebody's fourteenth-strongest trait as
  what they are most about. A column-count assertion cannot see ordering.
- **A verdict attaches to the assertion, never to the run**, so a review survives
  any number of re-scores. **`assertion_reviews` and `assertion_preferences` are
  two facts in two tables on purpose**: a reviewer's *"this claim is wrong"* is
  diagnostic, a user's *"don't show me this"* is product, and one column for both
  means a diagnostic judgement silently becomes a hide.
- **`-probe-surface 1` reads and never writes**, unlike `-probe-ingest`: confirm
  and suppress are somebody's own answers about themselves. **`-probe-ingest 1`
  writes a real encrypted row deliberately** — run it twice; the second receipt
  should read `stored 0, duplicates 1`. Both need a device.

### Where the pipeline stands

**Phase 2 closed 2026-08-12 on two accounts.** 65 active assertions per account,
thirteen concepts reaching two independence groups — which `motif_rules` requires
as a check constraint and which nothing in this system had ever had. **The music
sources all carry the `music` group by design, so no music source can ever be the
second witness.**

**HealthKit classifies and correctly produces nothing** — 390 accepted, **0
rejected**, coverage `aggregate_only`, which is what §10 requires when every
`activity:*` concept derives from typed workout sessions and no test device has
an Apple Watch. `rejected = 0` is the load-bearing number. **Calendar promotes 5
of 101**; the `excluded_unknown` majority is the allowlist working.

**The vault cannot answer "what was promoted and why", by design**, so
`tools/calendar_review.py` re-derives each decision from the legacy row with the
same classifier and catalogs, and a test pins its constructor arguments because a
missing catalog would silently reclassify. And **anything counted off
`distilled_records` counts history.**

### The dynamic profile

The official way one match presents themselves to another — distinct from the
dynamic *bio* (a line on a discovery card) and the *icebreaker* (a tip in a
thread).

**Reachable from exactly two places** — the avatar on an invitation and on a
chatroom banner — and **the rule is in Postgres, not in which buttons exist**.
`match_profile()` is `security definer` and returns rows only to somebody holding
a like *from* this person or a conversation *with* them. **A page reachable from
two buttons is a drawing; a function that returns nothing is a rule.**

- **The gate must consult state, not just existence.** `pending` (an open
  invitation is the *reason* the page exists) and `accepted` authorise;
  `declined` is history. Testing only that a like row existed left the sender's
  school and bio readable to the person who declined them, permanently.
- **The conversation clause is the second place blocking has to be consulted** —
  `conversations` carries no ended state, so its existence *is* the current
  authorisation.
- **The split is by how identifying a field is.** Name, age, district,
  photographs and the ontology mix are on `discovery_cards`, readable by every
  signed-in account. **The school and the bio are not, and must not be.**
  Anything added to this page must be sorted into one of those two piles before
  it is drawn.
- **`match_profile` returns zero rows for a refusal *and* for a match who filled
  in neither field, deliberately** — distinguishing them would tell a caller
  whether an account exists. So **`-probe-match <uuid>` prints the like and
  conversation rows beside the RPC's answer**, and must be pointed at somebody
  who has a school or a bio.

Two traps all three probes share. **An alert is a single-shot surface** — writing
`result` twice shows only the first message, so probes print to the console too.
And **a launch argument only exists when Xcode launches the app**; from the home
screen or the app switcher every probe silently does nothing.

### Phase 3: Memories draws assertions, and the legacy cards stay beside it

The surface (`api.list_assertions`, `confirm_assertion`, `add_assertion`,
`suppress_assertion`, `restore_assertion`, `record_assertion_exposure`) is each
`security definer` and scoped to `auth.uid()` with **no parameter for whose**.

**The difference from the legacy cards is what a row *is*.** There a row is a
string filed under a domain guessed at by substring, and striking one off goes
through `BanList.Kind`, which removes **every row whose name matches**. Here a
row is a concept with an id and `suppress_assertion` names one assertion — which
is what makes "a title ban never becomes a concept-level negative" true rather
than merely intended.

**What the page shows is `concept_kind`**, filtered to `creator`, `work`,
`activity` and `topic` (less `era:`/`sphere:`/`scene:`, `0197`) on the owner's
judgement: *"the terms shown should be well defined
enough to strike off or understand."* Genres, scenes and spheres remain asserted,
scored and evidenced, and are what Phase 4's discovery matches on. **Both
readings are on screen at once deliberately**, so the two can be compared.

### Memories is the ontology's surface

Legacy path. `Ontology.terms` groups everything distilled under the domain it
landed in and `DashboardView.domainSections` draws one card per domain — it
replaced five cards named after *sources*, which were a picture of the plumbing.
**Every term is the source's own string**, which is what keeps the page a reading
of somebody's data rather than labels applied to them.

- **Striking a term off goes through `BanList.Kind`, never a new `.term` kind**,
  so the records behind it are `markedRemoved` and stop feeding the mix, the
  discovery card and the icebreaker. A ban that only hid the row from this page
  would make the website's *never used, never shown, never counted* untrue.
- **YouTube goes through a different door, structurally rather than by a rule to
  remember.** `Ontology.youTubeTerms` cannot reach `classify`; it reads `topics`,
  `tags` and `category_id`, and a channel carrying none of the three is
  **absent, not placed plausibly**. **The YouTube cards empty themselves** as the
  sweep runs, and that must never be drawn as a failure.
- **The readings are not terms and stayed behind** — the chronotype and step
  average have no entry behind them for anybody to agree with.

### Growing the vocabulary: slices, offline, bounded by what the source states

`tools/wikidata_vocab.py` imports whole domains from Wikidata (CC0) on a laptop.
**It is not the resolver calling out, and nothing about the egress posture
changed**: `allow_external_resolution` is still written `false`, six projection
guards still refuse a row where it is not, an external hit is still permanently
`CANDIDATE`, and `resolve.py` still constructs no provider. What makes an
offline import honest is that **the query names the slice, never a user's
string** — `observation_mentions` is read locally to decide *which* slice is
worth having.

- **Notability is a number the source states** — sitelink count, the same shape
  as `subscriber_count` in `0195`. **And it only works for things whose fame is
  their own.** An `athletes` slice was written and removed: at any selective
  bound it returns the most famous *humans* who happen to have a sport recorded
  — Plato, Joe Biden, two Bushes, Gerald Ford — and requiring a sportsperson
  occupation does not help, because Camus kept goal. The next step would have
  been a deny-list of occupations, and **the failure mode of a deny-list is
  silence**. A person-shaped slice needs a signal *about the thing*, not a
  louder measure of fame.
- **A titled work hides its name in the article title.** Wikidata stores no
  English *label* for Minecraft, GTA V, Tetris, Roblox or Fortnite — the English
  Wikipedia title carries it — so `SERVICE wikibase:label` answers with the bare
  QID and `0198` dropped 90 of 304 games without saying so. `0199` reads
  `schema:about`/`schema:isPartOf <https://en.wikipedia.org/>` as a fallback.
  Common nouns are unaffected; **any future slice of works must ask for both.**
- **Refuse at both ends.** `subject:health` passed every key check — the word
  *health* contains no prohibited fragment — and was caught only by the
  migration's read-back, which rolled a 724-concept import back. `refusedTopics`
  now refuses in the tool as well. **It refuses the container, not the field**:
  `subject:medicine` has been vocabulary since `0134`.
- **Two entities with one name mint neither**, the key-level form of the rule
  the resolver already applies to ambiguous labels. **A duplicate is not an
  ambiguity**, though: an entity satisfying two slices is claimed by the more
  specific one and reported, or the first run silently loses both — which is how
  League of Legends became a sport and a work and then neither.
- **A merge list is authored and stays short.** Six proposals named something
  already held under another name (`association football` → `activity:soccer`);
  minting them would split one interest across two concepts with the evidence
  for each never reaching the other.
- **Every imported concept must reach a hub** — asserted through
  `concept_block`, which is what Memories calls. A floating concept lands under
  "Other" and one parented to a guess is a false claim.
- **Vocabulary is still not the binding constraint.** `0198`/`0199` added 779
  concepts across five domains; over both live accounts they drew **6
  observation mappings and no assertions**. That is the expected shape, not a
  failure: these libraries are music. Breadth makes an interest *nameable* and
  manufactures no evidence for it.

### An activity can be watched or done, and the predicate is where that lives

**Two concepts per sport is the wrong repair**: it splits the evidence and still
cannot say which was meant, because **the evidence decides, not the concept**. So
one concept accumulates everything and the *claim about it* names the
engagement — `0200`, scorer `0.15.0`:

    participates_in_activity   any evidence marked participation
    follows_activity           any marked spectating, none participation
    affinity_to                evidence that says neither

- **The obvious predicates could not be used.** `completed_activity`, `watched`,
  `attended_activity_at` and `booked_activity_at` are `observed_action` with
  `assertion_safe = false` — what somebody did is evidence, not a claim about
  them — and `guard_user_assertion_relation_class` refuses both properties.
  *"Asserting it took the whole worker down once."* `likes_activity` is
  `user_claim` and also refused, deliberately. The two new ones are `user_claim`,
  `assertion_safe`, **zero inference hops** like `affinity_to`, or playing
  five-a-side would become participating in sport by arithmetic.
- **Which evidence means which lives in
  `semantic_private.sources.engagement_modes`**, beside `action_weights` where
  the next reader looks — never a list in `score.py`. Marked today: HealthKit
  `workout`/`routine` as participation, YouTube `subscription`/`liked_video`/
  `watched`/`video`/`liked`/`shared` as spectating. **Most sources are
  deliberately unmarked and a migration assertion refuses a state where they are
  not** — a saved track is neither, and booking a yoga class and booking a ticket
  to a match are the same act on the same source, so calendars cannot be told
  apart at the level of the action.
- **Participation outranks spectating**, being a positive fact watching does not
  contradict. **Only `concept_kind = 'activity'`** is asked the question, less
  `travel:*`, which `assert_travel` writes outside the concept loop.
- **A concept whose predicate changes is a new assertion row, and both records of
  a person's answer are keyed on what just changed** — `assertion_preferences` on
  the assertion id, `user_suppressions` on the predicate. Unhandled, a re-score
  puts a suppressed term back on somebody's page. `carry_user_decisions` copies
  and never invents.
- **Every demotion statement names every assertable predicate.** They took one
  while `affinity_to` was all the scorer wrote; left that way, an engagement
  claim would have been unwithdrawable.
- **It ships ahead of its data and the measurement says so**: zero mappings onto
  any activity concept, zero HealthKit observations in the vault, and
  `healthkit.workout` weighted **0.0** — raising that is a separate decision.
  Both branches are exercised in `test_engagement_predicate.py` instead, because
  a rule that has only ever answered one way is not one to believe. `0198`
  records each concept's slice and source id in `metadata` for the same reason.
- **The app draws it or it is half-built.** `Assertion.engagement` renders
  *Does* / *Follows* beside the term and `nil` for `affinity_to`, which is every
  row today.

### Which sources may feed a model, and who may say so

**Four may, two may not, and consent does not move the line.** Apple Music, Apple
Podcasts, Apple Calendar and HealthKit carry no term restricting downstream use.
**YouTube and Spotify both forbid it** — III.E.4.h and IV.2.1.a. **A person can
grant rights over their own data and not over a platform's**: IV.2.5 covers
derived and aggregate data *"even if a user consents"*.

Training data comes from collaborators rather than users. **`private.collaborators`
is how the two are told apart** — a table in the schema nothing is granted on,
filled in by hand, because a column on `public.users` would have been settable by
the account it describes. The query, source exclusions included, is at the foot
of that migration.

**The development team has consented to their data being used for training, and
that consent comes with a standing requirement: nobody re-distils for us.**
(Owner, 2026-08-14.) Everything they have given must be stored, retained and
re-usable for training and testing at any time, without asking them for a tap.
Two things follow and both are rules rather than aspirations:

- **A change that needs data re-projected is our problem to solve server-side.**
  Four changes in two days were paid for by asking somebody to open the app —
  `title_works`, `place_key` three times over, and Spotify's `top_track` weight.
  Each cost a person's afternoon and one of them silently did not work for a
  week, because a build gate nobody could see meant the tap did nothing. Design
  the re-projection to run from stored data, and treat "ask them to distil
  again" as a bug report about us.
- **Losing a distillation is losing a person's afternoon.** Deleting or expiring
  anything a collaborator has given needs a reason that outranks that, which
  today only the retention obligations do.

**Consent does not move the licensing line, and this is where the two meet.**
`AppConfig.semanticIngestionSources` currently carries `spotify`, so Spotify
Content is reaching the vault — enabled deliberately for the data-collection
prototype and marked as the line to delete before launch. IV.2.1.a forbids
ingesting it into a model and IV.2.5 says a user's consent does not cure that, so
**a collaborator's agreement makes their Apple Music, Podcasts, Calendar and
HealthKit available for training and cannot make their Spotify or YouTube
available.** Storing it for inspection and excluding it from a corpus are
different acts; the corpus query at the foot of `0041` is where that exclusion
lives, and it is the thing to check before any training set is built.

**Never filter on a `data_type` no distiller emits.** `Ontology.subjects`
filtered `"song"` while the distiller writes `library_song`, `heavy_rotation`,
`playlist_item` and `recently_played`, so it answered `[]` for every real library
and `top_subjects` was empty; the preview fixture had the same disease in
reverse. It reads `MusicHighlights.songTypes` and `deduplicatedSongs` now, both
internal precisely so there is one list rather than two that drift.

**Photo captions degrade subject → domain → nothing.** When the fallback runs out
the photograph carries no caption, because a commonality that does not exist is
the one thing this feature must not manufacture. Each line is used once. The bio
is **capped at 30 characters at the keyboard**, not on save.

### The icebreaker

`0036` fills six columns on `conversations` at match time — a shared `theme`, its
kind, a subject per side and a pronoun per side — and the app draws one sentence
at the top of the thread.

- **The first specific is the reader's own and the second is the partner's**, so
  the sentence differs per reader and the version shown to one must never be
  shown to the other. That rules out a `messages` row twice: `sender_id` is
  `not null`, and one row is read by both participants.
- **The flip happens once**, in `ChatService.conversation(from:me:)`, the only
  place that already knows which side the reader is. Anything downstream deciding
  for itself whether `subject_a` is "mine" is a second copy of that decision.
- **Ingredients in SQL, language in Swift.** The trigger does set intersection
  and knows no English. Copy that needs a migration to change will not get
  changed.
- **Drawn as `DayDivider`'s pill, prefixed `Tips:`** — a day pill is the one
  thing already in a thread that is *about* the conversation rather than part of
  it. **It must never read as a bubble.**
- **The trigger must read the base tables, never `summary_distilled_records`** —
  those views are `security_invoker = on`, so a `security definer` function
  reading one is *still* filtered by the invoker's RLS: it would find the
  caller's rows, silently none of the partner's, and never error.
- **`source <> 'youtube'` is explicit and must stay** — an icebreaker derived
  from YouTube data is derived data under III.E.4.h.
- **`before insert`**, since it fills columns on the row being written. **It
  never recomputes**; stale after more distilling, which is accepted.
- **No overlap means no card**, not a generic one. **Both pronouns sit on a row
  both participants read, deliberately** — gender stays off `discovery_cards`,
  and this is the narrow channel instead. Anything unrecognised is **them**,
  including null, and a name is never used to guess.
- **It is not an embedding** — overlap counting over genres, sports and creators,
  and what the ontology stage replaces.

### The invitation becomes the first message

A trigger on `conversations` insert copies the like's note in as a message from
the liker, stamped with the *like's* `created_at`.

**A trigger rather than app code, and that is forced**: the conversation is
created by the accepter, the message must come from the liker, and `messages` has
an insert policy of `auth.uid() = sender_id`. The only client positioned to write
the row is the one person forbidden from writing it.

**It notifies nobody, tested by timestamp rather than a flag** — a message
carrying the like's time necessarily predates a conversation that exists only
because the like was accepted.

### An attachment with no caption

`0010` relaxed the body constraint so a photo could travel without words, and the
app satisfies `not null` with an empty string — which produced the sender's name
and **a blank line**. It says `📷 Photo` / `📹 Video` / `🎤 Voice message` now, and
a caption still wins.

**Emoji rather than SF Symbols, and that is the medium** — an APNs alert body is
plain text rendered by SpringBoard. The chat list uses `camera.fill` /
`video.fill` / `mic.fill`; watch that its branch tests every case, since one that
tested only `audio` made an uncaptioned video call itself "Photo".

### Unread, which nothing had ever counted

**The icon badge is set from two ends and needs both** — the count travels with
every message notification, which keeps it right while the app is closed (the
only time anybody looks at it), and the app recomputes on opening Chat, on
opening a thread and on each poll. **A null badge means *leave the number
alone***, which is what a like and a match send; a 0 would wipe a badge correctly
showing one.

**One request answers both the icon and the rows.** `unreadByConversation()`
needs no conversation filter — `messages` is readable only to participants, so a
bare query for unread rows you did not send returns exactly yours. **RLS is doing
the join.**

**The band in a thread is snapshotted before anything is marked read**, since
opening a thread marks everything read, and **it is read off the fetch, never off
`messages`**, which is seeded from a cache where a missing `readAt` decodes as
unread.

**Opening position is decided by scrolling to the end and asking whether the band
survived** — no height arithmetic, and no guessing from a count one photograph
would falsify. A band `LazyVStack` never built reports nothing, which *is* the
answer.

**Taps route.** `NotificationRouter` records the destination rather than acting
on it, because a tap that launches the app is delivered before `AppShell` exists.

### Offline: the cache existed, and the failure erased it

**A failed fetch must never be mistaken for a successful empty one.** The chat
list drew from cache and then the fetch that followed **wrote its empty answer
back**. `guard let me = await currentUserID() else { return [] }` is what fires
offline, and the guard against exactly this tested `lastError`, which that return
path never set. **The fix is the type, not another boolean** — return an optional,
nil for *could not ask*, so the caller is `if let`.

Three rules follow, all about not asserting what was never asked: **`hasLoaded`
moves only on a real answer**; **the empty state has two sentences**, since "No
conversations yet" is a claim about an account that an offline app cannot make;
and **no second banner while offline**, since `AppShell`'s covers every tab and
the service's own message there is nonsense to somebody on a train.

**Nothing about synchronisation changed**: the server is still the source of
truth and the cache is still replaced wholesale by every *successful* fetch.

## Photos

`PhotoService` uploads to a private `profile-photos` bucket at
`<user_id>/<position>.<ext>`. **The position *is* the order somebody meant**, so
re-picking slot 2 overwrites slot 2, and `slots()` keeps the position `paths()`
throws away — packing 0, 2, 5 into 0, 1, 2 silently rearranges a profile its
owner laid out.

**Nothing uploads on edit; edits are staged and flushed on the way out.** Which
surface passes `PhotoGrid`'s `onEdit` is the whole difference between the two
callers: onboarding waits for Continue, because somebody arranging pictures may
yet skip; the dashboard has no button, so the departure is the button. The
staging map is keyed by position, so the last write to a slot wins.

- **`.inactive` is what catches a force-quit**, not `.background`. A background
  assertion must wrap **the work, not the call**, and its expiration handler is
  not optional.
- **The queue survives the app** (`PendingPhotoStore`, one directory per account
  through `AccountScope`, because a queue flushed into the wrong account uploads
  somebody else's face). **The intent is the file name, not a manifest** —
  `3.jpg` is a pending upload, `3.removed` a pending removal, and a directory
  listing cannot disagree with itself.
- **Encoded at staging, not at send**, so a retry after a crash sends the same
  bytes — hence awaiting outstanding staging tasks before deciding there is
  nothing to do.
- **The flush is driven by staged edits and never by the array's contents.** A
  grid that has not hydrated is six empty slots, and anything reconciling the
  array against the server reads that as *delete everything*.
- **Removal is two writes, object first** — a row pointing at a missing file
  draws a broken picture, a file with no row is merely unreferenced. **Saving is
  two writes as well, and both must be checked**: an object whose row failed
  leaves `paths()` answering "no photographs", which makes `publish` decline by
  design, so that person has **no discovery card at all, permanently, with no
  error anywhere.**
- The card is republished after any change, since it carries the paths.

**One photograph is enough, and nought is not** — `publish` refuses on an empty
`photoPaths`.

**The six boxes take photographs only, and that is a deliberate stop.**
`matching: .images` filters inside Apple's picker process, so videos are absent
rather than shown and refused — the encoder would upload a video as picked,
failing at the bucket's 15 MB door after the person had waited. Restoring it is
`.any(of: [.images, .videos])`, the encoder's commented branch, the MIME types,
the `kind` column's `video` option and the `AVAssetExportSession` that was the
actual missing piece. The view's five video branches stay in place and marked
dormant, and `load` branches on what the item *is*, so the safety does not rest
on the picker's filter. **Chat attachments still take video** — `chat-media`,
50 MB.

**Some things can be set but never changed** — the shape of bug to watch for on
the next field. A value captured once during onboarding, on a screen nobody
returns to, is a value with a typo in it forever.

## Credentials

**Never commit `sb_secret_…`.** It is the successor to `service_role` and is
subject to no row-level security whatsoever. `tools/seed_synthetic.py` and
`tools/chat_e2e.py` need one; both read `SUPABASE_SECRET_KEY` from the
environment with no default, and that is the pattern for anything like it.

**Four keys have been exposed and every one went the same way: a chat transcript,
never the repo** — checked rather than assumed, `git log --all -S` found none of
them in any commit. The July pair were still live when checked eight months
later, which is the argument for rotating at the time.

**Rotate, then verify the old key is dead with a request** rather than trusting
the dashboard. The project runs on JWT signing keys, so the legacy secret is
verification-only and there is no rotate button: what kills an exposed
`service_role`/`anon` JWT is **disabling the legacy API keys**.

**Nothing that ships is ever affected**: both targets carry only
`AppConfig.supabaseAnonKey`, a `sb_publishable_…` value that is public by intent.
If rotating a secret ever *does* require a rebuild, something has been put in the
app that should not be.

## Shipping: build numbers, TestFlight and review

**Every upload needs `CURRENT_PROJECT_VERSION` bumped, once per configuration per
target, all moving together.** **Count it, never remember it**:
`grep -c CURRENT_PROJECT_VERSION project.pbxproj`. Un-embedding a target does not
reduce the count.

**Held-back features are hidden by one line and marked `ARCHIVED-`, never
deleted.** Two shapes:

- **A source** leaves `Modality.sources`; its distiller, `OAuthProvider` case,
  scopes and read paths stay compiled. Side effect: `recordSources` derives from
  `sources`, so an archived source's rows belong to no branch — harmless with no
  rows, and **`applyingBans` gates on `recordSources` too, so an archived source
  with rows silently stops honouring the ban list.**
- **A whole target** is **un-embedded**, not deleted and not `FALSEPREDICATE`'d —
  it still builds and signs and is simply not copied into the app.

**Verify in the archive, never in the build settings:**

    A="$(ls -dt ~/Library/Developer/Xcode/Archives/*/*.xcarchive | head -1)"
    ls "$A/Products/Applications/Written.app/PlugIns/"
    plutil -p "$A/Products/Applications/Written.app/Info.plist" | grep MinimumOSVersion

**An embedded extension's `IPHONEOS_DEPLOYMENT_TARGET` must not exceed the
app's** — Xcode gives a new target the *SDK* version by default, which shipped an
app whose share extension nobody below 26.5 received.

**A purpose string is demanded for the API you *could* call, not the one you do —
and the deployment target decides which key's name.** `ITMS-90683` twice:
`NSHealthUpdateUsageDescription` for an app that never writes to Health, and
`NSCalendarsUsageDescription` alongside the full-access key. **Adding a source
means adding every key its framework can reach, back to the deployment target.**

**Since 2026-04-28 a submission must be built with the iOS 26 SDK or later** —
unrelated to the deployment target, and only visible at upload. `DTSDKName` in
the archive is the check.

**"Uploaded" is four states short of "a tester has it", and the gap is silent at
every step:**

    archived -> uploaded -> processed -> in a tester group -> review-approved -> Testing

`Distributions` in `.xcarchive/Info.plist` answers "was it sent" offline, but
`success` there means only that the bytes reached Apple. **Read the TestFlight
tab for anything past the upload leg.**

**Internal testing needs no review; external TestFlight reviews the first build
per version.** The plan of record is external TestFlight before the App Store.

|  | External TestFlight | App Store |
|---|---|---|
| Review | first build per version | every version |
| What is reviewed | the app | the app **and** the listing |
| Screenshots, description, keywords | not needed | required and reviewed (2.3) |
| Age rating | not required | required |
| App Privacy details | not documented as required | required |
| Audience | 10,000 invited testers | public |
| Build life | **90 days** | indefinite |

A large share of launch rejections are metadata ones under 2.3 that TestFlight
never looks at. But **Guideline 2.2 puts TestFlight builds under the same
Guidelines**, so the demo account, UGC moderation, the privacy policy and a
working contact address all still bind.

**The unattended upload does not work on this machine; uploading does.**
`xcodebuild -exportArchive` has no distribution identity to use. Either Organizer
→ Distribute App → **App Store Connect** — **not "TestFlight Internal Only"**,
directly above it and a one-way door that stamps the build undistributable,
escapable only with a higher build number — or an **App Store Connect API key**
(role App Manager, `AuthKey_<KEYID>.p8` in `~/.appstoreconnect/private_keys/`).
The `.p8` downloads **once** and is a credential; treat it like `sb_secret_…`.

### The reviewer cannot create an account without help

Sign-up is phone-only and verified by SMS, with Twilio geo permissions allowing
Hong Kong, Taiwan and the US only. Apple and Google cannot rescue it — they
refuse any identity that is not already linked, and **Apple can never be a demo
route for any app**, since `ASAuthorization` signs in whoever the device is
signed into.

**The answer is a test phone number** — Supabase maps a number to a fixed OTP
(`SMS_TEST_OTP`, bounded by `SMS_TEST_OTP_VALID_UNTIL`) and sends no SMS,
sidestepping the geo restriction, the Twilio cost and Google's 2FA at once, while
exercising the real sign-up path rather than a bypass. Credentials live in App
Store Connect → App Review Information and nowhere else. **Remove the number
after approval**, or let the expiry do it.

Two silent ways to get it wrong: **the username must be the ten *national*
digits** (a pasted `1XXXXXXXXXX` is truncated to ten, still validates, and sends
the code to a number nobody holds), and **the Notes field is not optional here** —
a reviewer who taps "Sign in with Apple" is refused with no way to know that
*Create account* is the only door.

**Do not build a demo mode that hides restored data until a Connect tap** — it
makes Connect report data that did not come from the device, for one account
only, which is 2.3.1(a), and 2.1 permits a built-in demo mode only *"with prior
Apple approval"*.

## Known gaps

Open as of 2026-08-13, ordered by what hurts soonest. **Delete an entry when it
stops being true.**

- **A restore has never been run on a device that didn't already have the data.**
  `RestoreService` checks out on inspection, which is an argument, not a test.
  Sign in to the demo account on an erased simulator — **this is also the
  reviewer's first launch.**
- **Notifications are proven on sandbox and untested on production.** Confirm a
  `device_tokens` row reading `production`, then send one message and check the
  face still arrives.
- **Nothing enqueues a recompute when somebody answers a claim**, so a
  suppression correctly stales every inferred assertion and the Memories page
  stays blank until the worker is run by hand. The fix is one job per *user*,
  keyed on the revision and the three analysis ids, not one per tap.
- **Nothing lists a suppressed assertion**, so restoration is reachable only as
  an undo in the moment and a mis-tap is permanent. It wants a server decision —
  a second RPC or a parameter — and the question underneath is what somebody is
  owed over their own profile.
- **Exposures are recorded when an answer is given, not when a row is drawn**, so
  `assertion_exposures` cannot answer *"what was shown and not acted on"*, which
  §10 lists among the shadow metrics.
- **Connecting Google Calendar on a phone that already has the Google account
  duplicates every event, and it has happened.** The guard behaved as designed
  and its design has the hole: `hasGoogleAccountOnDevice()` returns false when
  calendar access has not been granted, and that is exactly the person being
  offered Google Calendar. Decide it after Apple Calendar is connected, or
  re-decide once access exists.
- **The assertions have been read down the strong end and not to the bottom** —
  confirmed to 0.362, the concept nearest the 0.35 bar; the middle is unread. One
  thing to check: **`genre:asian_music` is a container in all but name**, parent
  of four genres it scores alongside, and the hub rule cannot catch it because
  its kind is `genre`.
- **Whether HealthKit habit candidates are within the grant is unanswered**, and
  moot until a device records workouts.
- **App Store privacy labels are not filled in.** **The three answers that must
  agree are `PrivacyInfo.xcprivacy`, `web/en-us/privacy/` and the
  questionnaire**, and none of the three checks the others.
- **Identity linking is unbuilt** — three sign-in methods mean one person can
  hold three accounts. Decide before launch.
- **A failed record upload is recorded but undrawn** (`syncFailure`).
- **Watch `birth_date` the first time somebody completes the birthday step** —
  the age gate has never been observed reaching Postgres.
- **A declined Workouts toggle is indistinguishable from no workouts.**
  `health_sports` being empty is otherwise settled and correct. One line in the
  distiller's `Trail` would settle the rest.
- **The append/change-only path has never run from the app.** Distil Apple Music
  twice and confirm the second run writes only what moved.
- **CAPTCHA is off for phone sign-in**, with the 10/hour SMS limit standing in.

### Deferred by decision

**Google OAuth verification, deferred until the hubs exist** — submitting earlier
means shooting the demo video against a pipeline about to be replaced, and the
same form carries the derived-metrics request. **Nothing about that defers the
policies themselves.** Two traps: Search Console must be verified as a **Domain**
property signed in as an Owner of the Cloud project (verifying as the wrong
account is the standard rejection and Google does not say so), and the consent
screen must carry the two URLs **character for character**, matching
`SignInView.swift` — not `/privacy`, which 301s, and a redirect is not agreement.

**The Disconnect control has never been exercised against a real Google
account**, and the published privacy policy makes a 7-day claim resting on it.
That has to happen before YouTube comes back.

### Standing traps, not gaps

**The site is written from the app and goes stale silently** — a page cannot fail
to compile. **Adding a source, a sign-in method, or anything else that leaves the
device means editing `web/en-us/privacy/` in the same commit.** The worst form
this has taken: four pages saying in six places that Written "no longer connects
to a YouTube account" while YouTube was live with 731 rows. The scope table is
what Google's verification form points at, so a missing scope is the one omission
it cannot afford.

**Verify a site deploy by diffing a live page against the repo file**, not by
reading wrangler's success line. A `wrangler.jsonc` naming the wrong Worker
publishes successfully to a Worker nothing points at, while the apex serves the
old copy **with our own `_headers` CSP on it** and `cf-cache-status` says `HIT`
even for a cache-busting query. `GET /accounts/{id}/workers/domains` is what
settles which Worker owns the domain.

Two words the site uses precisely: **struck off** is the `BanList` pass, where
`markedRemoved` annotates `extra` and *keeps the row* — never used, never shown,
never counted, and not deleted. **Deleted** is account deletion, the YouTube
sweep and `deleteSource(_:)`. Deletion is immediate, so the 7-day clause is a
ceiling kept for backups.

**One network sinkholes `written-stl.com`** — on `wusm-wifi.wucon.wustl.edu` it
resolves to `sinkhole.paloaltonetworks.com`. **Do not diagnose a deployment from
a sinkholed resolver**; resolve over DoH and pin the answer:

    curl --resolve written-stl.com:443:104.21.7.174 https://written-stl.com/en-us/
