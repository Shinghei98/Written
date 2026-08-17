# Written — long-form project context

**This is the record; `CLAUDE.md` is the rules.** Where the two disagree,
`CLAUDE.md` controls — this file is the evidence, the measurements and the
postmortems behind each rule, kept so that a rule that looks arbitrary can be
checked rather than guessed at. Read it before removing a guard, re-litigating a
decision, or concluding a number was made up.

Older material that has since been cut from either file is in
`git log -p CLAUDE.md`; the semantic pipeline's build history is in
`semantic/JOURNAL.md`, and each migration's reasoning is in its own header
comment.

---

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

## The prime design constraint: minimum friction

Data extraction must feel like a **one-button experience** per app. OAuth is the
preferred mechanism; in-app browser login with automated download is the
fallback, to be discussed per app and never a default. When adding a source,
"how many taps and does the user type a password?" outranks how much data the
integration could theoretically reach.

| Source | Auth | Friction |
|---|---|---|
| Apple Music | MusicKit | One system permission dialog, no login at all — uses the device's Apple Music account. |
| Apple Podcasts | MusicKit (`MPMediaLibrary`) | The same dialog, already granted if Music was. |
| Apple Health | HealthKit | One system sheet listing the types read, no login. |
| Apple Calendar | EventKit | One system sheet, no login. Works in the simulator, unlike MusicKit. |
| YouTube — *archived* | Google OAuth (PKCE, `ASWebAuthenticationSession`) | Sheet shares Safari cookies → tap account, tap Allow. Refresh token in Keychain ⇒ later distills zero-tap, **but only once the app is published**: a consent screen in Testing expires every refresh token after 7 days. |
| Google Calendar — *archived* | Google OAuth, two narrow scopes | As above, and only offered where the phone has no Google account. |

Every Apple source above is one tap and no password, which is the standard the
OAuth ones are measured against rather than an accident of what was easy.

## The extraction rule: if it can be distilled, distil it

**Take whatever is technically possible, whether or not it looks useful at first
glance.** The ontology and embedding stages decide what matters, and only about
data that was kept; a field dropped at the parse cannot be recovered without
re-distilling everybody. It has cost something twice: `AppleMusicDistiller`
fetched `composerName`, `albumName`, `releaseDate` and duration and discarded
them at one line, making classical listening invisible — the "artist" of a Bach
partita is whoever performed it; and YouTube's `categoryId` sat inside a snippet
already being decoded.

Three things this rule does **not** license:

- **Asking for more permissions.** "Technically possible" means with the consent
  already given — Health's sheet lists only the types actually read.
- **Widening the list of what leaves the device.** That list is kept short and
  complete on purpose, and `PrivacyInfo.xcprivacy` has to keep agreeing with it.
- **Working out what a source already states.** *Keeping* a field and *inferring*
  one are different acts under different rules, and for YouTube the second is
  prohibited outright. Add `part=topicDetails` to reach one more field; do not
  compute a label the source would have given you for the asking.

Within one already-granted permission, take everything: extra fields on a
response already fetched, extra `part=` on a request already being made, a second
query against a library already open.

**And an absence is not a refusal.** Distil what is reachable and explain what is
missing — never stop because one route came back empty. **But do not assume the
other route saves you**: the device library is not a fallback for Apple Music.

## Supported apps and what each yields

Scope comes from `written_api.xlsx` (the source of truth for what each platform
exposes; consult it before adding a source). **`grep -rn "ARCHIVED-"` is what
actually ships** — a marker means "held back or on its way back", and only the
code around it says which.

- **YouTube** (`YouTubeDistiller`) — **live, and its `ARCHIVED-YOUTUBE` marker
  has drifted from the code.** `Modality.swift:134` says `"youtube"` was removed
  for the App Store build and `:147` returns it; same for `google_calendar` at
  `:175`. **Anything shipped from this tree offers a reviewer both sources, and
  both 403 for accounts off the Testing allowlist** — close the drift
  deliberately before any upload, in one direction or the other.

  Subscriptions, liked videos, playlists and playlist contents. Watch history is
  **not** reachable: the API does not expose it, and Takeout is EU-only.
  `channels.list` asks `topicDetails,statistics` in one call — quota is charged
  per call rather than per part, so the subscriber count is free, and it is the
  one field III.E.4 lets outlive thirty days, being a *statistic*. **It
  dual-writes to the vault and resolves.** What it may not do is infer:
  `provider_topic` and `uploader_tag` are reads and permitted,
  `written_title_tag` is a guess and is gated.

- **Apple Music** (`AppleMusicDistiller`) — library songs/albums/artists/music
  videos, playlists + contents, recently added, recently played, heavy rotation,
  recommendations, like/dislike ratings.

  **A person without an Apple Music subscription gets no music from this app at
  all.** With Sync Library off, `MPMediaQuery.songs()` went **320 to 0** while
  podcasts held at 2 — the control proving the library was still readable. Even
  the sixteen non-cloud rows were streamed tracks downloaded for offline play,
  which read as local and are not, so the cloud flag cannot tell owned music from
  downloaded. `MusicLibraryDistiller` still earns its keep for people who *own*
  music.

  **On a subscriber's phone both sources return the same library**, so every song
  was counted twice: 320 rows each, **320 title-and-artist pairs in common and
  zero ids in common**. `MusicHighlights.deduplicatedSongs` therefore collapses
  on **title and artist**, never on id. The doubling hid because it was uniform —
  shares untouched, only absolute counts wrong.

- **Spotify** — **live again for the data-collection prototype, and still removed
  before the real launch.** **Two edits turned it on and both must be reversed**:
  the string in `Modality.sources`, and `AppShell`'s
  `.task { viewModel.purgeArchivedSources() }`, now commented out — that task
  deletes Spotify rows from memory, the on-disk cache and Postgres on every
  launch, so left running with the source live it wipes each distillation moments
  after it lands. Turning it on also fixed something quietly broken:
  `applyingBans` gates artist bans on `Modality.music.recordSources`, so while
  archived a struck-off artist came back on every Spotify row.

  Why it comes out again, from the clauses rather than a summary: **IV.3.1.a is a
  limit, not a prohibition** (store, refresh, expire — the shape of `0016`) and
  **IV.2.5 permits** third-party data processors, so Postgres was never the
  problem. **IV.2.1.a is what rules it out** — no *"training a machine learning
  or AI model or otherwise ingesting Spotify Content into"* one — and **IV.2.5
  closes the consent route**: derived and aggregate data count *"even if a user
  consents"*. A collaborator can grant rights over their own data, never over
  Spotify's. And **it cannot leave development mode**: 5 users added by hand,
  extended quota organisations-only since 15 May 2025.

  **Its rows are not shaped like Apple Music's.** `top_track` — an explicit
  `rank=N`, the strongest listening signal either source returns — counted for
  nothing until it joined `MusicHighlights.songTypes`, with
  `top_artist`/`followed_artist` joining `artistTypes`. It stamps no `subject=`
  and its `creator` is **pipe-joined across every credit**, so the fallback
  produced the subject `Drake|Future|Tems`; `Ontology.musicSubject` stamps the
  first credit, which on this source can only ever be the performer. And
  `deduplicatedSongs` collapses by *group*: the Apple pair collapses, anything
  else stands alone, since reaching across to Spotify would discard single-artist
  tracks and double-count featured ones, spelling-dependently.

- **Apple Podcasts** (`PodcastDistiller`) — `MPMediaQuery.podcasts()`, one
  `MPMediaLibrary` permission, no login, same framework and
  `NSAppleMusicUsageDescription` as Apple Music. **It is the whole of the Media
  branch while YouTube is archived** (`Modality.isOffered`).

  **It returns downloaded episodes and nothing else** — cloud podcasts held at
  zero beside 304 cloud items, and following a show does not enumerate its back
  catalogue. Populated: `podcastTitle`, `title`, `artist`/`albumArtist`,
  `releaseDate`, `dateAdded`, `playbackDuration`, `bookmarkTime`, artwork,
  `assetURL`. Empty: `genre`, `playCount`, `lastPlayedDate`, `skipCount`,
  `rating`, `comments`, `composer`, `isExplicitItem`, `isCloudItem` — so there is
  **no play history**, and `bookmarkTime` is the only behavioural fact. A
  category would have to come from the iTunes Search API by show name.

  **Whether the source is worth having is unresolved, and it turns on one
  question: does Apple Podcasts auto-download episodes of followed shows?** If it
  does, the library is a rolling window over what somebody follows; if not, it
  reflects only deliberate downloads, which almost nobody does. **This ships
  unanswered.** Settle it by following a show on a device, downloading nothing,
  and looking again.

  Ruled out: MusicKit has no podcast types; iCloud sync uses Apple's private
  container; Now Playing metadata for another app is private API;
  `DeviceActivity` needs Family Controls; the privacy.apple.com export is an
  emailed ZIP; `JournalingSuggestions` is above the deployment target. What
  remains is the share extension resolving a `podcasts.apple.com` link through
  the iTunes Search API, or Spotify's `/me/shows`. `MPMediaQuery.audiobooks()` is
  **untested, not unavailable**, and reaches only the iTunes-era leftover.

- **Apple Calendar** (`CalendarDistiller`) — **the first source not in
  `written_api.xlsx`.** It reaches two things nothing else does: bookings that
  ticketing sites write in themselves (a far stronger claim than a followed
  artist — it cost money and a Saturday), and what people type for themselves.
  `url` and `organizer` are kept because they are what tells the two apart — see
  `booked=1` in `extra`.

  **Events are stored whole and synced**, unlike HealthKit, because the titles
  *are* the signal — a deliberate trade that puts other people's names and
  locations in the database, and `PrivacyInfo.xcprivacy` says so. **Windows are
  five years either side** (`AppConfig.calendarLookbackDays` /
  `calendarLookaheadDays`, capped by `maxCalendarEvents`), because a ticket
  bought today for November only exists ahead of now. Repeating entries keep one
  occurrence per identifier, marked `recurring=1`.

  Three traps, each paid for: **`predicateForEvents` silently returns nothing
  across more than four years**, so the fetch is chunked by year (one ten-year
  predicate returns an empty list and no error); **the chunks are walked outward
  from today**, or a decade of standing meetings fills the cap in 2021 and loses
  the booked trip ahead; and **on iOS 17+ the old `requestAccess(to:)` grants
  *write-only***, which looks exactly like an empty calendar —
  `requestFullAccessToEvents` is required, with the legacy
  `NSCalendarsUsageDescription` still needed alongside the modern key because the
  app deploys to 16.0.

  **Three exclusions, three mechanisms because no one of them can reach the
  others.** `CalendarDistiller.isGenerated` tests the calendar's *type* first and
  its *name* last, because holidays arriving through Google or Exchange are
  `caldav` and indistinguishable by type from a real diary, and the name list
  (English plus 节假日 / 節假日) **will always be incomplete**. `PublicHolidays`
  catches what Google copies into somebody's *primary* calendar as ordinary
  events — 49 of 77 surviving events on a real device, every one all-day,
  unrecurring, unorganised and unbooked, character for character what a real
  entry looks like — matched **by token, not whole name**. Titles carrying
  `birthday` or `meeting` are **not drawn**, a *reading* decision: every such row
  is still collected, synced and sent on.

  **A row with no `cal_type` is not drawn.** The distiller stamps it now and
  `append_source_records` treats a re-stamped row as a change, so one re-distill
  returns every event the person still has, typed. **The card lists the events
  themselves**, one row per distinct title, **ranked by what made the entry
  rather than by when it happens** — date order is why a flight to Los Angeles
  sat 59th of 77 behind five years of dentist appointments.
  `ListeningHighlights.shape` is kept and drawn by nothing.

- **Google Calendar** (`GoogleCalendarDistiller`) — **its `ARCHIVED-` marker has
  drifted exactly as YouTube's did**: `Modality.swift:175` returns it, with 7
  rows and 1 connection. The reason for archiving stands — the consent screen is
  in Testing, so a reviewer gets a 403 *after* a successful login.

  Its condition is the whole design: **offered only where the phone has no Google
  account.** One added in iOS Settings delivers its events through EventKit as
  `caldav`, so collecting them again puts every dinner in the database twice
  under a different `item_id` and `source` — which `append_source_records`
  dedupes *within* a source and cannot catch. `hasGoogleAccountOnDevice()` tests
  the `EKSource`, not calendar names, and both `SourceAvailability` and
  `DistillViewModel` guard it, because a hidden row is a drawing and not a rule.
  Two narrow scopes rather than `calendar.readonly`; birthdays go by Google's own
  `eventType`. Nothing downstream knows it exists.

- **Outlook Calendar** (`OutlookCalendarDistiller`) — Microsoft Graph `v1.0`,
  same PKCE machinery as every other OAuth source (an `OAuthProvider` case, not a
  second auth service, and deliberately not MSAL). The `common` authority, so
  personal and tenant accounts both sign in.

  **`Calendars.ReadBasic` is not available to personal Microsoft accounts**, and
  the failure is silent: consent is approved, a token is issued carrying no
  calendar permission, and Graph answers **401 with no body and no
  `WWW-Authenticate` header**, naming no scope. Four wrong diagnoses; reading the
  permissions reference is what found it. A personal-account Graph token is an
  opaque **compact token** beginning `EwA`, not a JWT, so its shape is not
  evidence of a problem.

  **So the grant is `Calendars.Read`, wider than what is read** — `$select` names
  twelve fields and never `body`, `bodyPreview`, `attendees`, `attachments`,
  `onlineMeeting` or `webLink`, minimisation our code performs rather than one
  the permission enforces. Still not `.ReadWrite`.

  **Its audience is narrower than it looks**: an account added in iOS Settings
  arrives through EventKit as `EKSourceType.exchange` and `CalendarDistiller`
  already collects it, and a tenant that disables user consent (WashU does)
  refuses Graph outright while remaining reachable through EventKit. What is left
  is the person who uses the Outlook app and never added the account to
  their phone. **It stamps no `booked=1`** — that needs an organiser and a
  ticketing url and the `$select` asks for neither, so its events map to
  `scheduled` alone; adding `organizer` is now possible and has not been done,
  since widening what is read is a decision rather than a consequence.

  **Its rows overlap Apple Calendar's**, and it is offered anyway — harmonising
  several calendars is the product — deduped where it is *shown*, by title and
  start, in `ListeningHighlights.personalEvents`. **That set is derived from
  `Modality.plans.recordSources`** rather than written out: it decides both which
  rows reach the Events card *and* which rows dedupe against each other. **A
  tenant can refuse after a successful sign-in**, which arrives as a 403 and is
  said in words (`CalendarError.tenantRefused`). **The row is absent, not
  disabled, until `AppConfig.microsoftClientID` is real**
  (`isMicrosoftConfigured`). **It is on the legacy `distilled_records` path
  only**, deliberately absent from `AppConfig.semanticIngestionSources` until
  exercised against a real tenant.

- **Google Health is not possible on iOS, settled rather than deferred.** Fit
  REST stopped accepting signups on 2024-05-01 and dies end of 2026; Health
  Connect is Android-only; Google's own guidance sends iOS developers to
  HealthKit. `fitness.*` was **restricted**, so even when it existed it meant a
  CASA assessment.

- **Apple Health** (`HealthKitDistiller`) — five `data_type`s: `age` (1),
  `biological_sex` (1), `workout` (0–300 a year), `activity_day` (≤365) and
  `activity_hour`, **24 rows for the whole window rather than 8,760**, because
  the question is which hours somebody is active in.
  `DistillViewModel.healthKeptTypes` lists all five and is kept as a list
  precisely because it now excludes nothing — it is the gate a *new* HealthKit
  type has to pass. Two windows (`healthWorkoutLookbackDays`,
  `healthActivityLookbackDays`, both a year) kept apart because workouts are
  sparse and quantity samples dense; the activity window is the dial to turn if a
  distillation is genuinely slow. Note it was turned once already, wrongly: the
  hang was the *authorization request* never returning, with no query run.

  **Only the types actually read are requested.** HealthKit authorizes per type,
  and *reading* a type never requested is what makes it answer
  `errorAuthorizationNotDetermined`. **A declined read looks exactly like no
  data**, so an empty distill is surfaced as a failure rather than silently
  growing a branch.

### A calendar missing from the private-source list is permitted, not unhandled

**Six `semantic_private` functions decide how a calendar observation is treated,
and five named `apple_calendar` and `google_calendar` as a literal `in (...)`
list.** Four are *prohibitions*: `guard_calendar_observation_mapping` (no generic
mapping lane), `guard_private_source_generic_lane_v03` (no mention or feedback
lane), `guard_calendar_assertion_evidence` (calendar evidence may not sit under a
public surface grant) and `private_observation_projection_is_valid_v03` (the
sanitised shape, which is what stops a title being transcribed).

So registering `outlook_calendar` in `semantic_private.sources` and stopping
there would not have left it *unhandled* — it would have left it **permitted**,
with nothing anywhere reporting the difference. **The failure mode of a deny-list
is silence.** `0133` replaces all five literals with
`semantic_private.is_private_calendar_source` and `is_private_lane_source`, and
asserts **no function outside those two still names a calendar by literal**, so a
sixth written later fails the next replay rather than shipping a hole.

- **Pure literal arrays, not table lookups.**
  `private_observation_projection_is_valid_v03` is `immutable` and backs a check
  constraint on `observations`; a helper reading `sources` could not be immutable,
  and making the projection `stable` would mean dropping and re-adding that
  constraint, re-validating every stored row. A table would also let a row in
  `sources` quietly change what is enforced.
- **The projection is proved by calling it, both ways** — an Outlook payload
  carrying an event title refused, a sanitised one accepted, Apple's answer
  unchanged. `0117` read an empty table, answered false for everything, and
  passed its own structural assertion; a predicate is not believed here until it
  has been seen answering both ways.

`outlook_calendar` shares the `calendar` independence group with the other two,
which is a decision rather than bookkeeping: two calendars agreeing is often one
diary reached twice, and `minimum_independence_groups >= 2` would otherwise be
satisfiable by a duplicate.

### HealthKit's permission sheet, which is not HealthKit's

It asks SpringBoard to launch `com.apple.HealthPrivacyService` and hosts a remote
view from it, so if anything else owns the screen or that process is cold it
gives up rather than reporting a refusal. Five rules, each paid for:

- **No other permission alert near this one** — anything asked for on
  `.task`/`.onAppear` is gated on that tab's `isVisible`, since `AppShell` mounts
  every tab.
- **One retry is not optional**: a cold start can use all of the ten seconds
  HealthKit allows its host. An error from `requestAuthorization` is always
  infrastructural, since a denied read is reported as success with no data.
- **`stageTimedOut` is the only terminal error.** `stage` wraps every underlying
  error as `stageFailed`, so a retry guard refusing `stageFailed` refuses the one
  error it exists for.
- **`authorizeTimeout` is 180s; `stageTimeout` stays 20** — the callback does not
  fire until the user *answers the sheet*.
- **Ask nothing of HealthKit while a sheet of ours is dismissing.**
  `waitUntilActive` cannot see it (`applicationState` stays `.active`), so
  `.sheet(item:onDismiss:)` starts the work instead of a guessed delay.

**Its Allow button is disabled until a category is switched on**, which reads as
a frozen app, so the Health row alone carries a second line warning of it and
`SourcePickerSheet.privacyNotice` sits under the rows rather than inside one.
**It only happens to people who have never been asked, so testing Health on your
own phone proves nothing** — reset with `xcrun simctl erase`, or Settings →
General → Transfer or Reset → Reset Location & Privacy.

Three lessons from the same hunt, none about the sheet. **A failure has to be
drawn against the branch that was attempted** — `GrowProfileView`'s prompt card
asked `nextModality`, so a source connected out of sequence drew "Ready to grow?"
over a real error. **A `withThrowingTaskGroup` cannot impose a timeout on a call
that never returns**: the group awaits every child, `cancelAll()` only sets a
flag, and a task suspended in `withCheckedThrowingContinuation` never observes it
— surviving a continuation nobody will resume needs an unstructured task that is
deliberately abandoned. And **a Release build may say what failed** —
`BuildKind.isBeta` prints the diagnostic in Debug and TestFlight only, because
`stageFailed` and `stageTimedOut` rendered identically with the detail behind
`#if DEBUG`. The detail is the whole run rather than its last line.

### Where each source can be tested

**YouTube works in the simulator.** **Apple Music requires a physical iPhone**
signed into Apple Music, plus a paid developer team and MusicKit enabled on the
App ID — MusicKit mints its developer token from the signing identity, so
ad-hoc-signed simulator builds fail with "Failed to request developer token".
**Calendar works in the simulator**; **HealthKit's sheet and API do too**, but
its database starts empty, so add samples in the simulator's Health app or every
distill comes back empty.

On device HealthKit needs the entitlement to survive packaging, and it silently
may not: with no `DEVELOPMENT_TEAM` set Xcode strips it (the built `.xcent` is
empty), and **`CODE_SIGNING_ALLOWED=NO` does the same to a simulator build**.
HealthKit reports the result as `Missing com.apple.developer.healthkit
entitlement` in `log show` and as an ordinary authorization failure on screen.
`xcodebuild test` signs correctly; building with that flag and hand-installing
from DerivedData does not.

## YouTube: the policy position, for when it comes back

**Read the clauses, never a summary of them** — three confident readings from
summarised fetches have all been wrong. One clause here governs every source.

**III.E.3.b — Authorized Data goes to nobody but its owner**, and *this one is
not about YouTube*: *"must not display or allow access to Authorized Data to
anyone other than the authorizing user."* `publishDiscoveryCard` was appending
every ranked YouTube channel to `discovery_cards`, the one table every signed-in
user may read. **The two-part test for anything added to that card is "is it
something a sentence can be about" *and* "do the source's terms allow a stranger
to see it".** Nothing in the schema asks the second.

**III.E.4.h — the derived-data prohibition, and why `Ontology.classify` is not
called on YouTube data.** *"Must not… access or use API Data to create new or
derived data or metrics"*, whose don't-list includes *"infer or estimate the
content category/type of a video or channel"*. The remedy is its heading:
***"Only offer metrics that are available via YouTube's API services"*** — the
category is read rather than guessed.
`Ontology.domain(youTubeTopics:creatorTags:categoryID:)` maps YouTube's own
vocabulary onto ours, most specific first:

- `topicDetails.topicCategories`, last path component. Liked videos carry these;
  **subscriptions do not**, so `channelTopics` makes a second `channels.list`.
- `snippet.tags`, **matched whole and lowercased against a small controlled
  vocabulary, never as substrings.** Recognising `physics` is translation;
  matching `phys` inside a title is a guess wearing the same clothes.
- `snippet.categoryId`, the numeric fallback.

**`refusedTopics` drops Religion, Politics, Health, Military and Society whatever
YouTube says**, and categories 25 and 29 are absent from the id table for the
same reason: a content tag is how a protected characteristic arrives without
anybody deciding to collect it. **Check the source before calling `classify`** —
the restriction is YouTube's alone, and the music line goes through
`musicLine(for:)` and Apple Music's own genres.

**Retention: 30 days, and `0016`'s daily `pg_cron` sweep is still running.**
III.E.4 permits storing beyond 30 calendar days only Analytics data, Reporting
data and *statistics*. Three stores hold YouTube strings: `distilled_records`,
`discovery_cards.interests` (swept by `0032`, no longer written), and
`shared_posts`, deliberately *not* swept because that video id came from a public
URL somebody pasted rather than an authorised API call.

**`0016`'s premise was settled by the owner on 2026-08-13: a channel name that
has become ontology vocabulary is not API Data.** It is a concept keyed to no
user — `creator:onion_man` is no more YouTube data than `creator:le_sserafim` is
Apple Music data — so `ontology.youtube_channels.canonical_title` (298 titles)
and the `creator:*` labels `0143` minted from them are deliberately unswept.
Three things it does **not** license:

- **The three sweeps stay.** `distilled_records`, `discovery_cards.interests` and
  `raw_source_records` hold titles as *user data* and are all swept daily
  (`youtube-retention` 03:17, `youtube-vault-retention` 03:27). The determination
  is about vocabulary, not about evidence.
- **It does not put titles back in the projection.** A title in
  `observations.normalized_payload` is *unremovable*: `guard_observation_immutable`
  freezes the payload and `ingestion_run_items` references observations
  `on delete no action`, append-only. `~/.claude/plans/melodic-inventing-ritchie.md`
  proposed a deleting sweep on the premise that no trigger fires on delete — true
  of triggers, false of foreign keys, proved when `0139`'s first draft tried it.
  **That plan cannot be executed as written.**
- **It does not make deriving a title into a term unnecessary.** The pattern that
  works is read-derive-discard, from the catalogue rather than stored evidence.
  `subject:bioinformatics` from `Bioinformagician` is a real derivation, additive
  and distinct under the amendment's §3; `creator:onion_man` from `Onion Man` is
  the identity function, which is why it needed the determination.

**Revocation.** Revoked at Google, everything read must be gone within 30 days,
which the sweep satisfies for free. Revoked in-app it is **7 days**, and a
deletion *request* is 7 — the case the sweep cannot cover. One control is built,
for people who have connected YouTube: **Disconnect all**, which revokes.
`DistillViewModel.deleteYouTube(revoking:)` takes the server first and the local
copy only if the server agreed. **`disconnect()` is not revocation** — it deletes
our copy of the token while the grant carries on existing. `revoke()` POSTs the
*refresh* token (an access token would revoke only itself) and treats **400 as
success**; its local half runs regardless, since the token needed to retry is
what is being thrown away.

**Bringing it back needs three things, each weeks rather than days.** Extended
quota — a worst-case distill is ~185 units against 10,000/day, and requesting it
triggers an audit. OAuth verification — the consent screen is in Testing, which
allowlists 100 users and expires refresh tokens after 7 days, and publishing
needs a Search Console **Domain** property, a scope justification and a demo
video. And, for the ontology stage, Google's **Content Categorization and
Tagging** amendment (`developers.google.com/youtube/terms/derived-metrics-policy`),
applied for on the same form — so do not apply while running the unlicensed
version of the thing being applied for.

**That amendment does license real derivation, and the line is *where the label
attaches*.** Three levels, only the middle turning on the amendment:

- **Read YouTube's own labels onto our vocabulary** — permitted today, already
  built (`Ontology.domain(youTubeTopics:creatorTags:categoryID:)`).
- **Assign our own sub-genres to videos and channels** — what §3 licenses
  (*"additive and distinct from YouTube's video categories"*, worked example
  `Speedrun` on a Gaming video). That is exactly `written_title_tag` and what
  `allow_title_tags` gates, and it is a genuine gain: licensed, the many untagged
  channels stop being unplaced.
- **Aggregate those into a claim about the viewer** — **absent.** All six
  categories concern channels and videos; the only sentence naming users is the
  protected-attributes restriction. So this stays inside III.E.4.h with no
  carve-out reaching it, and acceptance would not grant a viewer-level claim.

Two conditions sit around it. **There is a use-case gate and how it reads is
arguable**: *"Your API Service must reflect an analytics use case on YouTube"*,
with "analytics use case" nowhere defined — Memories, grouping somebody's own
channels under YouTube's own topic labels on their own page, is a defensible
analytics surface. The call is Google's at review; do not pre-refuse it and do
not assume it. And **the storage relief excludes what this product wants**:
statistics and derived metrics may be kept 36 months, but *"other data (such as
video titles, creator names, descriptions…)"* still follows the 30-day policy, so
`0016`'s sweep survives acceptance untouched.

**Which is why Memories is fine and the discovery card is not**, and the
amendment covers III.E.4.b/c/d only — **III.E.3.b is not in scope**, so showing
one user's YouTube-derived channels to another stays prohibited whatever is
accepted. §4 forbids profiling users on *"age, race, religious affiliation,
political leaning, sexual orientation, or health status"*, which is
`refusedTopics` and the absent categories, written before this page was read.

`youtube.readonly` is *sensitive*, not *restricted*, so no CASA assessment.
Whatever happens, the YouTube contribution must be **separable and reversible**
and **must not become load-bearing**. **The day the ontology layer is enabled for
YouTube, `web/en-us/privacy/` moves in the same commit.**

**Two things ruled out.** Takeout: the legal point is sound — API Data is data
provided *through the API services* — but a ZIP emailed days later breaks the
one-button rule at every step. And there is **no general prohibition on merging
YouTube data with other sources**; the sentence usually quoted is a
compliance-guide bullet, while the clauses are narrower (III.E.2.a aggregation
**across channels**, III.E.2.b insight into **YouTube's own** business, III.C.5
**search-result** mixing).

**The DNS trap on `written-stl.com`:** `www` is a **proxied** `A` record to
`192.0.2.1` (TEST-NET-1) answered by a dynamic Redirect Rule — the request
terminates at Cloudflare and the address is never contacted. Grey-cloud it and
the browser hangs. **Not a CNAME to the apex**: the apex is a Worker custom
domain, and a proxied CNAME onto one returns Error 1000. The rule is dynamic
(`concat("https://written-stl.com", http.request.uri.path)`) because Google's
reviewer follows deep links. A free host subdomain cannot stand in.

## Output pipeline

```
Distiller (per source)  →  [DistilledRecord]  →  CSVExporter  →  CSVDocument
                                                                      ↓
                                                        .fileExporter (Files app)
```

- Every source normalizes into the **same** `DistilledRecord` schema, so the
  downstream ontology/embedding work consumes one shape regardless of platform:
  `source, data_type, item_id, name, creator, detail, extra, collected_at`.
  `extra` is a `key=value;key=value` string for platform-specific context — put
  platform quirks there rather than widening the schema.
- `DistillViewModel` holds records in memory and replaces per-source on
  re-distill (`replaceRecords(from:with:)`).
- **Data no longer stays on-device.** Everything leaving the device is on this
  list, and the value of the list is that it stays short and complete.
  - **Postgres, keyed to the account** — the distillation itself, via
    `SyncService`, plus the profile, the ban list and derived health signals.
    **Health takes the same path as every other source**, plus its derived
    figures; for months this paragraph said so while `DistillViewModel.sync`
    branched health away to send only the figures, so `distilled_records` held
    **zero** `source='health'` rows for every user ever while connections and
    signals showed it distilling normally. Nothing looked wrong because the half
    that failed was the invisible half, and `apply(_:)` carries across only
    `isLocalOnly` rows, so the local copy survived exactly one launch. One edge
    case keeps the old `pushConnection` fallback: `push` returns early when rows
    existed and *every* one was withheld, which for Health is a real shape.

    The volume argument once given for discarding those rows was never real — the
    distiller sums samples into day and hour buckets *before* making a record, so
    a year is 400–700 rows against 2,540 from one real Apple Music library.

    **The gate is the vault's rather than this path's**: `FitnessPurposeGrantService`
    records a `fitness_connection` grant and the encrypted copy is withheld
    without one. This legacy push predates the contract and is what the typed
    envelopes replace.

    **`health/biological_sex` is the exception and is refused at the wire** by
    `SyncService.localOnlyTypes` — a per-`source/data_type` list, because the
    unit of that decision is a row rather than a source. It is a protected
    characteristic, nothing downstream asks for it, and `public.users.sex`
    already means the gender somebody *chose*. Still kept locally and in the
    owner's own export. `localOnlySources` survives, empty, for the next source
    that may not be stored at all.

    Row-level security is the whole authorisation layer.
  - **Lyrics providers** — `LyricsService` sends the top song's artist and title
    to lrclib.net, then music.163.com. One artist and one title, no user id, no
    library, cached so a song is asked once.
- **The server is the source of truth; the device keeps a cache.**
  `RestoreService.hydrate()` is the read half: records, `source_connections`, the
  user object, health signals and bans.
- **Nothing in Postgres is ever deleted, and only changes are stored.** The
  device *replaces* a source's rows in memory; the server *appends*.
  `append_source_records` stamps every row of a run with one `distilled_at`, and
  a `before insert` trigger drops any row identical to the newest version of
  itself. Two things make that work and both are easy to break: the comparison is
  against the **latest** version, not any historical one (or a value that changed
  and changed back is silently lost), and it **excludes `collected_at` /
  `distilled_at` / `updated_at`**, which differ on every pass.

  **Three exceptions, none a change of mind:** account deletion, the YouTube
  30-day sweep (`0016`), and `SyncService.deleteSource(_:)`. All three are
  obligations — "we kept it, marked as removed" fails an audit. **`markedRemoved`
  is still right for striking a row off** but cannot stand in for a deletion
  somebody is owed. `deleteSource` needs **no edge function** (`0001`'s policies
  are `for all`), but note the trap: PostgREST wants a query string, and
  `URL.appendingPathComponent` escapes the `?`, turning
  `distilled_records?source=eq.youtube` into a request for a table of that name.
  It 404s, which is the lucky failure; the unlucky one is a DELETE with no filter
  at all. `URLComponents`, always.
- **Read through the `summary_*` views, never the tables.** They return the
  latest row per item across all runs — a union, deliberately **not** a sum,
  since a HealthKit run reports sessions over a lookback and Apple Music reports
  cumulative play counts. The views are `security_invoker = on`; without it a
  view runs as its owner and bypasses RLS.
- **Signing out erases the device** — `signOutLocalState()` clears the cache, the
  ban list, the tree seed and the OAuth tokens. **Local state must be cleared
  before the session is dropped**: `AccountScope` reads the stored user id to
  know which files and Keychain items belong to the account, and after
  `SupabaseAuth.signOut()` it resolves to `local` and would clear the wrong ones.
  `HomeView` is the only place wired for this, and `GrowProfileView` deliberately
  has no `onSignOut` so there is no second route that could skip it.
- `PrivacyInfo.xcprivacy` must agree with that list.
- **A connection is a snapshot, not a subscription**, so "connected" means *has
  been connected* — which is why `RecordStore` persists it. **And a connection is
  not the same fact as a row.** Connectedness was inferred from record *volume*,
  so a YouTube account with no likes and no subscriptions was indistinguishable
  from an untouched one — same modality offered again, no `ConnectedBar`, empty
  badge ring, stage zero, **no error anywhere, because the distillation had
  succeeded.** Everything reads `branches` now. `ConnectionStore` is the local
  half of `source_connections`, which the server has always recorded correctly,
  and `replaceRecords` is the hook every source's rows pass through. It matters
  most for **Podcasts**, where zero is the *normal* result; Calendar and Health
  keep failing loudly on nothing, because for those an empty answer and a refused
  permission are the same answer.
- Exports are git-ignored (`written-distillation-*.csv`) — they are personal data
  and must never enter history.

## Signing in: three routes, but only one of them creates an account

**All three routes open a session; only phone creates an account.**
`supabase/functions/resolve-signin` refuses any Apple or Google session whose
`public.users` row has no phone, and deletes the orphan Supabase just made — the
`id_token` grant signs up and signs in with the same call, so "there is no
account for this identity" is only knowable *after* one has been made. Apple and
Google are therefore *sign-in for an existing, linked account*, and `SignInView`
says so on screen before the refusal can happen. Two consequences reach beyond
the sign-in screen: **a reviewer cannot create an account by any route they
control**, and **`AuthError.noLinkedAccount` is the correct behaviour**, not a
bug to be fixed the next time somebody reports that Sign in with Apple "doesn't
work".

**A button that does nothing is worse than an absent one.** Three of the four
launch-screen buttons once authenticated nobody: no session, no `route(for:)`, no
`auth.users` row, and the account was gone by the next launch. It cost a day
spent in the discovery publisher, the feed and the photo pipeline — **"the
account doesn't exist" is a hypothesis worth eliminating before any of the
machinery downstream of it.**

- **Apple** — native `ASAuthorization`, identity token traded for a session.
- **Google** — the *same* PKCE machinery that connects YouTube, asked a different
  question: `openid email profile`, and the `id_token` goes to Supabase's
  `grant_type=id_token`. No SDK, no client secret; the dashboard side is this
  app's client ID in **Authorized Client IDs**, because Supabase validates the
  token's `aud` against that list. Two refusals in it are deliberate. It does
  **not** persist Google's refresh token — saving it would file it under
  `AccountScope.current`, still `local` because the account being signed into
  does not exist yet. And `interactiveIdentityToken` never reuses a cached or
  refreshed token: reuse is right for reading a library and wrong for proving
  identity, where a token refreshed from the previous user's grant signs the
  wrong person in.
- **Phone** — Supabase's **Twilio Verify** provider. `sendOTP` / `verifyOTP`,
  sharing session adoption with the other two through `adopt(_:)`, which was
  lifted out of `exchange` because phone arrives from `auth/v1/verify` rather
  than `auth/v1/token`. Two copies would be two places to forget the
  `UserDefaults` write that `AccountScope` reads.

**Route from the step, never from a constant.** `onSignedIn` calls
`route(for: onboardingStep)`; hardcoding `.photos` is what skipped the
communication style page for every phone user. **E.164 is built once**
(`PhoneNumberView.e164`) and used for both calls: Supabase verifies a code
against the number it *sent* to, so a space in one string and not the other fails
a correct code against a number never messaged.

### What phone costs, and why it is not charged for

~$0.058 a verification in the US, **~$0.12 in Hong Kong** — a flat $0.05 Verify
fee plus the SMS channel fee, roughly eight times higher in HK because it is a
small market terminating internationally. It cannot be passed to users on iOS
anyway: in-app charges for digital services must go through IAP, whose price
points start around $0.29.

**The exposure is fraud, not traffic.** SMS pumping can burn hundreds overnight.
Four controls, in order of how much they buy:

- **Twilio Verify geo permissions, Hong Kong / Taiwan / US only.** Console →
  Verify → Settings → Geo permissions. **Separate from Messaging geo
  permissions**, which look identical and do nothing for Verify traffic.
- SMS Fraud Guard on.
- Supabase SMS rate limit at **10/hour**, project-wide: a ~$29/day worst case.
  It is *not* per-user, so five testers in an hour is half the budget.
- **CAPTCHA deliberately not enabled** — on native iOS it means a WebView-hosted
  challenge and a token threaded into `sendOTP`, real work against an exposure
  the three above already bound. **Revisit the day that rate limit is raised.**

Twilio also gates sending behind **Trust Hub KYC**: an unapproved primary
compliance profile answers "Primary compliance profile is not approved" and no
SMS leaves. An Individual profile is enough for Verify.

## Launch routing: the first frame must already be the right screen

`RootView` picks one of five screens — `signIn`, `name`, `communication`,
`photos`, `home` — from a single `Route`, never a set of booleans that can
disagree. Two rules, each paid for once:

- **Decide synchronously.** `SupabaseAuth.hasStoredSession` reads the Keychain
  and `restoredStep` reads `UserDefaults`; both are instant. Deciding from the
  Supabase token refresh meant the sign-in screen was drawn for two to four
  seconds and then replaced. `restoreSession` still runs and the server still has
  the last word; it corrects a route rather than choosing the first.
- **Onboarding steps are routes, not covers.** A `fullScreenCover` has to draw
  something underneath it, and the something was `SignInView` — so resuming on
  the photo page reintroduced the very flash the point above removed.

`restoredStep` mirrors two facts that live on the server (the name, and whether
the photo page has been shown). Anything that moves them — `upsertProfile`,
`loadProfile`, `markPhotoStepSeen` — must call `cacheOnboardingStep()`, and
`signOut` must clear it along with `firstName` and `hasSeenPhotoStep`, or the
next account inherits the last one's answers and is never asked its name.

**`loadProfile` is the correction, and it is the whole of how a new phone skips
onboarding.** It runs inside `restoreSession`, before `RootView` recomputes the
route, and on each fresh sign-in path. It reads all six facts `onboardingStep`
branches on and `adopt(_:)` fills any local store the device is missing, **one
direction only**: the local answer wins where it exists, because somebody may
have changed something on this phone a moment ago and be offline.

Three of those six had no column until `0034`, and a `distilled_records` row
cannot stand in for one here, because records arrive with `hydrate()`, which
needs `AppShell`, which needs the route. **The data could not unlock the route
that would load the data.** Anything added to `onboardingStep` needs a column and
a line in that select.

## Encoding: every generated file must support every language

**Any file this project writes must be UTF-8 with a BOM (`\u{FEFF}`), not just
UTF-8.** Users' libraries are full of Korean, Japanese, Chinese, Cyrillic, and
emoji. Plain UTF-8 is *correct* but Excel doesn't assume it — without the BOM it
falls back to a legacy Western encoding and non-Latin text renders unreadable,
so the bug only appears for the person opening the file in Excel. `CSVExporter`
prepends the BOM; apply the same rule to any new export format. For pandas, read
with `encoding='utf-8-sig'`. CSV escaping is RFC 4180 (quote fields containing
comma/quote/newline, double embedded quotes) — titles genuinely contain commas
and quotes, so don't hand-roll a simpler join.

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
- Xcode 16+ synchronized-folder project — new files under `Written/` are picked
  up automatically, no pbxproj surgery.
- New OAuth sources: add an `OAuthProvider` case rather than writing another auth
  service; `OAuthPKCEService` is provider-parameterized. Google *sign-in* is a
  second case on the same client, with `persistsRefreshToken: false`.
- **`web/` is the website, and it is not part of the app target.** A static page,
  no build step, deployed as a Cloudflare Worker serving `./web` as assets —
  `wrangler.jsonc` at the repo root, `web/README.md` for the deployment and the
  two headless-Chrome traps.

  **Every file in that directory is published**, and the two config files being
  exceptions is what makes it easy to believe otherwise: Workers consumes
  `_headers` and `_redirects` itself so both answer 404, which reads as "notes
  are not served". They are — `README.md` was live at
  `https://written-stl.com/README.md` for a day, carrying the Google scope
  justifications. `web/.assetsignore` excludes it; **anything added there that is
  notes rather than site goes in that file in the same commit.**

  **A Cloudflare dashboard toggle can add a third-party script to this site
  without touching the repo**, and one did: Web Analytics put a beacon on every
  non-EU page load while `web/en-us/cookies/` told reviewers nothing is fetched
  from anywhere else. The CSP's `connect-src` refused it, so the promise held.
  Disabled 2026-08-05. The check —
  `curl -s -H 'Accept: text/html' https://written-stl.com/en-us/ | grep -c
  cloudflareinsights` — **is load-bearing on that header**: injection keys off
  `Accept: text/html`, not the User-Agent, so a version keyed on the User-Agent
  answers 0 unconditionally. Run any such check while the thing is still switched
  on before trusting its zero.
- Pagination is capped by `AppConfig.maxPagesPerEndpoint` / `maxPlaylistsExpanded`
  / `maxSongsRated`. A per-item fetch that can't be capped is a red flag — Apple
  Music's ratings pass was one round trip per hundred library songs with no
  ceiling.
- **Independent fetches within a distiller run concurrently.**
  `AppleMusicDistiller.distill` is the shape to copy: one `async let` per
  independent endpoint, then dependent passes through `inParallel`, which keeps
  five requests in flight rather than all of them.
- **`Array.sort` is not stable in Swift.** Sorting messages on `sentAt` alone
  left rows with equal timestamps in a different order on every poll, and the
  unread band appeared to wander. Ties break on `id` now. `now()` is the
  *transaction* time in Postgres, so a batch inserted in one statement shares it.
- **Version a cache file when its model gains a field whose absence means
  something.** `read_at` was added and every row written before decoded with
  `readAt = nil`, indistinguishable from genuinely unread — hence
  `written-chat-v2-`. **An optional that decodes to nil is a value, not a gap.**
- Per-source failures are surfaced in that source's card (`SourceStatus.failed`)
  and never abort the other sources.
- **A call that can fail, a result nobody reads, and the symptom surfacing
  somewhere else.** This codebase's recurring defect, eleven instances so far and
  several written *after* this entry existed — `SyncService.lastError`,
  `PhotoService.lastError`, `DiscoveryCardService.lastError`, `record`'s
  discarded return, `paths()` answering `[]` for *could not ask*, `devices()`,
  `senderPhotoURL`, `ChatService.conversations()` and `LikeService.admirers()`
  (which overwrote the cache with their empty answers), and `SyncService.push`'s
  silent token guard. **The fix is the type, never another boolean** — return
  `nil` for *could not ask* so the caller is `if let`.
- **A shared `lastError` is not a record of what failed.** Whoever writes it last
  wins, so a later success erases an earlier failure. Anything that needs a
  reason takes the returned `String?`. And **every `return false` on a push path
  sets `lastError` first**, or a dead session reports itself as a network
  problem.
- **Never guard a request on the stored `accessToken`.** It is a cache: a token
  lasts an hour and a cold launch has none until `restoreSession()` has been
  round the network. `validAccessToken()` refreshes, and
  **`SupabaseAuth.currentUserID()`** is what to call when a request needs a user
  id — it awaits the token *then* reads the id. Reading `userID` first reports
  "not signed in" for a session merely not restored yet, which is how every fetch
  in `ChatService` and `LikeService` drew an empty Chat tab on every cold launch.
  `loadProfile` is the one deliberate exception.
- **`public.users.sex` means the gender somebody *chose*, and nothing else.** It
  was written by the gender step and by `pushDemographics` carrying HealthKit's
  *biological sex*; last write wins and Health re-distills every time it is
  connected, so HealthKit would eventually overwrite a chosen gender — silently,
  repeatedly, and worst for exactly the people it matters most to.
  `pushDemographics` now sends only `birth_year`. **Two columns that accept the
  same words are one column with two meanings.**
- **A published contact channel is a claim; test it like one, with a round trip
  rather than a lookup.** `hello@written-stl.com` was named on all five site
  pages and in `SettingsView` while the domain had no MX record at all, so every
  data-rights request bounced. Records resolving is not delivery working.

## Iterating on the garden illustration

**Five illustrated stages, one per connected modality plus bare soil.**
`TreeSkeleton.make` maps 0-4 to sprout/shoot/branch/bough/canopy; beyond that the
generated tree takes over. Stage 4 has art because falling through to generated
geometry there reads as the drawing breaking rather than as growth.

Rules that outlive any particular tweak:

- **Drive stages from the launch line, never by patching the source.**
  `xcrun simctl launch <device> com.written.datingapp -route home -stage 3`;
  `-stages all` renders every illustrated stage at once and is how shared
  geometry (`leafTilt`, `leafletTilt`, `LeafSpine`, the blade profile) is checked
  — a sign error in one silently distorts stages it was not being edited for.
  `-route home` is required unless the simulator holds a session. See
  `Views/Tree/DebugLaunch.swift`.
- **Measure, don't eyeball**, and one build per batch of changes with one
  cropped, downscaled screenshot per iteration. Reference measurements are
  recorded beside the constants they set (`SeedlingArt.swift`,
  `WateringCanOverlay.swift`).
- **The badges' bob is a sine of `TimelineView`'s date**, not
  `repeatForever` — any other explicit transaction touching a badge (including
  its own arrival spring) permanently replaces a repeating animation, which
  reported as "only the new icons float". One clock in `GrowProfileView.garden`,
  no phase offset, paused when the tab is not visible.
- **The bob goes into `.position`, never `.offset`.** An `.offset` moves the
  pixels and leaves the layout frame behind, and the tutorial cuts its hole from
  `anchorPreference`, which reports that frame — a bobbing badge sat 16.8 device
  pixels outside its own spotlight. `ModalityBadge.bobOffset(at:diameter:)` is
  static and the caller adds it to `.position`, which *is* layout. **The general
  rule: nothing may sit between `.tutorialTarget` and the pixels that moves the
  drawing without moving the frame** — the arrival `.scaleEffect` is the other
  one, handled by making the mark wait for the spring (`badgeSettle`).
- **Badge positions come off `leafLift`, never `displayedSkeleton`.**
  `SeedlingArt.shoots(by:)` *blends* shoots toward their canopy shape past stage
  3, so reading the discrete stage landed that blend outside any transaction and
  the badges appeared to vanish and reappear elsewhere.
- The first shoot's badge is dropped further than the others (`firstShootDrop`,
  +0.031) because its neighbour is the cotyledon badge, spaced by nothing. The
  fourth sits *above* its shoot (`shootBadge`) with **full** outward travel —
  tucking it inward puts it on the cotyledon blade. Shoots alternate sides going
  up, so a new one belongs on the side the last one wasn't. `StageSheet` derives
  its row count rather than hardcoding 2×2.
- `-tutorial badge` plus `tools/badge_hole_check.py` measures the coach mark
  against the badge; it refuses a screenshot taken during the mark's 0.22s fade.
- Rapid screenshot bursts and headless boots crash `backboardd`. Recovery is
  `killall Simulator && xcrun simctl shutdown all`.

## The layout audit: what proves nothing overlaps

    ./tools/run_layout_audit.sh          # 5 iPhone widths x 2 text sizes
    python3 tools/layout_audit.py out/layout/*/

`WrittenUITests` dumps accessibility frames and `tools/layout_audit.py` does the
geometry, because a screenshot only proves a screen looked right where somebody
looked. Four things it is easy to get wrong:

- **`-solo 1` is required.** `AppShell` mounts every tab and hides the rest with
  `opacity(0)`, `allowsHitTesting(false)` and `accessibilityHidden(true)`, and
  **XCUITest honours none of the three** — 543 overlaps, none real.
- **Never `descendants(matching: .any)`** — it kills the accessibility server.
  Ask per element type.
- **The dumps come out of the result bundle** via `xcresulttool export
  attachments`; a UI test runner's `print` never reaches `xcodebuild`.
- **`tools/layout_allowlist.json` is judgement, not bookkeeping.** This app
  overlaps on purpose, so regenerating with `--update-allowlist` without reading
  the diff is how the next real overlap gets buried.

Widths 375–440 catch geometry; the accessibility text size catches that **this
app mixes two font systems** — `BrandFont` scales, the 165 `.system(size:)` calls
do not. Discovery is **not** covered: it needs a real signed-in session.

## The two halves of the app

**Onboarding is a line; regular use is a tab bar.** Onboarding runs sign in →
birthday → name → gender → interest → communication style → photos → grow the
plant → "People you will see", and ends the moment **Explore** is tapped there.

**The birthday is first, and the ordering is the argument.** Everything after it
— a name, a gender, photographs — is data the app may have no business collecting
until that question is answered. `minimumAge` is 18, enforced in
`DistillViewModel.setBirthday`, again in `BirthdayEntryView` because the
onboarding page runs two screens ahead of any view model, and a third time in
`HealthKitDistiller` for the date of birth Health reports. Apple's June 2026
guidance is explicit that an app teens may reach must be age-appropriate in
itself, and reviewers test it by typing a birth date.

**Continue on the birthday page raises a card that reads the date back in
words** (`BirthdayConfirmCard`) — this is the one answer in onboarding that
cannot be corrected later without a support request. It is an **overlay, not a
`.sheet`**, so the keyboard does not drop and return for a correction nobody has
made yet; the three refusals (impossible date, 130 years back, under 18) stop at
the field and never reach it, since drawing "You're 4" over a confirmation would
read a refusal back as an acceptance; and **`confirming: Date?` *is* the
presentation state**, so the card and the date it names cannot disagree.
`BirthdayFields.errorRed` is `(240,72,72)`, brighter than anything else on
purpose, and **a fill threshold cannot measure these boxes from a screenshot** —
measure off the *error* state.

**Gender is one answer and who you date is several, and the control says so.**
`GenderEntryView.Purpose.isSingleChoice` drives both the arity and the shape —
radios for one, checkboxes for many — because that shape is the only thing
telling somebody whether a second tap will replace their first. Single-choice
rows *replace* rather than toggle: a radio that can be tapped off leaves the page
with no answer. The two pages **name the same three cases differently** and both
namings are right: "Male" is what you are, "Men" is who you would date.
**"Everyone" is a fourth row and not a fourth case** — an `everyone` case could
not say "men and non-binary people".

**Every one of these steps writes its local copy first and pushes in a detached
`Task` whose result nobody reads** — right, since onboarding should not block on
a round trip Postgres cannot refuse, but `needsBirthday` and `needsGender` are
answered from those *local* copies, so a failed push is never retried and never
re-asked. `DistillViewModel.repairIdentityPush` is the backstop, run from
`restoreFromServer` on every launch and guarded on the server actually
disagreeing, in the same shape as `adoptStoredCommunicationStyle`.

**The communication step is two sliders**, flirt level and response time, because
both are *boundaries* and a boundary set after the fact has already failed — which
is why it comes before anything can message anyone. Each bar is continuous under
the finger and one of **four bands** (`StyleBand.count`) to everything else:
nobody can honestly place themselves at 0.62 of a flirt, and a number that
precise invites a matcher to believe it. Flirt level carries **two
vocabularies**: the stored `rawValue` is flat (`Low` … `Extremely High`) while
the dashboard shows `Platonic` / `Mild` / `Flirty` / `Freaky` — good to read
about yourself, poor to sort a database by. Response time is stored as its tempo.

**The flirt dial's geometry is fixed by one constraint, not chosen.** The
captions sit on **thirds of the card** and the arc's two legs stand directly
above them, so `halfOpening = asin((0.5 - 1/3) / (diameter/2))` — which means
**shrinking the dial widens the gap**. `FlirtGauge` owns its captions, unlike
every other card here, and is the one thing that cancels `DashboardView.cardInset`,
because thirds of *the card* is not thirds of its content. Measure it on a
screenshot showing the **whole** card: `-scroll communication` hides the dial's
upper half and reports 52% for a dial that is 76%; `-scroll photos` works.

Two traps, both paid for while building it:

- **Adding a step re-opens onboarding for everyone who finished it.** The cached
  `restoredStep` said `done` — for the steps that existed when it was written. It
  answers `.communication` when the cache says `done`/`exploring` and no style is
  stored, matching what `onboardingStep` computes live, and on finishing the next
  route is **asked for** rather than hardcoded.
- **The answers are collected before a view model exists.** They go to
  `CommunicationStyleStore` (UserDefaults, account-scoped), which is *also* what
  `needsCommunicationStyle` reads — so having an answer and having been asked
  cannot disagree, unlike `hasSeenPhotoStep`, which needs its own flag because
  that page finishes whether or not anything was picked.
  `adoptStoredCommunicationStyle` copies them into `user` records after
  hydration, and is idempotent because it also runs as the repair on every launch.

Through all of onboarding the tab bar is absent: a bar would offer four exits
from a sequence whose whole point is that it has one. The garden therefore keeps
an arrow at its foot and a pull-up gesture.

**That pull-up is a reveal, and two things make it one.** `AppShell.page` hides
every unselected tab with `opacity`, which is right for a bar and wrong for a
drag, because during one *two* pages are on screen while `tab` still names the
one being pulled away — so the gesture revealed bare parchment until it
committed. `isDrawn` is the fix, the same shape as `DashboardTab` hiding the
profile preview until its slide began: *a layer needed during a transition, gated
on a flag that only moves at the end of it.* The second is **z-order**: the
dashboard must be built before the garden. Hit testing stays on `tab == which`
even while both are drawn, and `gardenLift` returns to **zero at rest**.
`-reveal 0.5` holds the frame and `-reveal 1` lands on the dashboard — **the only
way to screenshot Memories from a script**, since `simctl` can send no drag.

Regular use is the reverse: the bar exists, so the garden gives up the arrow and
the pull-up and the dashboard drops its "Garden" button, gaining sign-out and
delete — both hidden during onboarding, since offering to destroy an account
beneath the button that carries on making one invites ending it by accident.
`SupabaseAuth.OnboardingStep.exploring` marks the boundary, so a force-quit
mid-garden resumes correctly; `AppShell` owns the flag and every screen reads it.

`-route birthday|name|gender|interest|communication|photos|home|signIn` opens
straight onto a screen (DEBUG only). **`-birthday confirm|error`** seeds a
*state* rather than a screen, for the same reason `-reveal` does: both need a tap
to reach and `simctl` can send none.

## The tab bar, and why it must never inset

Four tabs: Explore, Chat, the garden, and Memories (the dashboard). Wish — the
bottle — is `ARCHIVED-WISH`: `MainTab.wish` and `BottleIcon` stay commented in
place so restoring it is uncommenting rather than redrawing. Nothing persists a
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
people impossible rather than merely unbuilt. Two tables open that up and no more
should without the same argument — `bookmarks` (`0035`) is *not* a third: it
names another user in a column, but only the owner may read the row.

- **`discovery_cards`** (`0007`) — a name, an age, a district, six photo seeds
  and derived `{domain, subject}` pairs. Deliberately **not** a view over
  `distilled_records`: enough for `Ontology.line(for:subject:)` to write a line,
  and nothing that could reconstruct a distillation. **Subjects only** — things a
  sentence can be *about*.
- **`shared_posts`** (`0008`) — a video id and a sentence somebody chose to
  publish. `sharer_name` is denormalised because `public.users` is
  `auth.uid() = id` and opening it for a byline is not a trade worth making.

Both split read from write. Measured 2026-07-29 from a real signed-in session
rather than argued from the policy text: 6 cards and 5 posts visible, 12 own
records against 2528 that exist, 0 to an unauthenticated caller, and a forged
post naming another user refused with `42501`. **Re-run that probe if these
policies are ever touched** — a table opened for read is the one place in this
schema where a mistake is silent.

Six synthetic accounts populate it (`tools/seed_synthetic.py`, needs the
`service_role` key). **For a long time they were the *only* people in it**: the
seeder writes six and **nothing in the app ever wrote a card**, so every real
signup was invisible — not a bug in the feed, `0007` has carried own-row insert
and update policies from the start and only the caller was missing.
`DiscoveryCardService.publish` is it, called from `DistillViewModel.sync`. The
feed also never excluded the viewer, now filtered in the query with
`user_id=neq.…` so it never crosses the wire.

**A match profile is two reads and only one of them was ever guarded.**
`match_profile` returns school and bio behind a condition; the name, age,
district and photographs came from a direct read of `discovery_cards`, whose
policy is *any signed-in user may read this table* — so `0123` hid a blocked
person's two fields and left their face. `0126` adds `public.match_card` under
the same condition and factors that condition into `private.may_see_match` —
**one function called twice, because a copy would have been the third place to
edit and the first to be forgotten.** Deliberately **not** gated on
`discovery_profile_reads`: that flag decides whether the *feed* is server-owned,
while this is a hole that exists today.

**`api.discover_profiles` (`0120`, completed by `0125`) is the server-owned
replacement and ships dark.** `assert_surface_allowed('matching')` requires
`discovery_profile_reads`, which is `false`, and nothing in Swift calls it. It
exists because the rules currently live in the client — `DiscoveryService`
appends `user_id=neq.<me>` and `DiscoveryModel` filters likes in three places
that must agree — and a courtesy is not a rule when another client holds the same
anon key.

**§10's gate asks for revision and surface permission, which are properties of an
assertion rather than of a card**, so the RPC returns, beside each card, the
terms that person may show: eligible assertions carrying the grant, scored at the
subject's current revision, and — for inferred ones — passing
`concept_has_non_video_witness`. The witness test applies to inferred assertions
only: a declared one has no observations, so demanding a witness would withhold
precisely the terms somebody chose about themselves.

**Which grant, though, is what `0128` fixed.** The matching surface **may *use* a
term and may never *name* it** — naming somebody's term to another person is the
**`bio`** surface, which is why `assert_surface_allowed` calls a bio *"a
projection of one person shown to another"*. `0125` returned labels gated on
`matching.can_select`; `matching_terms` gates on `bio.can_name` now.

**And every one of those grants was false, for everybody, because a derived claim
defaulted to owner-only** — each assertion is born `memories(true,true,true)`
with the three outward surfaces shut. **The product decision (2026-08-13) is that
a derived claim needs no purpose grant**: Explore shows whoever fits the viewer's
dating preferences, a profile's contents are simply shown, and the one lever a
person has is Settings → dating preferences. Terms are profile content like a
photograph. **No consent screen, because what one would have bought already
exists** — Memories lists the same terms and suppressing one there already
removes it from `matching_terms`; what was missing was only a line of copy saying
so. `0128` opens `matching` (`can_select`) and `bio` (`can_select, can_name`) and
leaves `icebreaker` shut, having no consumer: **155 of 178 opened; 23 refused by
the source guards**, which is those guards working.

**Two things that migration cost.** Its first draft set `can_name` on `matching`
and **every one of 178 rows was refused** — and the count named nothing, because
the three triggers it was natural to blame all early-return without their
evidence type; carrying `SQLERRM` out in the raised exception found a *check
constraint*. And the back-fill is **row by row inside its own exception block,
never one `update`**: a bulk statement meets the first guarded row, raises, and
rolls back every grant behind it.

**The client routes on the flag, and the asymmetry is the safety property.** Flag
off falls back to the direct read; **flag on and the call failing does not** — a
fallback on error would let an outage quietly restore the unauthorised path.
`terms` is carried on `Person` and drawn by nothing yet, because routing should
decide *who* is shown before it changes *what* is shown.

**Rate limit is 60 calls an hour**, recorded in
`semantic_private.discovery_requests` — and **nothing sweeps that table yet**,
which wants a `pg_cron` job like `0016`'s.

**It filters on eligibility, which nothing did before, and that will read as a
regression.** Both production users are `sex = 'Male'` and
`interested_in = {female}`, so the current feed shows each of them somebody
neither asked to see, and under the RPC they correctly see nobody.

**And the two gender columns speak different vocabularies, which `lower()` does
not bridge.** `users.sex` holds `Gender.label` — `Male`, `Female`,
**`Non-binary`**; `users.interested_in` holds `Gender.rawValue` — `male`,
`female`, **`nonbinary`**. A casefold comparison matches the two binary cases and
**silently drops every non-binary person from every feed in both directions**.
`private.gender_key` is the one place that maps them and returns null for
anything unrecognised, so it fails closed. **The real fix is for the two columns
to share a vocabulary** — an app change and a backfill.

### Bookmarks

**A private note to yourself, and the privacy is the design.** `0035` is one
table with one policy — `for all using (auth.uid() = user_id)` — so the person
bookmarked cannot read the row, is never notified, and no trigger fires. A like
is addressed to somebody; a bookmark is addressed to nobody. Three things follow:

- **It is a real delete.** "Nothing in Postgres is ever deleted" describes the
  distillation record, not a list somebody curates.
- **Bookmarking does not remove anybody from the feed**, unlike a like — so
  `bookmarked` is a set the card draws from and never a filter, and it stays live
  on a card you have already liked, because the heart and envelope are one
  invitation spent once while this is not.
- **`bookmarkedIDs()` answers `nil` for *could not ask*.** Assigning `[]` on a
  dropped request would draw every saved profile as unsaved.

`BookmarksView` draws `DiscoveryCard` verbatim through a real `DiscoveryFeed`, so
the photograph and line selection are Explore's code rather than a second copy —
but **one round only**, since discovery is endless and a saved list is finite.

It is reached from a bookmark icon **inboard of the cog** on the Memories header,
as a `fullScreenCover` like Settings — inboard because Settings is the last thing
on every bar in every app. Hidden during onboarding. The paper plane that used to
sit there is deleted rather than disabled: there is no URL scheme and no profile
page, so a share would open nothing.

### Blocking

**`0123` is the table and `0124` is the door.** A block is mutual, server-side,
and the blocked person is told nothing: no notification, no error naming it, and
refusals borrow wording the app already uses for a deleted account. Both ways in
the feed; a pending invitation is **revoked** (a fourth `likes.status`, because
*"I answered no"* and *"this was withdrawn"* are different facts); an existing
conversation stays **visible and frozen** — past contact is history both took
part in, and blocking ends future contact rather than erasing it.

**Because it must be invisible, it cannot be enforced by an RLS policy.** A
policy runs as the caller, so it would need `authenticated` to hold execute on
the check — and anything a client may call, a client may probe:
`is_blocked(me, them)` is the one question the blocked person must not be able to
ask. So enforcement lives in **`security definer` triggers and RPCs**:
`api.discover_profiles` and `match_profile` call `private.is_blocked`, and three
triggers revoke the like, refuse a new like and freeze the thread. `blocks`'
select policy is `auth.uid() = blocker_id`, so the row is invisible to its
subject **structurally** rather than by a screen remembering not to draw it.

**Blocking is by phone number, and the resolution is server-side for the same
reason.** `block_by_phone` returns **void whether or not it matched**, because a
distinguishable answer would make the safety screen an oracle for *"is this
person on Written?"*. `block_by_phones` is the bulk form and returns void for a
stronger version of the same reason.

**`0124`'s own assertion caught a real defect before it applied.** `anon` could
execute the function, because Supabase installs *default privileges* granting
every new `public` function to `anon` and `authenticated` — so `revoke ... from
public`, which names the pseudo-role, left a direct grant untouched. **Revoke
from `anon` by name.**

**Blocking is deliberately absent from `ProfileActionsSheet`.** It lives in one
place, the block list, because it is the only one of these that can be undone and
a control you can undo wants a screen where you can see what you have done. A
match offers **Unmatch** and Report — irreversible, and the word says so.

**And the contacts toggle still promises more than it does.** `importContacts`
takes names only, on a documented refusal: *"uploading somebody's address book
would be collecting data about people who never agreed to anything."* A name
matches only in `BanList`, on this device — so *"people you already know cannot
see you"* is true of nothing, and closing that gap means uploading contact
identifiers, which needs `PrivacyInfo.xcprivacy`, `web/en-us/privacy/` and the
App Store questionnaire moving in the same commit. **`block_by_phones` is
deployed with no caller** for exactly this reason.

### The feed's rotation

`DiscoveryFeed` shows a person repeatedly with different photographs and
different lines each time — two of each, both drawn without replacement, on
independent cycles.

**The round order is fixed, and that is not laziness.** Requiring five profiles
between one person and their next means `q >= p` for everyone simultaneously
across a permutation, which only the identity satisfies; a repeated permutation
gives exactly `n - 1` every time, the most any ordering can offer.

**A like removes that person from the feed, but not on the tap — on the next
scroll.** Removing their cards instantly takes the post out from under the
reader's thumb and hides the one piece of feedback the gesture has. `like`
therefore touches nothing but `liked`, which also keeps its failure path honest.

`DiscoveryFeed` is not where the removal happens either — its `people` is `let`,
so rebuilding the rotation would reshuffle everybody mid-scroll. `DiscoveryModel`
filters the *output*, in three places that have to agree: `load` builds from the
unliked, `extend` purges liked people from `items`, and `extend` also drops them
from each newly generated batch — miss that last one and they return the moment
the list grows. The purge sits **above** `extend`'s near-the-end guard, because a
row appearing is the only scroll signal this view has; it removes only indices
**strictly after** the one that appeared, since taking out an item above the
viewport moves what is being read; and the top-up loop is **bounded**, or asking
until six survive spins forever once everything left has been liked. An all-liked
feed is not a failure: `load` must leave `failure` nil there.

Shared videos are interleaved every fourth item rather than mixed into that
machinery, since the separation rule is about people and a video is not one.
Their ids carry an **appearance number** for the same reason profiles' do: one
post recurring with one id hands `ForEach` duplicates, which hung the app.

## Embedding YouTube, which took six attempts

**The player will not run in a document with no origin, and an app-built page has
none.** A base URL resolves relative links and is not an origin, an `origin`
player var is a claim, a top-level `youtube.com/embed` load gets 153, and
**Supabase cannot host the page** — edge functions and Storage both rewrite HTML
to `content-type: text/plain` with `default-src 'none'; sandbox`. What works is
`loadSimulatedRequest`, which gives the HTML the security origin of a URL you
name — a **third-party** one, since the page had been claiming to *be*
youtube.com. It claims the project's Supabase host now.

None of that was deduced: five fixes were reasoned from a single error number and
all five were wrong, while the page's own console said `api: loaded`,
`player: ready`, `error: 152`. `EmbedWebView` still forwards `console`,
`window.onerror` and player errors through `onLog` — nothing draws them, and the
next blank player will want them back.

Playback follows the card nearest the middle of the screen, muted, one at a time.
Muted is load-bearing: WebKit blocks unmuted autoplay outright. Sound is a
preference of the *reader*, so unmuting one video unmutes the feed — and resets
on launch.

## The share extension

`ShareToWritten` is the second of three targets. (`NotificationService` is the
third, and deliberately carries *neither* the App Group nor the keychain group,
because its image URL arrives pre-signed and it needs no session at all.)
`ShareToWritten` needs three things on **both** targets: the App Group, a shared
keychain group so the extension can read the session and post as that user, and
matching bundle ids. Verify entitlements in the *signed* binary, not the
`.entitlements` file; Xcode has silently dropped one here before.

It is **deliberately self-contained**, repeating the host, the anon key, the
keychain read and the link parsing rather than sharing files — synchronized
folders scope everything under `Written/` to the app target, and sharing files
means the `project.pbxproj` surgery that arrangement exists to avoid.

Three things the template gets wrong for this use. Its activation rule is
`TRUEPREDICATE`, which offers Written in every app's share sheet for photos and
contacts it cannot use. Its compose sheet pre-fills the text view with the shared
item, which published the URL as the caption. And **`INFOPLIST_KEY_*` build
settings beat the `Info.plist` file**, so the display name has to change in
`project.pbxproj` or the share sheet says "ShareToWritten".

## Likes and chat, and the upsert that column grants forbid

Proven end to end on a real device 2026-08-01: a like, an accept, a message, a
reply on the four-second poll, a decline. `0009` is fully applied.

**`resolution=merge-duplicates` cannot be used on `likes`, `conversations` or
`messages`.** It compiles to `on conflict do update`, and Postgres checks
privileges when it *plans* a statement rather than when a conflict happens — so
it demands `update` on every column being inserted, whether or not the row
exists. `0009` revokes update on all three tables and grants back only the narrow
columns each side may answer with (`status, responded_at`; `read_at`), precisely
so a recipient cannot rewrite `liker_id` and forge a like. The privilege wins,
and the failure is **42501 on every attempt**. That shipped: `LikeService.like`
used it, so every double-tapped like in the feed was silently refused — silently
because the heart fills optimistically and `lastError` is recorded and never
shown. `ignore-duplicates` gives the same idempotence through `on conflict do
nothing`. `SyncService` and `SupabaseAuth` still use `merge-duplicates` and are
fine: `0009` is the only migration that revokes update.

**There is a second precondition, and it is a policy rather than a privilege.**
`on conflict do update` has to be able to *see* the row it might update, so a
table with RLS enabled and **no select policy cannot be upserted into at all**,
including when it is empty. `device_tokens` was given insert, update and delete
policies and deliberately no select policy, and every registration answered `403
… violates row-level security policy … 42501`, which reads as a wrong `user_id`
and was nothing of the sort. So: **`merge-duplicates` needs update privilege *and*
a select policy.**

**A name in a chat was a copy of a copy.** `likes.liker_name` is denormalised
when a like is sent and `ChatService.open` copied *that* onto the conversation,
so a profile read "Chan Tai Man" in Explore and "Marco" in the chat header. Names
now come from `discovery_cards.display_name` through `ChatService.cards(for:)`,
alongside the photograph. The stored columns remain as the fallback, because
`0009`'s insert policy needs them at creation when no card may exist yet. **The
same gap existed on the two single-conversation fetches**, so a thread opened
from a notification tap drew the generated portrait and the frozen name.

**One invitation per person, and it is either a heart or a note.** Whichever was
used is red and filled and the other fades; both go inert.

**`23503` means the person deleted their account.** Every foreign key leads back
to `public.users`, and deleting an account cascades from `auth.users`. A
discovery card outlives the account because `DiscoveryFeed` is built once and
scrolled rather than re-fetched. `PostgREST.Failure` carries the error code now
rather than folding it into the message, and the feed removes them and says
"That profile is no longer available."

**Two accounts are needed to test any of this**, because RLS makes each half of a
conversation invisible to the other. `tools/chat_e2e.py` plays the second person
over REST, and the six synthetic accounts are real `auth.users` rows. A simulator
cannot be the first person; Sign in with Apple needs a device. **Read the
database after every step rather than trusting the screen** — the first accept in
that run appeared to open a conversation while writing nothing at all.

## Notifications: a like, a match, a message

Three events, sent from the database rather than a phone — the person to be told
is by definition not the person making the request, and their session is the only
thing that could reach their own devices under RLS. The path is
`likes`/`messages` trigger → `pg_net` → `functions/push` → APNs, **proven end to
end on a device 2026-08-05** through a real ES256 signature and a real sandbox
token.

- **`pg_net` is fire-and-forget**, so a dead APNs cannot make a like fail — but
  it is not invisible: it records every response in **`net._http_response`**.
  **Anything the function needs to say should travel in the response body**, not
  only to `console`; the function's own log lines were unfindable for a known
  `execution_id`.
- **The URL and shared secret live in `private.push_config`**, a table in a
  schema nothing is granted on. The function is deployed with **JWT verification
  off**, which is mandatory rather than lax — the triggers carry no Authorization
  header, and the toggle demands a JWT signed by the *legacy* secret, disabled in
  the July rotation. `PUSH_SECRET` and `x-push-secret` are the auth instead.
- **A successful install proves nothing about push.** Automatic signing issues a
  Team Provisioning Profile carrying `aps-environment: development` **whether or
  not the App ID has the capability**, so the app installs and APNs even hands
  over a token. Apple's **Push Notifications Console** and a *distribution*
  profile are what check.
- **It is a `.p8` key, not a certificate**, and **it must be created as "Sandbox
  & Production"** — the page lets you create one that is not, and a Sandbox-only
  key answers **403 `BadEnvironmentKeyInToken`** against the other host, so it
  delivers every Xcode build's notification and refuses every TestFlight one.
  That shipped, and it read as *lateness*. **`sent: 2` with `["ok","ok"]` to
  somebody with two devices is the only proof both environments work.**
- **The token's environment is not bookkeeping**: two APNs hosts, two namespaces,
  both kinds of token exist here at once, so `device_tokens.environment` records
  which and `#if DEBUG` decides it.
- **Where permission is asked has been wrong twice.** iOS allows the question
  **once, ever**. It now shows **`NotificationPrimer`** — the app's own sheet,
  naming what arrives — and only somebody who taps *Turn on* is passed to iOS; a
  "not now" spends nothing and is offered again in three days. Fired from
  `AppShell.onChange(of: tab)` on reaching Explore or Chat, 900ms after the
  transition, and deliberately nowhere near Health. **A refusal is said out
  loud** in `ChatView`, with a route to Settings — left unsaid, `device_tokens`
  stays empty and every notification reports `{"sent":0,"note":"no devices"}`, a
  *success*. `-push ask` exists because setting this up otherwise requires
  arranging to be liked.
- **`SUPABASE_` is a reserved prefix** and a secret using it cannot be created.
  The function reads the platform-injected `SUPABASE_SERVICE_ROLE_KEY`, which
  carries the `sb_secret_…` value despite the stale name; a first draft preferred
  `SUPABASE_SECRET_KEY`, a name that can never exist.
- **`create or replace function` does not replace a function whose *signature*
  changed — it overloads it**, leaving a latent ambiguity that Postgres refuses
  with `42725` *from inside a trigger on `likes`*, where the like fails rather
  than the notification. **Changing a function's parameters means `drop function`
  naming the old signature in full.**

### The banner is a person, not an app

`NotificationService` — the project's **third** target — turns each notification
into a communication notification: the sender's photograph on the left, their
name where the app's name would be. Proven on device 2026-08-05 for all three
events.

**A `UNNotificationAttachment` cannot do this.** It needs **three things in three
places, each silently inert on its own**:
`com.apple.developer.usernotifications.communication` in `Written.entitlements`,
`INSendMessageIntent` in `NSUserActivityTypes`, and an `INSendMessageIntent`
donated from the extension then `content.updating(from: intent)`.

**That Info.plist key needs a real file, because `INFOPLIST_KEY_` ignores names
it does not know** — `INFOPLIST_KEY_NSUserActivityTypes` wrote nothing, no error,
no warning. `Written-Info.plist` exists for that one key, at the repo root rather
than under `Written/`, since that folder is a synchronized group and a plist
swept into Copy Bundle Resources ships twice. **Read the built `Info.plist`,
never the setting.**

**`updating(from:)` renames the title to the sender's display name**, which is
why `0027` passes `sender_name` and `subtitle` separately — using the title as a
display name announces somebody called "Marco likes you".

**The photograph is signed server-side** (a one-hour URL against the private
bucket), because authenticating inside a process with a thirty-second life would
mean the shared keychain and a refresh, for a picture. **Everything in the
extension falls back to the plain banner**, because a notification that arrives
looking ordinary is enormously better than one that does not arrive.
`INPersonHandle` is `.unknown`, or iOS matches against Contacts and puts
somebody's saved contact photo on a stranger's profile; `INInteraction.direction`
must be `.incoming`, or Siri learns that *you* messaged everyone who has ever
messaged you.

## The semantic contract, and what it supersedes

**`Written-Semantic-System-v0.3.1` is the authority for semantic design, and this
app is not.** Its integration plan is written against this repository by name:
*"When the current Swift/SQL implementation and the v0.3.1 contract disagree, the
v0.3.1 contract controls."* Its governing rule is **capture broadly in an
authorized private vault, promote narrowly into semantic evidence, expose only
purpose- and surface-authorized projections** — four separate decisions where the
legacy path has one.

| Named as superseded | Becomes |
|---|---|
| `Ontology.swift`, `mix`, `terms`, `classify` | Server-owned classification and mapping; legacy behind a flag during shadow |
| Client-authored `discovery_cards` semantics | A paginated server-owned RPC enforcing block, eligibility, revision and surface grants |
| `summary_distilled_records` as current state | Ingestion runs with membership, coverage, tombstones and validity windows |
| `seed_icebreaker` (`0036`) | Revision-bound frames requiring active match authorization |
| Title-keyed `BanList` removals | Assertion-specific no-reason RPCs; a title ban never becomes a concept-level negative |

Everything below about the ontology, the dynamic profile, Memories and the
icebreaker is **still true of the shipping code and is now the legacy path**.

**The build history is in `semantic/JOURNAL.md`, and this section is only the
rules.** Every rule below was bought with a failure recorded there. **Read the
journal before removing a guard, adapting another reference migration, or
concluding that something looks arbitrary.**

**Migration head `0218`.** `db push` is the deployment mechanism and
`supabase/DEPLOY.md` holds the procedure. **Each migration file carries its own
reasoning in its header comment**, and that is the record — this section carries
only what a later change could violate.

### The second real account, and what it proved (2026-08-13)

**A second person connected seven sources and the pipeline produced zero
assertions.** Nothing failed — nine worker jobs succeeded, `rejected 0`. The
resolver hit 12 of 20 YouTube topics and **3 of 152 uploader tags**.

**The creator vocabulary *is* one person's Apple Music library**, minted by
`0075`, and it does not generalise: of 20 artists the second account named,
exactly two existed. The first diagnosis — that this was an alias problem — was
drawn from three examples, two of which happened to be the two that existed. It
is mostly a *concept* problem, and the tail is unbounded.

`0134` publishes ontology **0.10.0** with a third CSV family,
`semantic/ontology/youtube_terms_*.csv`. **Never add rows to `seed_*.csv`** —
`test_seed_consistency` asserts those three mirror `0044_semantic_seed.sql` field
for field. `tools/seed_from_csv.py` reads `FAMILIES`, and **does not emit the
recompute enqueue** — that block is hand-added from `0097`.

**It was necessary and not sufficient.** Unresolved terms went 191 → 159 and
scored concepts 15 → 27; the account still has zero eligible assertions, because
its whole vault is 50 YouTube observations. **Vocabulary was never the binding
constraint — evidence was.**

### YouTube channels are terms, and the flags that decide it

**Everything below the flag was already built and had never been switched on.**
`observation_mappings` has permitted `youtube_semantic_kind = 'channel_identity'`
since `0045`, `ontology.youtube_channels.canonical_title` has existed since then,
`youtube_channel_role_resolver` 0.2.0 is registered, and the projection has
always carried `channel_id`. What was missing was a catalogued title, an
approval, and worker code.

**`ontology.youtube_policy_approvals` is a row of booleans, and a new row
supersedes rather than an edit.** `initialize_youtube_run_policy` selects the
most recently approved and copies it onto the run, so the older determination
stays as history. `0135` adds
`written:determination:channel-identity:2026-08-13`, granting
`allow_channel_identity` and `allow_title_tags` alongside the uploader tags.

**The trigger looks up `model_key = 'youtube_uploader_tag_resolver'` by
literal.** Registering a differently-named resolver leaves that lookup empty and
the trigger falls to its deny-all branch — every future run silently denied,
nothing failing. Assert it rather than assume it.

**Channel titles come from `distilled_records`, not the API** — 941 `liked_video`
rows carry `channel_id` in `extra` and the title in `creator`; a `subscription`
row *is* the channel. No key, no quota, no Lambda network call. **`VideoPayload`
read `channel_id` from `extra` only**, so every subscription reached the vault
with a null channel — invisible until `0135` gave channel ids a use, and then
stark: 941 likes carried one, all 430 subscriptions carried none, and the
subscription is the stronger signal.

Measured after: 191 titles loaded, **112 `channel_identity` mappings**, and **no
new assertions** — they resolved to artists Apple Music had already proved.

### Three levers force a re-score, and a policy is not one of them

A run's identity is `(user, revision, ontology version, resolver, scorer)`.
**`0135` granted a policy and enqueued zero jobs**, correctly:
`enqueue_recompute_on_analysis_change` only enqueues where no run exists for that
tuple, and `0134`'s recompute had already created runs at 0.10.0. The YouTube
approval is not in the identity, and `semantic_run_live_identity_idx` would have
deduped a forced run anyway. So a behaviour change needs a **model version**:
`0136` publishes resolver 0.4.0, `0138` scorer 0.7.0.

**And read the grants first, not sixth.** `0136` shipped a resolver reading
`ontology.youtube_channels`, which `semantic_worker` could not see — three
invocations answered `42501` before anybody looked. `semantic_worker` is
`bypassrls`, and that is **not a grant**. `information_schema.table_privileges`
shows only what the *querying* role can see and answers empty for `ontology`; ask
`has_table_privilege` instead, as `0137` does.

### Where the informative fields actually are

Measured on one account's YouTube rows, for the repost case: the channel name
(`LisaEdit`, `Aexgrant`) is meaningless, the topics (`Entertainment`, `Film`)
are containers, the uploader tags are **null** on every repost channel — and the
**title** carries everything (*"Sheldon ran a red light… #youngsheldon"*).

**The projection keeps the fields carrying nothing and excludes the one carrying
everything.** Titles are omitted because III.E.4 requires them deleted or
refreshed within 30 days and `guard_observation_immutable` freezes
`normalized_payload`. **That objection is half right**: the guard prevents
*updates*, and no trigger fires on delete — but foreign keys do, which is what
refused `0139`'s first draft. See the YouTube section.

**Live defect:** scorer 0.7.0's co-attestation rule shipped reading
`bool_or(subscription) and bool_or(liked)` across all mappings for a concept,
which promoted `concept:fashion` (0.190) and `medium:television` outright on
incidental tags from *unrelated* channels. Fixed in the repository to intersect
on channel id; **not deployed**, and both assertions are still eligible in
production.

### The schema, and who may reach it

- **Two namespaces, and the distinction is load-bearing.** The reference chain
  uses `private` for its own objects; this app already owns that schema
  (`push_config`, `notify`, `collaborators`). Every semantic object is
  **`semantic_private`** here. **The hazard when adapting a reference migration
  is the grant, not the revoke** — reference `002` grants `service_role` broad
  access to everything in `private`, which here would widen access to the push
  secret and to `collaborators`. **No executable statement in an adapted
  migration may name `private`.**
- **`semantic_private` has RLS on and no policies anywhere.** Access is decided
  by role grants and `security definer` functions instead. Adding the first
  policy costs that sentence, so it needs an argument.
- **Two identities, and neither may become the other.** `semantic_ingestor` can
  call exactly one `security definer` function and holds **zero table
  privileges** — leaked, it writes vault rows and reads none back.
  `semantic_worker` is `bypassrls` with an **enumerated** grant list, nothing
  outside `semantic_private`, asserted from the catalog at migration time.
- **`0043` grants `on all tables in schema semantic_private`, and `on all tables`
  binds at execution time**, so every table a later migration adds gets no grant
  unless that migration grants it explicitly.
- **When a migration needs a grant, read `pg_trigger` for the tables being
  written and follow what each trigger calls.** Five migrations each cost a
  deploy and a run to learn one statically-knowable fact.

#### The append/change-only path, run for the first time (2026-08-17)

The rule — *the device replaces, the server appends, and only changes are
stored* — had never been exercised from the app against a real source. Every
source on the live account had been distilled exactly once.

Apple Music re-distilled on a physical iPhone against a 1,208-row library:

| data_type | rows appended |
|---|---|
| `recommendation` | 96 |
| `playlist_item` | 3 |
| `recently_played` | 1 |
| `library_song`, `album`, `artist`, `heavy_rotation`, `rating` | **0** |

**100 appended, 0 identical to any existing row**, 97 items never seen before and
3 whose content had changed. The stable library re-uploaded nothing, which is
exactly what the comparison is for and what a naive implementation would have got
wrong by 1,208 rows.

Worth noting for the retention question: **96 of the 100 are `recommendation`,
which carries `action_weight` 0.000.** The growth term is dominated by the one
data type deliberately weighted at nothing — Apple's suggestion rather than the
person's act — so repeated distillation accumulates rows that no score will ever
read. That is correct capture under *capture broadly, promote narrowly*, and it
is also the strongest argument for the retention rule this project has not yet
written.

#### The restore path, run for the first time (2026-08-17)

`RestoreService` had only ever been read, never exercised on a device that did
not already hold the data — and that device is also the reviewer's first launch.
David's account was signed into a freshly installed simulator: **it went straight
to the garden and Memories drew terms.** No onboarding screen appeared, which is
the whole of the test, since `loadProfile` runs inside `restoreSession` and has
to supply all six facts `onboardingStep` branches on before the route is
computed. All six were present on the server.

Two smaller things fell out of it, both recorded as gaps rather than fixed:

- **Nine duplicate `user` rows.** `flirt_level` and `response_time` are pushed
  three times in one batch, and since a batch shares one transaction timestamp,
  `append_source_records` compares each row against the *pre-existing* latest and
  never against its siblings — so all three insert. The function is behaving as
  designed and the caller is not. Confined to `source = 'user'`: zero duplicates
  across `apple_music`, `youtube`, `health`, `music_library` and `apple_calendar`.
- **A slider's position does not survive a new device, only its band.**
  `public.users` holds `Medium` and `Allegro`; the continuous value lives only in
  a `distilled_records` row, so a clean device re-derives it from the band
  default. `gender_preference` moved the other way and was *corrected* — the
  14 August row said `female` while the profile column has said `male|female`
  throughout, so the restore replaced a stale record with the true one.

**It did not close the append/change-only question.** Every real source on that
account was distilled exactly once, all inside one minute on 15 August, so the
comparison has still never run against a second distillation of the same library.

#### Where recording evidence actually aggregates (measured 2026-08-17)

The recordings clear no bar themselves — 1.31 observations each, strongest 0.148
against 0.25. The question that decides whether the ISRC work was worth having is
what happens when that evidence is rolled *upward*, and the answer differs
sharply by level. All four measured with `√w` damping, so one album cannot behave
like forty independent pieces of evidence.

| rolled up to | result |
|---|---|
| **creator** | **0 new crossings.** 99 (user, creator) pairs reached, 34 already above the bar. Redundant, not additive |
| **genre** | **8 new crossings**, each backed by ≥2 independent artists |
| **album** | 254 distinct albums, only 19 with ≥2 recordings, 6 with ≥4. Weak, and no album identifier exists to key them on |
| **franchise** | 0. No game-soundtrack credit in the cohort |

**Creator is redundant because the same library yields the artist's name to the
lexical route directly.** A recording points at a creator that was already found;
the two crossings it produces under *linear* accumulation are exactly what the
damping exists to refuse, since one creator has 33 recordings.

**Genre is the level that pays**, and the terms are specific rather than
containers:

    genre:baroque             29 artists   0.753   (was 0.089)
    genre:oratorio            24 artists   0.735   (was 0.000)
    genre:violin               5 artists   0.559   (was 0.089)
    genre:solo_instrumental    3 artists   0.549   (was 0.000)
    genre:dance                8 artists   0.405   (was 0.000)
    genre:piano                4 artists   0.343   (was 0.000)
    genre:chamber_music        2 artists   0.255   (was 0.000)

That is a coherent and recognisable picture of a classical listener, and the
existing path scored every one of them at or near zero. **Genre is stated at the
recording level and the artist-level mint never saw it** — `0202`'s nine stated
artist genre strings resolved to nothing, while recording genres yield 48
distinct strings matching 37 concepts.

So the conclusion is narrower than "recordings are not worth having": *a recording
is not a trait, and it is excellent evidence for one.* The unit is too fine to
assert and the right size to aggregate — and it aggregates to genre, not to
creator.

One blemish to fix if this is built: `genre:apple_19` crosses at 0.272 and is an
Apple genre id with no name, which should not be assertable.

#### The ISRC route, and what it measured (`0213`–`0218`)

Song titles were the largest block of unresolved evidence in this database —
1,422 distinct strings — because nothing mints a non-game work. The exact lane
put a number on it once it ran: **2,362 eligible mentions, one resolvable.**

The route: an ISRC on an observation joins to a `recording:isrc_*` concept
through `external_concept_links`, and writes an accepted `provider_id` mapping
that the existing scorer and Memories already consume. Deliberately *not* the new
overlay — the mature path already reaches a surface, so a resolved recording
becomes confirmable and strikeable with nothing new built to show it.

- **Identity is the ISRC; the title is a label.** 560 recordings carry 551
  distinct titles, so minting by title would have merged nine pairs in the first
  batch. No `concept_labels` row is written at all: the name lives in
  `preferred_label` and the concept is reached through the link, because adding
  560 titles as active aliases would raise the published label set by a fifth and
  make ambiguity the dominant failure of a resolver that cannot yet be told which
  family a mention wants.
- **Nothing is inferred from an ISRC beyond the recording.** No abstract
  `music_work`, no `recording_of`, no album, no `performed_by` — a cover, a
  remaster and the original are three ISRCs and one work, and the batch cannot
  tell which is which.
- **The catalogue had to be taught to keep the name first.** Song entities were
  labelled with their genre list — 2,329 of them called `"Pop, Music"` — because
  when genre inference was the only purpose the title was surplus, and
  `emit_songs` said so. Storing the field was not enough: `SELECT_MISSING_ISRCS`
  decides completeness by testing for a *key*, so `name` had to join that test or
  1,513 stale rows would have looked finished forever.

**Three defects between writing the route and running it, and the difference
between them is the lesson.** A missing grant named itself as `42501` and a
`candidate_rank` of 0 as `23514` — both from the per-handler diagnostic added
hours earlier. The third produced no signal at all: a `str` tested against a set
of `uuid.UUID` skipped all 736 eligible observations while the run reported
success and wrote 9,841 other mappings. Every query it depended on returned
exactly the right rows. It is the only one that cost real time.

`0218` and the bucketing in `resolve_user` are the response — see the rules in
`CLAUDE.md`.

**The measurement, which is the point.** 731 accepted mappings across 560
recordings, every gate passing. Each recording is attested by **1.31 observations
on average**, at most 3, and the strongest scores **0.148** against a work bar of
0.25. **Nothing surfaces, and nothing is close.**

That is not the route underperforming — it is what a recording *is*. A creator
accumulates across everything they touch; a work is attested only by its own
songs; a recording is held once. The 993 ISRCs still without a concept would add
993 more concepts each attested about once, so vocabulary growth does not change
the shape.

**So recordings probably do not belong in the versioned ontology.** 560 concepts
took the published set from 2,961 to 3,521 revisions and every publish copies all
of them; they scale with libraries rather than with vocabulary; and they clear no
bar. Shared provisionals are the better home, and this is the number that says so.

#### Account deletion was broken for every account (`0204`)

`delete-account` deletes the `auth.users` row and lets the cascade do the rest.
**Six `before delete` guards on `semantic_private` tables sat in that cascade and
refused unconditionally**, and all three live accounts held rows behind them —
58,789 `ingestion_run_items`, 9,712 `current_source_items`. A row trigger fires
on a cascaded delete exactly as on a direct one, so the first guarded child row
raised and the whole erasure rolled back.

Five predated `0203`; `0203` added the sixth. `0166` met the first of them and
read it correctly at the time — *"refuses every operation that is not an
`INSERT`, with no escape hatch of any kind"* — and concluded to redact instead of
delete, which is right for `forget_distillation`, a call that keeps the account.
It is not available to account deletion, where the `auth.users` row genuinely
goes.

- **The house had already solved it once**, in `guard_healthkit_grant_delete`:
  refuse while `auth.users` still holds the owner, permit once it does not. The
  parent row is deleted before its cascade fires. It needs no flag, no privileged
  procedure and no grant — a `security definer` erasure path would be a fourth
  mechanism where the schema has one, and a GUC a fifth that every future
  deletion path has to remember to raise.
- **The triggers were only half of it.** `ingestion_run_items` held
  `(observation_id, user_id)` and `(raw_source_record_id, user_id)` with no
  `on delete` clause and no `deferrable` — `no action`, checked immediately — so
  an erasure reaching `observations` first would raise a foreign-key violation
  with every trigger behaving perfectly. Both are now deferred, matching what
  `observations → ingestion_runs` has always done.
- **Proven against a real deletion.** The probe builds a throwaway account with a
  miniature vault, asserts each guard still refuses a direct delete, then deletes
  the account and asserts nine tables are empty — inside a block that unwinds, so
  it re-runs on every replay and leaves nothing behind.

#### The chain replays from empty again (`0173` and seven others)

`tools/replay_contracts.sh` had been stopping at `0173` since it landed, with
`unreplayable_migrations.txt` empty — so **`0174` through `0205` had never been
applied to a fresh database.** Thirty-two migrations.

Every one of the eight failures was the same disease in a different costume: a
migration asserting the *precondition* it was written for rather than the
*transformation* it performs. `0185` compared HealthKit against 1202. `0191`
demanded four minted genres. `0192` named an ingestion run by uuid. `0180`
required a catalogue-minted creator. **The repair is always to ask what must be
true when the input exists**, which answers on an empty database and on
production alike.

Two findings fell out that were not that:

- **`0174` never ran in production.** It and `0181` both mint
  `ontology_first_resolver` 0.10.0 from 0.9.0 and collide by construction; the
  live 0.10.0 row carries `0181`'s parameter and not `0174`'s. It is marked
  applied in the ledger — repaired there on evidence (*"resolver 0.10.0 is
  active"*) that `0181` satisfies equally well. The substance shipped anyway,
  in the Python package: 12,787 of 12,803 `top_track` observations are mapped.
  `0181` now merges rather than inserts, and `0205` records the missing
  parameter, because **parameters live on the model row where a later reader
  looks**.
- **`0180` minted a concept with no revision.** Its work concept was created
  unconditionally while its revision was copied *from* the creator being
  deprecated, so where that creator did not exist the concept landed with no
  revision at the published version and the parent edge failed its foreign key.
  A concept with no revision is invisible to every reader that joins through
  `concept_revisions`, and permanent.

#### The five drafted hubs are published (`0206`, ontology 0.33.0)

Ten of fifteen hubs were `active` and five had been `draft` since `0044`, whose
`definition` column records why: *"Not directly observed in the current V1
sources"*, *"Candidate hub"*, *"Confirmation-only in V0"*. `hub:games_play` was
drafted for the same reason and has since been activated, which is the precedent.
Two of the five now have children.

- **The contract named one of them**, so the live-database gate had been
  reporting `hub:nature_outdoors` as missing from the ontology. It was not
  missing; it was unpublished.
- **`0198`/`0199`'s hub assertion was blind, not violated.**
  `semantic_private.concept_block` climbs `broader` edges filtered on
  `edge.status = 'active'` and never reads the *hub's* revision status, so 36
  Wikidata crafts satisfied "every imported concept reaches a hub" under a draft
  one. `0206` asserts the stronger thing — no active concept files under a hub
  that is not active — which would have failed before it.
- **Publishing changes `status` and nothing else.** `work_study_making`,
  `social_community` and `daily_rhythms` stay `private`, and their
  `explicit_only` / `review_required` policies stand. A container becoming
  available to file terms under is not permission to assert anything about a
  person, and `never_asserted_kinds` has included `hub` since `0092`.
- **The cost was stated before it was paid**: 145 eligible assertions are stale
  until the worker runs, and Memories goes blank rather than stale, which is the
  design. 760 external concept links carried forward — the table the standard
  copy-forward pattern omits and which `0179`/`0180` both dropped.

#### The candidate overlay's sixteen stores (`0203`)

The execution specification's `required_storage_objects`. Fifteen were created;
`observation_mentions` already existed. **Nothing reads or writes them yet** —
`semantic_qwen_overlay` is false and eight of the nine pipeline jobs are not in
the `worker_jobs` allowlist, so this is the `storage_integration` gate's subject
rather than its pass.

- **The contract calls them `private.*` and that name is taken.** Same crosswalk
  hazard as the reference chain, arriving from a second direction: the compiled
  contract was authored against a schema layout where `private` is the semantic
  one. Resolving it literally would have created thirteen tables beside
  `push_config`. `STORAGE_SCHEMA_CROSSWALK` in the compiler is the one place that
  maps it, and `--check-database` reports the production name *and* the declared
  name in every failure, so a reader is never sent to the wrong schema.
- **Composite foreign keys carry `user_id` throughout.** `(observation_id,
  user_id) references observations(id, user_id)` rather than `observation_id`
  alone: the constraint proves tenancy instead of a query remembering to.
  `observation_mentions` predated the pattern with only `primary key (id)`, so
  nothing could reference it that way — `0203` adds the missing
  `unique (id, user_id)`, additively and with no rewrite.
- **Derived state cascades; vocabulary restricts.** These are candidates and
  presentations, not evidence. When the evidence goes they must go, or
  `api.forget_distillation` leaves a profile standing on rows that no longer
  exist — the same defect as *Disconnect all* emptying four tables and naming
  none of the ones Memories read.
- **`model_invocations` has no column that could hold provider text.** Hashes,
  versions, token counts, latency, status and a stable error *code* — never a
  message, because a provider's error string can quote the input it choked on.
  §20.1's rule is kept by giving the text nowhere to go rather than by anyone
  remembering not to write it.
- **`review_items` and `review_exposures` refuse update and delete by trigger**,
  proven in the migration against a temporary table carrying the same trigger
  (`0200`'s probe shape) rather than by reading the function's source. A check on
  a function's text is not a check on its behaviour.
- **`candidate_relation_proposals.traversable` is false unless the row is
  `verified_relation`, enforced by check constraint.** An inferred `about` edge
  that could be walked is how a model proposal becomes a fact nobody accepted.
- **`user_term_candidates` keys one active card per (user, term, predicate) and
  `review_epoch` is deliberately not in it** — the epoch belongs to immutable
  exposure history, and putting it in the key would make the same term reappear
  as a second live card every review round.
- **The advisors report exactly fifteen `rls_enabled_no_policy` notices and
  nothing else.** That is the posture, not a finding.
- **`provisional_entities.family` restates the 23-family vocabulary as a check
  constraint**, which is a second copy of a fact the contract owns — this
  repository's recurring defect. It is permitted because a check constraint is
  the only mechanism the database has, and made safe by `--check-database`
  reading it back and refusing to agree the contract compiles if the two have
  drifted in either direction.

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
- **It applies `SyncService.isLocalOnly` before deriving anything**, the single
  most important line in it: `health/biological_sex` never leaves the device, and
  a second upload path is precisely how such a promise stops being true without
  anybody deciding to break it. The rule is *asked for* rather than reimplemented.
- **Refusals are counted, never swallowed.** An unmapped `data_type` would
  otherwise show up as a batch quietly smaller than the distillation it came
  from.
- **A permanent refusal is dropped, not retried; 401 is transient.** A malformed
  batch fails identically forever, but an expired token means the batch is fine.
  **A projection refusal is a 4xx**: sent as 500 it is retried forever at the
  head of a FIFO queue, starving everything behind it.
- **Enabled per source** (`AppConfig.semanticIngestionSources`), never per build
  — a disagreement found in one source is a diagnosis, and in nine it is a shrug.
  **Dual-write excludes YouTube and Spotify on licensing grounds.**
- **Two translation seams, and only two.** `SemanticSource.appSourceCode` maps
  `health` → `healthkit`; `semanticDataType` maps calendar rows to
  `calendar_event`/`scheduled`. Both are pinned by a test that also asserts
  **nothing else is translated**. Renaming either side would rewrite history in a
  table that is append-only by design.
- **The vocabulary is checked from both ends, because neither end can see the
  other.** `semantic/tests/test_ios_envelope_contract.py` reads the distillers
  and fails if a `data_type` is unmapped; `tools/replay_contracts.sh` asks the
  *built* schema whether each claimed action is one that source actually weighs.
- **`actionsByDataType` has three answers, and the middle one is the point**: an
  action the server weighs, a real signal it does **not** weigh yet, or
  structurally not an act. Collapsing the middle into the last is how the list of
  things still owed a decision disappears. Five sit there: `heavy_rotation`,
  `library_music_video`, `top_track`, `top_artist` and `location/place`.
- **`SourcePayload+Legacy.swift` is scaffolding and is meant to be deleted.** The
  end state is distillers emitting `SourcePayload` directly.

### Capture against promotion

- **Capture must not depend on promotion.** `0055` could roll back a whole
  captured batch when the finalizer refused a run with no scope; `0056` finalizes
  only when the run has one and otherwise leaves it `running` and inert.
- **A scope is `(source, data_type, action)`, because
  `ingestion_run_scopes.action_type` is `not null`.** A row with no action
  belongs to no scope, gets no run item and is never promoted — a `user/bio`, a
  calendar container, the subscription flag. *Capture broadly, promote narrowly*
  falls out of the schema rather than being imposed on it: 1,224 promoted against
  1,225 captured, the difference being one subscription-state row.
- **`partial`, never `complete`.** Only `complete` licenses expiring an item that
  went missing, and every Apple Music read is capped — so claiming a complete
  snapshot would be inferring absence from omission, which §10 forbids. It is the
  difference between a bad afternoon for one connector and somebody's library
  disappearing.
- **A duplicate still needs a run item.** The insert is `on conflict do nothing`,
  so a duplicate returns no id — but the item was *seen* this run, and a head
  that missed it would read as the item having gone away. Resolve ids by lookup,
  not only from `returning`.
- **Evidence is written by ingestion, not by the worker, and the schema decided
  that.** `guard_observation_ingestion_run` refuses any observation whose run is
  not still `running`, while finalization enqueues the worker *after* the run
  closes. No grant fixes it. Classification belongs where the plaintext already
  is — and a worker that could update a run could mark somebody's capture
  complete.
- **A run that promoted nothing is finished, not running**, and this is
  structural: **every `user` distillation produces one**, since every `user` data
  type is `notAnAction`. `failed` would be a lie, and the finalizer cannot be
  used because it refuses a run with no scope manifest by contract. Hence
  **`close_unpromotable_ingestion_run`**, never an `update`: the function refuses
  a run that *has* a scope, and a migration that knows better than the guard is
  how the guard stops meaning anything. It raises its own flag
  (`written.close_unpromotable_v031`) rather than impersonating the finalizer's,
  so any trigger exempting one must be taught the other.
- **The whole row speaks the schema's language.** `guard_ingestion_run_item_v031`
  requires the raw row's `data_type`, the observation's and the scope's to be
  equal, so an observation cannot hold a vocabulary of its own — which is why the
  calendar rename had to happen on the device. **Renaming a `data_type` re-stores
  every row** (it is part of the fingerprint) **and orphans its current items**,
  since a `partial` scope licenses no expiry. `current_source_items` holds 202
  for `apple_calendar` for that reason; it is inert history.
- **The fingerprint must not depend on the encoding.** `fingerprintContent`
  unwraps the payload's discriminator and drops `schema_version`. Never reduce an
  unrecognised payload shape to a subset of its keys — `{title}` and
  `{title, playCount}` hashing alike means a changed record is skipped as a
  duplicate and lost.
- **`schema_version` is `written-source-envelope-v2`, v1 rows exist forever, and
  a reader must handle both.** The vault is append-only and the ingestion
  identity has no `Decrypt`, so a row's encoding can never be rewritten.

### Reading the vault

- **Read `current_source_items`, never `raw_source_records`.** Nothing
  supersedes a prior revision — a row whose payload changed is captured beside
  the old one and both stay `active` — and `ingest_healthkit_rows` quarantines
  **both** sides of a lineage whose fingerprints disagree. Same rule as reading
  through the `summary_*` views, one layer down.
- **Comparing the vault against the legacy path compares two different
  things.** `distilled_records` is append-only, its summary views are a *union
  across runs* rather than a snapshot, and the legacy path stores only *changes*.
  The comparison that means something is the **second** distillation.

### The revision, and what may move it

**`api.list_assertions` withholds every *inferred* assertion whose score was not
computed at the account's current revision** — the difference between a claim
about somebody and a claim about who they used to be. It is also why **the
Memories page goes blank rather than stale**.

**The revision means *"which version of the inputs were these scores computed
against"*, so it moves when the scorer's inputs move — not when state changes.**
Three migrations were needed to get that sentence right, and the shape repeated:
**a trigger fired on something that looked like a change and was not, and the
cost was every score the person had** — closing a zombie run (`0104`), a
suppression emptying the whole page (`0111`), and then exempting `explicit_add`
the wrong way round (`0113`), where *adding a term deleted the page and left the
term*, a declared assertion having no observations and being **exempt from the
currency check by construction**.

`0115` is the current answer and a trade rather than a settlement:

| action | bumps | why |
|---|---|---|
| `suppress` / `restore` | **yes** | redistributes weight; the score really changed |
| `confirm` | no | nothing reads it yet |
| `explicit_add` | no | no observations, no mappings, never scored |

**The revision is monotonic and is never walked back** — an earlier value would
be a lie about what has happened — so the repair is always to re-score at the
revision that now stands.

### Classification and scoring

- **The Calendar classifier is its own Lambda** — `written_ontology.calendar_
  semantics` vendored, not ported. **Titles go in and do not come back**: the
  stored payload is at most four keys, and a test asserts no fragment of a title,
  address, organiser or email domain survives into it. Its IAM role holds
  `kms:GenerateMac` on the lineage key and **nothing else**, and the lineage
  signer is **salted per user**, because `content_lineage_hmac` exists to be
  joined on and an unsalted digest would be a cross-account correlation handle.
  **A classifier failure must never fail a distillation**; `CALENDAR_CLASSIFIER_ARN`
  unset is a deliberate off switch.
- **`_FLIGHT_TITLE_RE` matches the canonical title and nothing else.** "Flight to
  Los Angeles" is `excluded_unknown`, and the space in `(UA 1103)` is
  load-bearing since `[A-Z0-9]{2,3}` is greedy. An event is excluded unless
  positively recognised — the allowlist is the design, not a gap.
- **Deploying resolver or scorer code re-scores nothing.**
  `semantic_run_live_identity_idx` keys a run on the user, ontology version,
  model ids, input revision and input hash — **the code version is not in it**.
  Three levers force a fresh run: a new distillation, a new ontology version, or
  a new model id. So the parameters live on the model row where a later reader
  looks, not in a commit message.
- **Retire the old version in the same migration; never leave two active.**
  `finalize_ingestion_run_v031` picks the newest *active* model by `created_at
  desc`, so leaving both works by ordering, which is a coincidence rather than a
  statement. **Retirement is not deletion** — `on delete restrict` protects the
  runs pointing at it.
- **A model version and the recompute it implies belong in one migration.**
- **A rule that only withholds arrives too late for exactly the rows it was
  written for.** `0092` promoted a scorer that refuses to assert hubs and the
  three hub assertions already standing came back untouched.
- **A suppression is an `ambiguous_rejection`, and redistribution is
  disambiguation rather than a negative.** Liking a song admits three readings —
  singer and song, singer only, song only — so striking off the singer leaves the
  weight to whatever else the row names. Nothing asserts a dislike;
  `user_suppressions` stays empty and is where a real negative would live.
  **Freed weight goes to a *different named role on the same row*** — `creator`,
  `composer`, `source_work` — apportioned by existing weight, **never to the same
  role** (striking one cast member would promote the other five, identically
  ambiguous) and **never to genre, era, scene or sphere**. **Conservation rather
  than a constant**, applied before saturation. Writing it in the resolver's
  *roles* rather than in `concept_kind` is what makes classical and pop one rule.
- **A scene's decade and sphere must come from the same row.** Deriving one per
  row and the other per artist let a 1998 Japanese single reach
  `scene:1990s_anglophone` through two rock tracks recorded twenty-eight years
  later. The bare `era:*` term stays artist-level, a decision rather than an
  omission. **An era is an axis; a scene is the claim** — `era:*` and `sphere:*`
  are scored and never asserted, through `NEVER_ASSERTED_KEY_PREFIXES` rather
  than by kind, since all three families are `concept_kind = 'topic'`. **A marked
  genre silences the unmarked ones on its row** (Apple writes `Mandopop|Music|Pop`)
  while the union across *rows* survives, so a bilingual act keeps both.
  **Classical periods are never crossed with a sphere.**
- **Match labels are `alternate`, not `preferred`.** The resolver emits the bare
  key suffix, so a prose `preferred` label never meets it. Auto-accepting alias
  types are `preferred` and `alternate` only.
- **Mint no vocabulary from `recommendation` rows.** They carry `action_weight`
  0.000 because they are Apple's suggestion rather than the person's act.
- **Authored vocabulary is minted whole, not on demand** — the full decade ×
  sphere cross-product exists whether or not a library produces the pair, or the
  concept set would differ per install. `EmergentTermMiner`'s five-user floor
  stops one person's private string becoming a public concept and has nothing to
  say about a closed authored list.
- **`unicodedata.normalize("NFKD")` decomposes a Hangul syllable into jamo**, so
  a key accepting only precomposed `가-힯` strips every Korean name to empty.
  That alone was survivable; **what merged nine artists into one concept was a
  *constant* fallback. A fallback key must not be able to collide.** Correcting
  such a merge **does not rewrite history**: the old concept keeps its id and
  mappings, since those record what the resolver actually did, and is deprecated
  with its labels withheld; the assertion resting on it is retired `inactive`.
- **A migration that publishes an ontology version or activates a model ends with
  `semantic_private.enqueue_recompute_on_analysis_change`.** Ingestion is the only
  other thing that enqueues, it fires only when a run changed something, and it
  cannot see a model publish.
- **Invoke the worker serially**, and run psycopg with **`prepare_threshold=None`**
  — the transaction pooler hands each transaction to whichever backend is free,
  so an auto-prepared statement fails `42P05` on the second of two back-to-back
  invocations, for one account and not the other.
- **`exact_terms_only`: no fuzzy matching.** `resolve_alias`'s `SequenceMatcher`
  fallback consumed a whole 300-second Lambda timeout on arbitrary uploader tags,
  and every result was discarded anyway since the fuzzy path returns only
  `CANDIDATE` or `REJECTED`.
- **`strength` saturates as `w/(w+6)` rather than summing**, because one concept
  carries 3,893 mappings and a hard cap would tie every strong concept at 1.0.
  **`stability` is 0.0 on a first run and that is a refusal** — 1.0 would assert a
  property from the absence of observation. The curve is nearly flat at the top,
  so **a percentage cut cannot demote anything**; weights are chosen against the
  0.35 eligibility bar.
- **The scorer withdraws as well as raises.** Scored-and-no-longer-eligible is
  demoted in the loop; never-scored-at-all is swept afterwards. Both are
  `assertion_origin = 'inferred'` only — a declared assertion is what a person
  said about themselves — and **the sweep is guarded on the run having scored
  something**, since a fallen-over resolver must not read as somebody who likes
  nothing. A unit test asserts **which statement ran**, because the bug was never
  in the arithmetic.
- **A classical performer is weighed by distinct albums, not rows.** One album
  means the performer came with a recording; several means they were chosen.
  Below two albums the credit is weighed `0.02` rather than dropped, because the
  term still has to exist for `EmergentTermMiner`. **`_is_classical` falls back to
  a catalogue number only when no genre is stated at all**, and a composer prefix
  must *be* the prefix — `Part`, `Glass`, `Reich`, `Berg` and `Ives` are waiting.
- **Assert resolvability, not counts.** `0095` minted 35 concepts that could
  never resolve and its own assertions passed, because counting the right number
  of unreachable things is what a structural check gets wrong.

### The surfaces

- **Two switches, and they are not redundant.**
  `AppConfig.semanticSurfacesEnabled` decides whether the app *asks*;
  `memories_reads` decides whether the server *answers* and is §9's rollback
  contract, throwable without a release.
- **The `api` schema is exposed by hand** — Settings → API → Exposed schemas, no
  migration can do it. Unexposed, every RPC answers `PGRST202` naming
  **`public.list_assertions`**, which reads as a missing function.
  **`PostgREST.callFunction` sends both `Content-Profile` and `Accept-Profile`**,
  because an RPC is a POST that reads and setting one sends half the calls to
  `public`.
- **An answer must name the exposure it answers.** `suppress_assertion` and
  `confirm_assertion` require a matching `record_assertion_exposure` — "I
  disagree" refers to a particular label at a particular rank computed by a
  particular score version. A `uuid`-returning RPC answers a top-level JSON
  fragment, which `JSONSerialization` refuses by default.
- **`list_assertions` is an allowlist of `concept_kind`** — `creator`, `work`,
  `activity`, and since `0197` `topic` less the `era:`/`sphere:`/`scene:` key
  prefixes — so a new kind is withheld until somebody decides it belongs. An
  internal kind appearing on a profile is worse than a nameable one being missed,
  because only the first is invisible to whoever added it. **A user's own term
  always survives it**, having no concept and therefore no kind.
- **YouTube may raise a concept's strength and may never be the only reason it
  crosses to another user** (`0117`, corrected by `0118`). Of 1,139 concepts
  scored, 56 are touched by YouTube: 26 have another witness and cross, 30 are
  YouTube-only and withheld. "Concepts are ours so anything goes" is the wrong
  answer — a concept only YouTube witnesses still discloses YouTube data, because
  the subscription list is the only way it could be true.
  `semantic_private.concept_has_non_video_witness` is the test: if a non-YouTube
  source attests it, **the identical row would be published with YouTube
  disconnected**. It reads `observation_mappings → observations →
  sources.independence_group` and requires `mapping_state = 'accepted'`, a
  candidate being a fuzzy near-miss the scorer discards. **`0117` read
  `concept_source_scores`, which the contract defines and nothing populates, so
  it answered false for everything and its own assertion was guarded on that
  table being non-empty and skipped.** *A check that can be skipped will be
  skipped exactly when it is needed*; `0118`'s assertion instead demands the
  predicate answer both true and false over real data. YouTube still supplies the
  second independence group, which no music source can. **No gate is opened** —
  `allow_bio`, `allow_icebreaker` and `allow_cross_source_fusion` stay false.
- **The work bar is 0.25 against creators' 0.35, and it is a judgement.** A
  creator accumulates across everything they touch while a work is attested only
  by its own songs, so the same strength means more evidence. One library, one
  reviewer.
- **The flag check lives inside `assert_surface_allowed`**, not beside it — five
  `api` functions already call that guard, and a parallel check is how two tests
  that must agree stop agreeing. It is **`stable`, never `immutable`**: a flag
  lookup reads tables, and an `immutable` function may be folded at plan time,
  which for a guard means evaluated once and never again. The kill switch comes
  free.
- **A check on a function's source text is not a check on its behaviour.** This
  has shipped twice — `0095` counted 35 unreachable concepts, `0102` asserted a
  guard *mentions* the flag function. `0103` is the shape to copy: flip the flag,
  call the guard, assert the answer changes in both directions and with the kill
  switch down, then restore every flag and prove that too, inside the migration's
  transaction so it re-runs on every replay.
- **Rewriting a reader to add a guard drops what is at the bottom of it.**
  `0102` pasted `list_assertions`' body from `pg_get_functiondef` and lost the
  `order by`; its own assertion checked the column *count*, which cannot see
  ordering. **Memories draws in the order it is given**, so an unordered read
  showed somebody their fourteenth-strongest trait first. Found on a device.
- **A verdict attaches to the assertion, never to the run.** `user_assertions`
  rows are stable — keyed on `(user, predicate, concept)`, a re-score updating
  `machine_state` — so a review survives any number of re-scores.
  **`assertion_reviews` and `assertion_preferences` are two facts in two tables
  on purpose**: a reviewer's *"this claim is wrong"* is diagnostic, a user's
  *"don't show me this"* is product, and one column for both means a diagnostic
  judgement silently becomes a hide.
- **`-probe-surface 1` proves the read half and needs a device.** It reads and
  never writes, unlike `-probe-ingest`: confirm and suppress are somebody's own
  answers about themselves. **`-probe-ingest 1` writes a real encrypted row
  deliberately**, since a probe that avoided writing would leave the write path
  unproven. Run it twice — the second receipt should read `stored 0,
  duplicates 1`.

### Where the pipeline stands

**Phase 2 closed 2026-08-12 on two accounts**; §8's four bullets are satisfied.
`semantic/JOURNAL.md` records what each involved.

**65 active assertions per account over ~6,650 scores**, from 2,417 music
observations and 101 calendar events. Thirteen concepts reach two independence
groups, which `motif_rules` requires as a check constraint and which nothing in
this system had ever had — so until then every motif rule was unsatisfiable by
construction. `creator:le_sserafim` at 0.684, across Apple Music and nine YouTube
repost channels, is the shape the exercise was for: the music sources all carry
the `music` group by design, so no music source can be the second witness.

**HealthKit classifies and correctly produces nothing**: 390 accepted, **0
rejected**, 366 activity days, 24 hours, coverage `aggregate_only`, zero habit
candidates — what §10 requires when every `activity:*` concept derives from typed
workout sessions and no test device has an Apple Watch. `rejected = 0` is the
load-bearing number, since `_parse_activity_day` refuses a row it recovered
nothing from. **Calendar promotes 5 of 101**; the 68 `excluded_unknown` is the
allowlist working rather than a gap.

Two things about reading any of it. **The vault cannot answer "what was promoted
and why", by design** — the payload is four keys and no title, and
`source_item_hmac` is salted with a KMS key only the classifier's role may use —
so `tools/calendar_review.py` re-derives each decision from the legacy row with
the same classifier and catalogs, and a test pins its constructor arguments
because a missing catalog would silently reclassify. And **anything counted off
`distilled_records` counts history**: that tool reported 9 promotions against the
vault's 5 for exactly that reason.

**Three works are judged and the bar honours all three** — Footloose in at 0.266,
BanG Dream! out at 0.237, Re:Zero out at 0.047 — which is what moved the work bar
to 0.25. Still one library and one reviewer.

### The dynamic profile

The official way one match presents themselves to another — distinct from the
dynamic *bio* (a line on a discovery card) and the *icebreaker* (a tip in a
thread). Laid out like an Instagram account, with three figures where posts /
followers / following sit: a follower count is a claim about how many people know
you, while these are what somebody's attention is made of.

**Reachable from exactly two places** — the avatar on an invitation
(`AdmirerRow`) and on a chatroom banner (`ConversationView`) — and **the rule is
in Postgres, not in which buttons exist**. `match_profile()` is `security
definer` and returns rows only to somebody holding a like *from* this person or a
conversation *with* them. A page reachable from two buttons is a drawing; a
function that returns nothing is a rule.

**`0122` made that gate consult state.** The like clause tested only that a row
existed, so **declining an invitation left the sender's school and bio readable
to the person who declined it, permanently** — exactly the two fields kept off
`discovery_cards` on purpose. Now `pending` (an open invitation is the *reason*
the page exists) and `accepted` authorise; `declined` is history. **The
conversation clause is untouched and is the second place blocking will have to be
consulted** — `conversations` carries no ended state, so its existence *is* the
current authorisation.

**The split is by how identifying a field is.** Name, age, district, photographs
and the ontology mix are on `discovery_cards`, which every signed-in account may
read. **The school and the bio are not, and must not be.** Anything added to this
page has to be sorted into one of those two piles before it is drawn.
**`match_profile` returns zero rows for a refusal *and* for a match who filled in
neither field, deliberately** — distinguishing them would tell a caller whether
an account exists.

**`-probe-match <uuid>` exists because no screen can check this**: declining
destroys the admirer row while creating no conversation, so the state has no
button left to press, and the direct RPC call is what a rule must defend against.
**The RPC's answer alone proves nothing** — zero rows means both *refused* and
*filled in neither field* — so the probe prints the like and conversation rows
beside it. **Probe somebody who has a school or a bio.** Proven on a device
2026-08-12.

Two things the probe cost. An **alert is a single-shot surface**: writing
`result` twice left SwiftUI showing the first message, so the probe reported only
that it had *started*; it prints to the console as well now. And **a launch
argument only exists when Xcode launches the app** — from the home screen or the
app switcher the scheme passes nothing, so every probe silently does nothing.
All three probes share both traps.

### Phase 3: Memories draws assertions, and the legacy cards stay beside it

**Built 2026-08-12** against a surface `0048` had already shipped whole:
`api.list_assertions`, `confirm_assertion`, `add_assertion`,
`suppress_assertion`, `restore_assertion` and `record_assertion_exposure`, each
`security definer` and scoped to `auth.uid()` with no parameter for whose. Phase
3 was pointing the app at them. Rules are in *The surfaces*; `semantic/JOURNAL.md`
has the three defects of this codebase's recurring shape that made every confirm
and suppress fail silently from the moment they were written.

**The difference from the legacy cards is what a row *is*.** There a row is a
string filed under a domain `Ontology.classify` guessed at by substring, and
striking one off goes through `BanList.Kind`, which removes **every row whose
name matches** — so banning an artist also bans a YouTube channel called the
same. Here a row is a concept with an id, and `suppress_assertion` names one
assertion. The contract forbids a title ban becoming a concept-level negative;
this is what makes that true rather than merely intended.

**What the page shows is `concept_kind`**, filtered by `0108` to `creator`,
`work` and `activity` on the owner's judgement — *"the terms shown should be well
defined enough to strike off or understand"* — which took it from 65 rows to 36.
The 13 genres and 16 scenes/spheres remain asserted, scored and evidenced, and
are what Phase 4's server-owned discovery will match on. **Both readings are on
screen at once deliberately**, so the two can be compared.

### Memories is the ontology's surface

**Still drawn, and now beside the assertion card rather than alone.** Everything
below describes the legacy path.

`Ontology.terms` groups everything distilled under the domain it landed in, and
`DashboardView.domainSections` draws one card per domain. It replaced five cards
named after *sources*, which were a picture of the plumbing. **Every term is the
source's own string** — an artist, a composer, a channel, a show, an event title.
Nothing on that page is a word this app invented, which is what keeps it a
reading of somebody's data rather than labels applied to them.

**Striking a term off goes through `BanList.Kind`, never a new `.term` kind.**
`banTerm` carries a name *and* any id, dispatches to the existing kind, and lands
in `applyingBans` — so the records behind it are `markedRemoved` and stop feeding
the mix, the discovery card and the icebreaker. A ban that only hid the row from
this page would make the website's *never used, never shown, never counted*
untrue.

**YouTube goes through a different door, structurally rather than by a rule to
remember.** `Ontology.youTubeTerms` cannot reach `classify`: placing a channel
under a domain by matching a term list against its name is exactly *"infer or
estimate the content category/type of a video or channel"*. It reads `topics`,
`tags` and `category_id` out of `extra`, and a channel carrying none of the three
is **absent, not placed plausibly**. The premise usually offered for this page is
backwards: III.E.3.b forbids showing Authorized Data to *anyone other than* its
owner, so channel rows on somebody's own page are the permitted case, while
*aggregating* them is the restricted one. Two consequences: **the YouTube cards
empty themselves** as `0016` sweeps, which must never be drawn as a failure; and
**a user-editable term list derived from YouTube data is Google's Content
Categorization and Tagging feature**, while reading labels YouTube supplied is
not.

**The readings are not terms and stayed behind.** `lifestyleSection` still draws
the chronotype and the step average, because there is no entry behind "You start
at 06:40" for anybody to agree with. Sports left it — a sport is a named thing.

### Which sources may feed a model, and who may say so

**Four may, two may not, and consent does not move the line.** Apple Music, Apple
Podcasts, Apple Calendar and HealthKit carry no term restricting what is done
with what they return — Apple's rules are about the permission sheet and what is
disclosed, not about downstream use. **YouTube and Spotify both forbid it**:
III.E.4.h and IV.2.1.a, the latter naming *"train a machine learning or AI model
or otherwise ingesting Spotify Content into"* one.

**A person can grant rights over their own data and not over a platform's.**
Spotify says so outright — IV.2.5 covers derived and aggregate data *"even if a
user consents"*.

Training data comes from collaborators rather than users, which is why the
published policy needs no new purpose. **`private.collaborators` (`0041`) is how
the two are told apart** — a table in the schema nothing is granted on, filled in
by hand. A column on `public.users` would have been settable by the account it
describes (`0001`'s policy is `auth.uid() = id`), so anyone could have marked
themselves and put their own rows in a corpus. The query, source exclusions
included, is at the foot of that migration.

**`Ontology.subjects` was reading a `data_type` that has never existed** — it
filtered `dataType == "song"` while the distiller writes `library_song`,
`heavy_rotation`, `playlist_item` and `recently_played`, so it answered `[]` for
every real library and `discovery_cards.top_subjects` was empty. It reads
`MusicHighlights.songTypes` and `deduplicatedSongs` now, both internal precisely
so there is one list rather than two that drift. **The preview fixture had the
same disease in reverse**, writing `top_track`, which no distiller emits.

**Photo captions degrade subject → domain → nothing.** Two real libraries share
one or two specific things and almost never six, so captioning all six with
subjects would mean inventing four. The fallback is `Domain.sharedLine`; when
that runs out the photograph carries no caption, because a commonality that does
not exist is the one thing this feature must not manufacture. Each line is used
once.

The bio is a `user` record like education and occupation, so it owns no column
and applies locally at once. **Capped at 30 characters at the keyboard**, not on
save: a sheet that accepts forty and then refuses is a dead end that cannot
explain itself.

### The icebreaker

`0036` fills six columns on `conversations` at match time — a shared `theme`, its
`theme_kind`, a subject per side and a pronoun per side — and the app draws one
sentence at the top of the thread:

> You two both listen to J-Pop. You can talk about Ado, or ask her about Fujii
> Kaze!

**The first specific is the reader's own and the second is the partner's, so the
sentence differs per reader** — and the version shown to one must never be shown
to the other. That rules out a `messages` row twice: `sender_id` is `not null`,
so a system message has no sender, and one row is read by both participants. It
is drawn instead, which is also what makes it dynamic prompting. **The flip
happens once**, in `ChatService.conversation(from:me:)`, the only place that
already knows which side the reader is; anything downstream deciding for itself
whether `subject_a` is "mine" is a second copy of that decision, and the day they
disagreed somebody would be told to ask their match about their own favourite
band.

**Ingredients in SQL, language in Swift.** The trigger does set intersection and
knows no English; `IcebreakerCard` picks the verb, which varies by kind. Same
reasoning that keeps `Ontology.line(for:subject:)` in Swift: copy that needs a
migration to change will not get changed.

**Drawn as `DayDivider`'s pill, prefixed `Tips:`** — a day pill is the one thing
already in a thread that is *about* the conversation rather than part of it, so
matching it puts the tip in that category without a label. **It must never read
as a bubble.** `-chat icebreaker` opens the sample thread with no messages.

Four things about the trigger:

- **It must read the base tables, never `summary_distilled_records`.** Those
  views are `security_invoker = on`, so a `security definer` function reading one
  is *still* filtered by the invoker's RLS: it would find the caller's rows,
  silently none of the partner's, and never error.
- **`source <> 'youtube'` is explicit and must stay** — an icebreaker derived
  from YouTube data is derived data under III.E.4.h.
- **`before insert`, unlike `0022`'s `after`**: it fills in columns on the row
  being written.
- **It never recomputes.** Fixed at match time; stale after more distilling,
  which is accepted.

**No overlap means no card**, not a generic one. **Both pronouns sit on a row
both participants read, deliberately**: gender stays off `discovery_cards`, and
this is the narrow channel instead. Anything unrecognised is **them**, including
null, and a name is never used to guess. **It is not an embedding** — this is
overlap counting over genres, sports and creators, and it is what the ontology
stage replaces.

### The invitation becomes the first message

`0018` let a like carry a note, and once accepted that sentence had nowhere to go
— the admirers row disappeared with the like and the thread opened empty. A
trigger on `conversations` insert copies it in as a message from the liker,
stamped with the *like's* `created_at`.

**A trigger rather than app code, and that is forced.** The conversation is
created by the accepter, the message must come from the liker, and `0009` gives
`messages` an insert policy of `auth.uid() = sender_id`. The only client
positioned to write the row is the one person forbidden from writing it.

**It notifies nobody, tested by timestamp rather than a flag.** A message
carrying the like's time necessarily predates a conversation that exists only
because the like was accepted.

### An attachment with no caption

`0010` relaxed the body constraint so a photo could travel without words, and the
app satisfies `not null` with an empty string — which the notification passed
through unread, producing the sender's name and **a blank line**. It says
`📷 Photo` / `📹 Video` / `🎤 Voice message` now, and a caption still wins.

**Emoji rather than SF Symbols, and that is the medium**: an APNs alert body is
plain text rendered by SpringBoard, with no reach into the symbol set the app
draws with. The chat list uses `camera.fill` / `video.fill` / `mic.fill` for the
same three — and `ChatView.lastLine` turned out to test only for `audio`, so an
uncaptioned video called itself "Photo".

### Unread, which nothing had ever counted

`read_at`, its policy and its column grant existed since `0009` and nothing used
them until `0030`.

**The icon badge is set from two ends and needs both.** The count travels with
every message notification, which keeps it right while the app is closed — the
only time anybody looks at it — and the app recomputes on opening Chat, on
opening a thread and on each poll. A **null** badge means *leave the number
alone*, which is what a like and a match send: neither is an unread message, and
a 0 would wipe a badge correctly showing one.

**One request answers both the icon and the rows.** `unreadByConversation()`
returns a count per thread. It needs no conversation filter — `messages` is
readable only to participants, so a bare query for unread rows you did not send
returns exactly yours. RLS is doing the join.

**The band in a thread is snapshotted before anything is marked read**, because
opening a thread marks everything read, so the boundary exists only in the first
fetch. **And it is read off the fetch, never off `messages`**, which is seeded
from `ChatStore`, where a cached row with no `readAt` decodes as nil and reads as
unread.

**Opening position is bottom when the unread fits and centred when it does not**,
decided by scrolling to the end and asking whether the band survived — no height
arithmetic, and no guessing from a count one photograph would falsify. A band
`LazyVStack` never built reports nothing, which *is* the answer.

**Taps route.** `NotificationRouter` records the destination rather than acting
on it, because a tap that launches the app is delivered before `AppShell` exists.
`AppShell` moves the tab, `ChatView` opens the page, and a conversation not yet
loaded is fetched by id rather than waited for.

### Offline: the cache existed, and the failure erased it

**The chat list was empty offline, and it was not a missing cache.** `ChatStore`
held the threads all along; what emptied the screen was the fetch that followed,
which **wrote its empty answer back to `ChatStore`**.

`ChatService.conversations()` opened `guard let me = await currentUserID() else
{ return [] }`. Offline that guard is what fires — `currentUserID()` awaits
`validAccessToken()`, the refresh cannot complete, and it answers nil. The guard
against exactly this tested `lastError`, and that return path set none.
`LikeService.admirers()` had the identical opening. **The fix is the type, not
another boolean**: both return an optional now — nil for *could not ask* — so the
caller is `if let`.

Three things fell out of it, all about not asserting what was never asked:
**`hasLoaded` moves only on a real answer**; **the empty state has two
sentences**, since "No conversations yet" is a claim about an account that an
offline app cannot make (`couldNotReach` picks the other); and **no second banner
while offline**, because `AppShell`'s covers every tab and the service's own
message there is "You're not signed in" — true of the token, nonsense to somebody
on a train.

**Nothing about synchronisation changed**: the server is still the source of
truth, the cache is still replaced wholesale by every successful fetch, and only
an *unsuccessful* fetch stopped being mistaken for a successful empty one.

## Photos

`PhotoService` uploads to a private `profile-photos` bucket at
`<user_id>/<position>.<ext>`. **The position *is* the order somebody meant**, so
re-picking slot 2 overwrites slot 2, and `slots()` keeps the position that
`paths()` throws away — packing 0, 2, 5 into 0, 1, 2 would silently rearrange a
profile its owner laid out.

**Nothing uploads on edit; edits are staged and flushed on the way out.**
`PhotoGrid` takes an optional `onEdit`, and which surface passes it is the whole
difference between the two callers: onboarding waits for its Continue button,
because somebody arranging pictures may yet skip. The dashboard has no button, so
the departure is the button — `stagePhoto` records, `flushPhotos` sends, fired
from `AppShell` on leaving the tab, on the app going away, and before signing
out. The staging map is keyed by position, so the last write to a slot wins.

- **`.inactive` is what catches a force-quit**, not `.background`. A background
  assertion must wrap **the work, not the call** — taken around `flushPhotos()`
  it covered a function that returned at the re-entrancy guard while the real
  upload ran unprotected. Its expiration handler is not optional.
- **The queue survives the app**, through `PendingPhotoStore` — Application
  Support, one directory per account through `AccountScope`, because a queue
  flushed into the wrong account uploads somebody else's face. **The intent is
  the file name, not a manifest**: `3.jpg` is a pending upload for slot 3,
  `3.removed` a pending removal. A directory listing cannot disagree with itself.
- **Encoded at staging, not at send**, so a retry after a crash sends the same
  bytes — which is why `flushPhotos` awaits outstanding staging tasks before
  deciding it has nothing to do.
- **The flush is driven by staged edits and never by the array's contents.** A
  grid that has not hydrated yet is six empty slots, and anything reconciling the
  array against the server reads that as *delete everything*.
- **Removal is two writes**, object first: a row pointing at a missing file draws
  a broken picture, while a file with no row is merely unreferenced. **Saving is
  two writes as well**, and both must be checked — an object whose row failed
  leaves `paths()` answering "no photographs", which makes
  `DiscoveryCardService.publish` decline by design. That person then has **no
  discovery card at all, permanently, with no error anywhere.**
- The card is republished after any change, since it carries the paths.

**One photograph is enough, and nought is not.** `publish` refuses on an empty
`photoPaths`. One is fine: `DiscoveryFeed.draw` asks for `min(count, pool.count)`
and `MatchProfileView` uses `photoPaths.first` as the avatar.

**The six boxes take photographs only, and that is a deliberate stop.**
`matching: .images` filters inside Apple's own picker process, so videos are
absent rather than shown and refused — `PhotoService.encode` would upload a video
as picked, failing at the bucket's 15 MB door after the person had waited.
Restoring it is `.any(of: [.images, .videos])`, the encoder's commented branch,
the MIME types, the `kind` column's `video` option in `0015`, and the
`AVAssetExportSession` that was the actual missing piece. The view's five video
branches stay in place and marked dormant; `load` branches on what the item *is*,
so the safety does not rest on the picker's filter. **Chat attachments are a
different feature and still take video** — `chat-media`, 50 MB.

**Some things can be set but never changed** — the shape of bug to watch for on
the next field. A value captured once during onboarding, on a screen nobody
returns to, is a value with a typo in it forever. The name had this until
`NameSheet`; the biographics rows had it from the other side, rendering only once
they held a value, so nobody could put a first one in.

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

**Every upload needs `CURRENT_PROJECT_VERSION` bumped, and it appears once per
configuration per target.** All of them must move together. **Count it, never
remember it**: `grep -c CURRENT_PROJECT_VERSION project.pbxproj`. The number
grows with every target, and **un-embedding a target does not reduce it**.

**Held-back features are hidden by one line and marked `ARCHIVED-`, never
deleted**; `grep -rn "ARCHIVED-"` is the whole inventory. Two shapes:

- **A source** leaves `Modality.sources`. Its distiller, `OAuthProvider` case,
  `AppConfig` scopes and every read path stay compiled, so restoring it is an
  edit. Side effect: `recordSources` derives from `sources`, so
  `Modality.owning(source:)` answers nil for an archived source and its rows
  belong to no branch — harmless with no rows, which is why Spotify needed
  `purgeArchivedSources` and Google Calendar did not. **Less harmless than it
  reads**: `applyingBans` gates on `recordSources` too, so an archived source
  with rows silently stops honouring the ban list.
- **A whole target** is **un-embedded**, not deleted and not `FALSEPREDICATE`'d.
  It still builds and signs; it is simply not copied into the app.

**Verify in the archive, never in the build settings** — both of these, because
each only becomes true once baked in:

    A="$(ls -dt ~/Library/Developer/Xcode/Archives/*/*.xcarchive | head -1)"
    ls "$A/Products/Applications/Written.app/PlugIns/"
    plutil -p "$A/Products/Applications/Written.app/Info.plist" | grep MinimumOSVersion

**An embedded extension's `IPHONEOS_DEPLOYMENT_TARGET` must not exceed the
app's.** Xcode gives a new target the *SDK* version by default, so
`ShareToWritten` was created at 26.5 against the app's 16.0 and shipped that way
twice — anyone below 26.5 got an app with no share extension in it.

**A purpose string is demanded for the API you *could* call, not the one you do —
and the deployment target decides which key's name.** `ITMS-90683`, twice:
`NSHealthUpdateUsageDescription` for an app that never writes to Health, and
`NSCalendarsUsageDescription` alongside `NSCalendarsFullAccessUsageDescription`.
Adding a source means adding *every* key its framework can reach, back to the
deployment target. Both arrive after a successful upload.

**Since 2026-04-28 a submission must be built with the iOS 26 SDK or later** —
unrelated to the deployment target, and a silent blocker that only appears at
upload. `DTSDKName` in the archive is the check.

**"Uploaded" is four states short of "a tester has it", and the gap is silent at
every step:**

    archived -> uploaded -> processed -> in a tester group -> review-approved -> Testing

Testers sat on build 1 for a week because build 8 was never *submitted for Beta
App Review*. The `Distributions` array in `.xcarchive/Info.plist` answers "was it
sent" offline, but `success` there means only that the bytes reached Apple — build
6 carries that stamp and shows **Failed**. **Read the TestFlight tab for anything
past the upload leg.**

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
working contact address all still bind — and 90 days is a commitment.

**The unattended upload does not work on this machine; uploading does.**
`xcodebuild -exportArchive` sees no Apple ID and no API key, so it cannot use a
*distribution* certificate. Two ways out: Organizer → Distribute App → **App
Store Connect** (2FA every time, and **not "TestFlight Internal Only"**, directly
above it in the same list and a one-way door that stamps the *build* as
undistributable, escapable only with a higher build number); or an **App Store
Connect API key** (Users and Access → Integrations, role App Manager,
`AuthKey_<KEYID>.p8` in `~/.appstoreconnect/private_keys/`, then
`-authenticationKeyPath/-KeyID/-KeyIssuerID`). The `.p8` downloads **once** and
is a credential; treat it like `sb_secret_…`.

### The reviewer cannot create an account without help

Sign-up is phone-only and verified by SMS, and Twilio Verify's geo permissions
allow Hong Kong, Taiwan and the US only — so a reviewer outside those cannot
receive a code, and one inside still needs a number they control. Apple and
Google cannot rescue it: they refuse any identity that is not already linked, and
**Apple can never be a demo route for any app**, since `ASAuthorization` signs in
whoever the device is signed into. Guideline 2.1 rejections for "we could not
sign in" are routine and slow.

**The answer is a test phone number.** Supabase maps a number to a fixed OTP
(`SMS_TEST_OTP`, bounded by `SMS_TEST_OTP_VALID_UNTIL`) and sends no SMS,
sidestepping the geo restriction, the Twilio cost and Google's 2FA at once —
while exercising the real sign-up path rather than a bypass. The demo account was
built this way on 2026-08-07 and its credentials live in App Store Connect → App
Review Information and nowhere else. **Remove the number after approval**, or let
the expiry do it.

Two ways to get this wrong, both silent:

- **The username must be the ten *national* digits.** `PhoneNumberView` defaults
  to `Country.unitedStates` and `Country.format` truncates to ten, so a pasted
  eleven-digit `1XXXXXXXXXX` becomes `1XXXXXXXXX`, still passes
  `isValidNationalNumber`, and sends the code to a number nobody holds.
- **The Notes field is not optional here.** A reviewer who taps "Sign in with
  Apple" is refused by `resolve-signin` with no way to know that *Create account*
  is the only door.

**Do not build a demo mode that hides restored data until a Connect tap.**
Considered and rejected: it makes Connect report data that did not come from the
device, for one account only, which is 2.3.1(a) — *"no hidden, dormant, or
undocumented features"* — and 2.1 permits a built-in demo mode only *"with prior
Apple approval"*.

**`supabase/auth#1252` did not bite.** It reports that Twilio Verify always
routes to Twilio and ignores the test OTP; tried 2026-08-07, the number works.
Kept only as the first place to look if that stops being true.

## Known gaps

Open as of 2026-08-13, ordered by what hurts soonest. **Delete an entry when it
stops being true** — everything deleted from this file is in `git log -p
CLAUDE.md`.

- **A restore has never been run on a device that didn't already have the data.**
  `RestoreService` is wired into launch and checks out on inspection, which is an
  argument, not a test. Sign in to the demo account on an erased simulator —
  **this is also the reviewer's first launch.**
- **Notifications are proven on sandbox and untested on production.** Every
  `device_tokens` row reads `sandbox`; a TestFlight build mints a **production**
  token against a different host. Confirm a row reading `production`, then send
  one message and check the face still arrives.
- **Nothing enqueues a recompute when somebody answers a claim.** `0114` made
  suppression a real scorer input and `0115` restored the revision bump to match,
  so a suppression correctly stales every inferred assertion — but no trigger
  enqueues the work, so the Memories page stays blank until the worker is run by
  hand. The trade was taken deliberately (showing the old score would be showing
  a number the system no longer stands behind). The fix is one job per *user*,
  keyed on the revision and the three analysis ids, not one per tap.
- **Nothing lists a suppressed assertion**, so a hidden row cannot be recovered
  the next day: `list_assertions` filters `display_state = 'suppressed'` and no
  other function returns them, which makes a mis-tap permanent. It wants a server
  decision — a second RPC, or a parameter — and the question underneath is what
  somebody is owed over their own profile.
- **Exposures are recorded when an answer is given, not when a row is drawn.**
  Honest for anchoring and cheap, but `assertion_exposures` cannot answer *"what
  was shown and not acted on"*, which §10 lists among the shadow metrics. Three
  orphan exposures from failed attempts are already in that table.
- **Connecting Google Calendar on a phone that already has the Google account
  duplicates every event, and it has now happened** — four flights promoted
  twice, once under each source, same carrier and flight number, different
  `item_id`. **The guard behaved as designed and its design has the hole**:
  `hasGoogleAccountOnDevice()` reads `EKEventStore().sources` and returns false
  when calendar access has not been granted, but the person who has not yet
  granted it is exactly the person being offered Google Calendar. Deciding it
  after Apple Calendar is connected, or re-deciding once access exists, is the
  fix; `append_source_records` dedupes within a source and cannot see this.
- **The assertions have been read down the strong end and not to the bottom** —
  confirmed as far as `creator:frederic_chopin` at 0.362, the concept nearest the
  0.35 bar. What is unread is the middle: the K-pop and J-pop creators between
  0.38 and 0.72. One thing to check: **`genre:asian_music` at 0.942 is a
  container in all but name**, a `broader` parent of k_pop, j_pop, cantopop and
  mandopop, so it scores once for everything those four score for — the same
  tautology as `hub:music`, which the hub rule cannot catch because its kind is
  `genre`.
- **Whether HealthKit habit candidates are within the grant is unanswered.** The
  consent says *keep and use my activity to describe me to myself*; the next
  HealthKit unit computes fitness *assertions*. Moot until a device records
  workouts.
- **App Store privacy labels are not filled in.** **The three answers that must
  agree are `PrivacyInfo.xcprivacy`, `web/en-us/privacy/` and the
  questionnaire**; a disagreement is a routine rejection and none of the three
  checks the others.
- **Identity linking is unbuilt.** Three sign-in methods mean one person can hold
  three accounts. Deferred for the beta; decide before launch.
- **A failed record upload is recorded but undrawn.** `sync` keeps the first
  failure on `DistillViewModel.syncFailure` and nothing renders it.
- **Watch `birth_date` the first time somebody completes the birthday step** — it
  was null for every account as of 2026-08-07, so the age gate has never been
  observed reaching Postgres.
- **A declined Workouts toggle is indistinguishable from no workouts.**
  `health_sports` being empty is otherwise settled and correct — zero `HKWorkout`
  samples, since no test device has an Apple Watch, and the v0.3.1 handoff
  independently found the same abstention. HealthKit returns a refused read as an
  empty set and nothing records the sample count; one line in the distiller's
  `Trail` would settle it.
- **The append/change-only path has never run from the app.** `0004`–`0006` were
  exercised directly against the database. Distil Apple Music twice and confirm
  the second run writes only what moved.
- **CAPTCHA is off for phone sign-in**, with the 10/hour SMS rate limit standing
  in for it. **Revisit both together.**

### Deferred by decision

**Google OAuth verification, deferred until the hubs exist.** Decided
2026-08-05: submitting earlier means shooting the demo video against a pipeline
about to be replaced, and the same form carries the derived-metrics request.
**Nothing about that defers the policies themselves** — they bind every API
Client, verified or not. Two traps: Search Console must be verified as a
**Domain** property signed in as an Owner of Cloud project `672788849005`
(verifying as the wrong account is the standard rejection and Google does not say
so), and the consent screen must carry `https://written-stl.com/en-us/` and
`.../en-us/privacy/` **character for character**, matching `SignInView.swift` —
not `/privacy`, which 301s, and a redirect is not agreement.

**The Disconnect control has never been exercised against a real Google account**
and the published privacy policy makes a 7-day claim resting on it; that has to
happen before YouTube comes back.

### Standing traps, not gaps

**The site is written from the app and goes stale silently** — a page cannot fail
to compile. It once described a one-sign-in-method app with no Google Calendar
and no notifications for a day after all three shipped, and promised six times
across three pages an in-app control that existed for nothing. **Adding a source,
a sign-in method, or anything else that leaves the device means editing
`web/en-us/privacy/` in the same commit.**

**It happened again and worse: four pages said in six places that Written "no
longer connects to a YouTube account" and collects "no new YouTube data", while
YouTube was live with 731 rows.** A published compliance document asserting that
a live source collects nothing is the most expensive form this trap takes.
Corrected 2026-08-12, and the scope table gained `youtube.readonly` — that table
is what Google's verification form points at.

**And the deploy target was wrong the whole time.** `wrangler.jsonc` named
`written-site`; `written-stl.com` is a custom domain on a Worker called
`written`. Every `npx wrangler deploy` created a *second* Worker and published to
it — success, every asset uploaded, a version id printed, nothing reachable
changed. It was convincing in the wrong direction: the apex served the old copy
**with our own `_headers` CSP on it**, and `cf-cache-status` said `HIT` even for
a cache-busting query. What settled it was the account, not any amount of `curl`:
`GET /accounts/{id}/workers/domains` → `written-stl.com -> written`. **Verify a
site deploy by diffing a live page against the repo file**, not by reading
wrangler's success line.

Two words it uses precisely: **struck off** is the `BanList` pass, where
`markedRemoved` annotates `extra` and *keeps the row* — so the site says never
used, never shown, never counted, and does not say deleted. **Deleted** is
account deletion, the YouTube sweep and `SyncService.deleteSource(_:)`. Deletion
is immediate in every case, so the 7-day clause is a ceiling kept for backups.

**One network sinkholes `written-stl.com`, and it is the network rather than the
machine.** On `wusm-wifi.wucon.wustl.edu` it resolves to
`sinkhole.paloaltonetworks.com` — newly-registered-domain filtering, and
`example.com` resolving correctly from the same resolver is what makes that a
decision rather than a fault. **Do not diagnose a deployment from a sinkholed
resolver.** Resolve over DoH and pin the answer:

    curl --resolve written-stl.com:443:104.21.7.174 https://written-stl.com/en-us/
