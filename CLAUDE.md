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

- **Asking for more permissions.** Health's sheet lists only the types actually
  read. "Technically possible" means with the consent already given.
- **Widening the list of what leaves the device.** That list is kept short and
  complete on purpose, and `PrivacyInfo.xcprivacy` has to keep agreeing with it.
- **Working out what a source already states.** *Keeping* a field and
  *inferring* one are different acts under different rules, and for YouTube the
  second is prohibited outright — "infer or estimate the content category/type of
  a video or channel". Add `part=topicDetails` to reach one more field; do not
  compute a label the source would have given you for the asking. See III.E.4.h.

Within one already-granted permission, take everything: extra fields on a
response already fetched, extra `part=` on a request already being made, a second
query against a library already open.

**And an absence is not a refusal.** Distil what is reachable and explain what
is missing — never stop because one route came back empty. **But do not assume
the other route saves you**: the device library is not a fallback for Apple
Music, measured below.

## Supported apps and what each yields

Scope comes from `written_api.xlsx` (the source of truth for what each platform
exposes; consult it before adding a source). **`grep -rn "ARCHIVED-"` is what
actually ships** — two of the sources below are held back for the App Store
build, one is impossible, and one is unresolved. **Spotify is a third case: its
`ARCHIVED-SPOTIFY` markers are in place but lifted**, because the
data-collection prototype offers it and the real launch will not. So a marker
means "held back or on its way back", and only the code around it says which.

- **YouTube** (`YouTubeDistiller`) — **live, and the `ARCHIVED-YOUTUBE` marker
  had drifted from the code for months.** `Modality.swift:134` says `"youtube"`
  was removed for the App Store build and `:147` returns it; the same is true of
  `google_calendar` at `:175`. Measured 2026-08-12: **731 rows**, 3 connections,
  distilling normally. **Anything shipped from this tree offers a reviewer both
  sources, and both 403 for accounts off the Testing allowlist** — so the drift
  has to be closed deliberately before any upload, in one direction or the other.

  Subscriptions, liked videos, playlists and playlist contents. Watch history is
  **not** reachable: the API does not expose it, and Takeout/Data Portability is
  EU-only. `channels.list` is asked for `topicDetails,statistics` in one call —
  quota is charged per call rather than per part, so the subscriber count is
  free, and it is the one field here III.E.4 lets outlive thirty days because it
  is a *statistic*.

  **It dual-writes to the vault and resolves**, which the YouTube section below
  sets out. What it may not do is infer: `provider_topic` and `uploader_tag` are
  reads and are permitted, `written_title_tag` is a guess and is gated.

- **Apple Music** (`AppleMusicDistiller`) — library songs/albums/artists/music
  videos, playlists + contents, recently added, recently played, heavy rotation,
  personalized recommendations, like/dislike ratings.

  **The source the product depends on — and a person without an Apple Music
  subscription gets no music from this app at all.** Not from MusicKit, whose
  library endpoints read the same cloud library, and not from the device library
  added to cover for it. Measured on one device with Sync Library toggled off:
  `MPMediaQuery.songs()` went **320 to 0**, cloud items 304 to 0, while podcasts
  held at 2 throughout — that last number is the control proving the library was
  still readable, so the zero is an absence rather than a refusal. Not even the
  sixteen non-cloud rows survived; they were Apple Music tracks downloaded for
  offline play, which read as local and are not. `MusicLibraryDistiller` still
  earns its keep for people who *own* music — iTunes purchases, a synced
  collection — which is real and uncommon.

  **The other face of that measurement: on a subscriber's phone both sources
  return the same library, so every song was counted twice.** A real export had
  320 `library_song` rows under `apple_music` and 320 under `music_library`,
  **320 title-and-artist pairs in common and zero ids in common** — and
  `MusicHighlights.deduplicatedSongs` collapsed on the id, which only ever
  deduplicates *within* a source. It collapses on title and artist now: 1,046
  song rows went 888 unique to 560.

  It hid because the doubling was uniform — rankings held and
  `Ontology.subjects`' shares were untouched, since the denominator doubled with
  the numerator. Only the absolute counts were wrong, and the rest was safe only
  while the two sources had identical coverage. **Skipping cloud items in
  `MusicLibraryDistiller` was the obvious alternative and is worse on this
  page's own evidence**: those sixteen non-cloud rows were streamed tracks that
  read as local, so the flag cannot tell owned music from downloaded.

- **Spotify** — **live again for the data-collection prototype, and still
  removed before the real launch.** It is offered alongside Apple Music so test
  users' listening can be inspected together; the five-user development cap is
  survivable for a coordinated group and is not survivable for a beta, which is
  what the rest of this entry is about.

  **It is offered in the source picker, so tapping Music shows two choices**,
  and picking Spotify opens an OAuth sheet — a web login where the Spotify app
  is not installed. **Backing out of that sheet used to fail the whole Music
  branch**: `OAuthPKCEService` reports it as `OAuthError.cancelled`,
  `distillSpotify` drew it as `.failed`, and `failureMessage(for:)` returns the
  *first* failed source in a modality — so a cancelled Spotify put an error on
  the Music card while Apple Music had just distilled 1,225 rows successfully.
  A cancelled sign-in returns the source to `.idle` now, through
  `DistillViewModel.status(after:)`, which YouTube and Google Calendar share:
  dismissing a sheet is a decision, and `.idle` is exactly where a source
  nobody connected belongs.

  **Two edits turned it on and both must be reversed to turn it off**, which is
  the thing to remember rather than either one alone: the string in
  `Modality.sources`, and `AppShell`'s `.task { viewModel.purgeArchivedSources() }`,
  now commented out. That task deletes Spotify rows from memory, from the
  on-disk cache and from Postgres — `distilled_records` and `source_connections`
  both — on every launch. Left running with the source live it wipes each
  distillation moments after it lands, and because the purge and the upload are
  independent detached tasks it would not even fail the same way twice.

  Turning it on also fixed something that was quietly broken: `applyingBans`
  gates artist bans on `Modality.music.recordSources`, so while Spotify was
  archived a struck-off artist came back on every Spotify row.

  The clause reading below is unchanged and is why it comes out again:

  - **The storage rule is a limit, not a prohibition.** **IV.3.1.a**: *"you may
    not store, aggregate or create compilations or databases of Spotify Content,
    other than as strictly necessary to operate your SDA… Do not store Spotify
    Content indefinitely."* That is the shape of `0016`'s YouTube sweep — store,
    refresh, expire — rather than "could never be restored to a new device",
    which is what this said and is stronger than the clause supports. And
    **IV.2.5 explicitly permits** *"transfer Spotify Content to third party data
    processors, such as server providers for providing your SDA"*, so Postgres
    was never the problem either.
  - **What actually rules it out is IV.2.1.a**: *"using the Spotify Platform or
    any Spotify Content to train a machine learning or AI model or otherwise
    ingesting Spotify Content into a machine learning or AI model."* No
    carve-out, and the clause names the use twice. **IV.2.5 also closes the
    consent route**, in its own words — derived and aggregate data count, *"even
    if a user consents to such transfer or use."* A collaborator can grant
    rights over their own data and never over Spotify's.
  - **And it cannot leave development mode**: *"up to 5 authenticated Spotify
    users"*, added by hand in the dashboard by name and Spotify email. Extended
    quota has been organisations-only since 15 May 2025 — a registered business,
    a launched service, at least 250,000 monthly actives, key markets — and
    individual developers are explicitly not eligible.

  Five is survivable for a coordinated group, rotated by hand; it is not
  survivable for a beta, where the sixth person logs in successfully and is then
  refused, which reads as the app being broken. That is the same judgement that
  archived YouTube.

  **Its rows are not shaped like Apple Music's, and three of the differences had
  to be answered before the two could be read side by side.** Of the six
  `data_type`s `SpotifyDistiller` emits, only `recently_played` and
  `playlist_item` overlapped — so `top_track`, which carries an explicit
  `rank=N` and is the strongest listening signal either source returns, counted
  for nothing until it joined `MusicHighlights.songTypes`; `top_artist` and
  `followed_artist` joined `artistTypes` for the same reason. Spotify stamps no
  `subject=`, and its `creator` is **pipe-joined across every credit**, so
  `Ontology.storedSubject`'s fallback produced the subject `Drake|Future|Tems`
  — a discovery-card term and a ban value that no artwork lookup could ever
  match. It stamps the first credit now, through `Ontology.musicSubject` rather
  than a second copy of the rule, though on this source that rule can only ever
  return the performer: Spotify returns no composer, so a Bach partita is filed
  under whoever played it.

  **And `MusicHighlights.deduplicatedSongs` now collapses by *group*, not by
  source.** Its key was written for one Apple library read twice — `apple_music`
  against `music_library`, the same metadata by two routes — and letting it
  reach across to Spotify would have been wrong in both directions at once. A
  single-artist track matches and the Spotify row is discarded; a featured one,
  `Drake` against `Drake|Future|Kyla`, does not and counts twice. Spelling-
  dependent, silent, and different per track. The Apple pair still collapses;
  anything else stands on its own, which is also what an inspection prototype
  wants.

- **Apple Podcasts** (`PodcastDistiller`) — `MPMediaQuery.podcasts()`, one
  `MPMediaLibrary` permission, no login, same framework and same
  `NSAppleMusicUsageDescription` as Apple Music. **It is the whole of the Media
  branch while YouTube is archived** — a branch with one source is still a
  branch. See `Modality.isOffered`.

  **It returns downloaded episodes and nothing else**, evidenced rather than
  assumed: 304 cloud items sat in the same library while cloud podcasts held at
  zero, and following a show does not enumerate its back catalogue — *Crime
  Junkie* appeared with one item against hundreds published. Measured on two real
  episodes:

  - **Populated:** `podcastTitle`, `title`, `artist`/`albumArtist` (the
    publisher), `releaseDate`, `dateAdded`, `playbackDuration`, `bookmarkTime`,
    artwork, `assetURL`.
  - **Empty:** `genre`, `playCount`, `lastPlayedDate`, `skipCount`, `rating`,
    `comments`, `composer`, `isExplicitItem`, `isCloudItem`.

  So there is **no play history** — `playCount` was 0 and `lastPlayedDate` nil on
  episodes demonstrably played. `bookmarkTime` is the only behavioural fact and
  it is real (50.8s of 4191.8s). A category would have to come from the iTunes
  Search API by show name.

**Whether the source is worth having is unresolved, and it turns on one
  question: does Apple Podcasts auto-download episodes of followed shows?** If it
  does, the library is a rolling window over what somebody follows; if not, it
  reflects only deliberate downloads, which almost nobody does. Both test
  episodes were downloaded by hand, so there is no evidence either way. **This
  ships unanswered**, and an empty source that looks connected is worse than no
  source. Settle it by following a show on a device, downloading nothing, and
  looking again.

Ruled out and not to come back: MusicKit has no podcast types; iCloud sync uses
  Apple's private container; Now Playing metadata for another app is private API;
  `DeviceActivity` needs Family Controls; the privacy.apple.com export arrives as
  an emailed ZIP days later; `JournalingSuggestions` vends one user-picked item
  at a time above this app's deployment target. What remains is the share
  extension resolving a `podcasts.apple.com` link through the iTunes Search API,
  or Spotify's `/me/shows`. `MPMediaQuery.audiobooks()` is **untested, not
  unavailable**, and reaches only the iTunes-era leftover — Books has no
  user-library API and its DRM-protected M4B never leaves its container.

- **Apple Calendar** (`CalendarDistiller`) — **the first source not in
  `written_api.xlsx`.** A calendar collects two things nothing else reaches:
  bookings that ticketing sites write in by themselves (Eventbrite,
  Ticketmaster, Dice), a far stronger claim than a followed artist because it
  cost money and a Saturday; and what people type for themselves, which is
  behaviour rather than inference. `url` and `organizer` are kept because they
  are what tells a booked event from a typed one — see `booked=1` in `extra`.

  **Events are stored whole and synced**, unlike HealthKit, because the titles
  *are* the signal — a deliberate trade that puts other people's names and
  locations in the database, and `PrivacyInfo.xcprivacy` says so. **Windows are
  five years either side** (`AppConfig.calendarLookbackDays` /
  `calendarLookaheadDays`, capped by `maxCalendarEvents`), both directions,
  because a ticket bought today for November only exists ahead of now — a flight
  to Los Angeles disproved the old 365/180. Repeating entries were the argument
  for a short window and are solved separately: the fetch keeps one occurrence
  per identifier and marks it `recurring=1`.

  Three traps, each paid for:

  - **`predicateForEvents` silently returns nothing across more than four
    years**, so the fetch is chunked by year. One ten-year predicate returns an
    empty list and no error, indistinguishable from a person with no plans.
  - **The chunks are walked outward from today**, not oldest-first. A decade of
    standing meetings fills the cap somewhere in 2021 and the walk stops before
    reaching anything ahead of now, losing the booked trip the widening was for.
    Walked outward, a cap costs the furthest year in either direction.
  - **On iOS 17+ the old `requestAccess(to:)` grants *write-only***, which reads
    nothing and looks exactly like an empty calendar.
    `requestFullAccessToEvents` is required, and the legacy
    `NSCalendarsUsageDescription` is still required alongside the modern key
    because the app deploys to 16.0.

  **Three exclusions, and they are three different mechanisms because no one of
  them can reach the others:**

  - `CalendarDistiller.isGenerated` tests the calendar's *type* first and its
    *name* last, because holidays arriving through a Google or Exchange account
    are `caldav` — an ordinary type, from a server, indistinguishable by type
    from a real diary. The name list matches English plus 节假日 / 節假日 and
    **will always be incomplete**, which is why it runs after the type.
  - `PublicHolidays` catches what Google copies into somebody's *primary*
    calendar as ordinary events, which no calendar-level or structural test can
    see: of 77 surviving events on a real device, 49 were public holidays and all
    49 were all-day, unrecurring, unorganised and unbooked — character for
    character what "Outpatient" and "1st email" look like. Matched **by token,
    not by whole name**, because Google writes one day a dozen ways, and
    incomplete by construction, since a rule broad enough to swallow a real event
    costs more than showing somebody Karneval.
  - Titles carrying `birthday` or `meeting` are **not drawn**, in either script —
    a *reading* decision, not a filter on what is kept. Every such row is still
    collected, synced and sent to the ontology stage.

  **A row with no `cal_type` is not drawn.** Counted on a real device: 95
  calendar rows, every one untyped, of which 51 were `US Holidays`, 37
  `香港节假日`, one `Birthdays` and six were real. It costs nothing permanent —
  the distiller stamps `cal_type` now, and `append_source_records` treats a
  re-stamped row as a change, so **one re-distill returns every event the person
  still has, typed.**

**The card lists the events themselves**, one row per distinct title, **ranked
  by what made the entry rather than by when it happens** — date order is why a
  flight to Los Angeles could not be found on a card listing it, sitting 59th of
  77 behind five years of dentist appointments. `ListeningHighlights.shape` is
  kept and drawn by nothing: booked-against-typed, evenings, weekends and the
  busiest day are derived readings the ontology stage will want.

- **Google Calendar** (`GoogleCalendarDistiller`) — **its `ARCHIVED-` marker has
  drifted exactly as YouTube's did**, and the sentence that used to sit here —
  *"nobody has ever connected it"* — is false. `Modality.swift:175` returns
  `google_calendar`, and there are **7 rows and 1 connection**. The reason for
  archiving still stands: the consent screen is in Testing, so a reviewer's
  account gets a 403 *after* a successful login.

Its condition is the whole design: **offered only where the
  phone has no Google account.** One added in iOS Settings delivers its events
  through EventKit as `caldav`, so `CalendarDistiller` already has them, and
  collecting them again would put every dinner in the database twice under a
  different `item_id` and `source` — which `append_source_records` dedupes
  *within* a source and would not catch. `hasGoogleAccountOnDevice()` tests the
  `EKSource`, not calendar names, and both `SourceAvailability` and
  `DistillViewModel` guard it, because a hidden row is a drawing and not a rule.
  Two narrow scopes rather than `calendar.readonly`. Nothing downstream knows it
  exists: same `extra` keys, same card, same ontology stage. Birthdays go by
  Google's own `eventType`, which beats the Apple path's title matching.

- **Google Health is not possible on iOS, and this is settled rather than
  deferred.** The Fit REST API stopped accepting new signups on 2024-05-01 and
  is supported only to the end of 2026; Health Connect is Android-only with no
  cloud API; Google's own migration guidance sends iOS developers to Apple
  HealthKit. Worth knowing `fitness.*` was a **restricted** scope, so even when
  it existed it would have dragged this project into a CASA assessment.

- **Apple Health** (`HealthKitDistiller`) — five `data_type`s, and the counts
  are the reason they are all kept: `age` (1) and `biological_sex` (1);
  `workout` (0–300 a year — sport, duration, energy, distance, recording app);
  `activity_day` (≤365 — exercise minutes, active calories, steps, first
  movement); and `activity_hour`, **24 rows for the whole window rather than
  8,760**, because the question is which hours somebody is active in and not
  what they did at 3pm last March. `DistillViewModel.healthKeptTypes` lists all
  five and is kept as a list precisely because it now excludes nothing — it is
  the gate a *new* HealthKit type has to pass, and a type that is read and
  travels by default is how a permission sheet grows without anybody deciding.
  Two windows, not one:
  `AppConfig.healthWorkoutLookbackDays` and `healthActivityLookbackDays`, both a
  year, kept apart because the asymmetry is real — workouts are sparse, quantity
  samples dense — so the activity window is the dial to turn first if a
  distillation is ever genuinely slow. Note it was turned once already, wrongly:
  the hang was the *authorization request* never returning, with no query run.

  **Only the types actually read are requested.** HealthKit authorizes per type,
  so asking for vitals we have no use for widens the sheet for nothing — and
  *reading* a type never requested is what makes it answer
  `errorAuthorizationNotDetermined`, which is how distance was queried for
  months without ever being returned. **A declined read looks exactly like no
  data**, since HealthKit never says which reads were refused, so an empty
  distill is surfaced as a failure rather than silently growing a branch.

### HealthKit's permission sheet, which is not HealthKit's

It asks SpringBoard to launch `com.apple.HealthPrivacyService` and hosts a
remote view from it, so if anything else owns the screen or that process is cold
it gives up rather than reporting a refusal. Five rules, each paid for:

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
  `.sheet(item:onDismiss:)` starts the work instead of a guessed delay — right
  for `ASWebAuthenticationSession` and the MusicKit and EventKit alerts too.

**Its Allow button is disabled until a category is switched on**, which reads as
a frozen app, so the Health row alone carries a second line warning of it
(`detentHeight` counts it) and `SourcePickerSheet.privacyNotice` sits under the
rows rather than inside one. **It only happens to people who have never been
asked, so testing Health on your own phone proves nothing** — reset with
`xcrun simctl erase`, or Settings → General → Transfer or Reset → Reset Location
& Privacy.

Three lessons from the same hunt, none of them about the sheet. **A failure has
to be drawn against the branch that was attempted** — `GrowProfileView`'s prompt
card asked `nextModality`, so a source connected out of sequence drew "Ready to
grow?" over a real error. **A `withThrowingTaskGroup` cannot impose a timeout on
a call that never returns**: the group awaits every child, `cancelAll()` only
sets a flag, and a task suspended in `withCheckedThrowingContinuation` never
observes it, so surviving a continuation nobody will resume needs an
unstructured task that is deliberately abandoned. And **a Release build may say
what failed** — `BuildKind.isBeta` (a TestFlight build carries a *sandbox*
receipt, an App Store build carries `receipt`) prints the diagnostic in Debug and
TestFlight only, because `stageFailed` and `stageTimedOut` rendered identically
with the detail behind `#if DEBUG`. The detail is the whole run rather than its
last line, and long-pressing copies it.

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

**YouTube is archived** and none of this binds while it is. It is kept because
re-entering costs more than reading it, and because one clause governs every
source. **Read the clauses, never a summary of them** — two confident readings
from summarised fetches were both wrong.

**III.E.3.b — Authorized Data goes to nobody but its owner**, and *this one is
not about YouTube*. *"Must not display or allow access to Authorized Data to
anyone other than the authorizing user."* `publishDiscoveryCard` was appending
every ranked YouTube channel to `discovery_cards`, the one table every signed-in
user may read. **The two-part test for anything added to that card is "is it
something a sentence can be about" *and* "do the source's terms allow a stranger
to see it".** Nothing in the schema asks the second. Apple Music is untouched.

**III.E.4.h — the derived-data prohibition, and the reason `Ontology.classify`
is not called on YouTube data.** *"Must not… access or use API Data to create new
or derived data or metrics"*, whose don't-list is scoped to channels and videos
and includes *"infer or estimate the content category/type of a video or
channel"*. The remedy is its heading: ***"Only offer metrics that are available
via YouTube's API services"*** — so the category is read rather than guessed.
`Ontology.domain(youTubeTopics:creatorTags:categoryID:)` maps YouTube's own
vocabulary onto ours, most specific first, since category 28 is "Science &
Technology" while a channel tagged `Technology` is not:

- `topicDetails.topicCategories`, reduced to the last path component. Liked
  videos carry these; **subscriptions do not**, since `subscriptions.list` has no
  `topicDetails` part, so `channelTopics` makes a second `channels.list` call.
- `snippet.tags`, **matched whole and lowercased against a small controlled
  vocabulary, never as substrings.** Recognising `physics` is translation;
  matching `phys` inside a title is a guess wearing the same clothes.
- `snippet.categoryId`, the numeric fallback.

**`refusedTopics` drops Religion, Politics, Health, Military and Society whatever
YouTube says**, and categories 25 and 29 are absent from the id table for the
same reason: a content tag is how a protected characteristic arrives without
anybody deciding to collect it. **Check the source before calling `classify`** —
the restriction is YouTube's alone, and the music line goes through
`musicLine(for:)` and Apple Music's own genres. What the compliant reading costs
in coverage is unmeasured; measure it on its own rather than running the old
classifier alongside.

**Retention: 30 days, and `0016`'s daily `pg_cron` sweep is still running.**
III.E.4 permits storing beyond 30 calendar days only Analytics data, Reporting
data and *statistics*; titles, channel names and playlist contents must then be
deleted or refreshed. Three stores hold YouTube strings: `distilled_records`,
`discovery_cards.interests` (swept by `0032` and no longer written), and
`shared_posts`, deliberately *not* swept because that video id came from a public
URL somebody pasted rather than an authorised API call. **`0016`'s premise — that
derived output may persist indefinitely — may be wrong, so settle it before
anything derived is persisted.**

**Revocation.** Revoked at Google, everything read must be gone within 30 days —
which the sweep satisfies for free, since it deletes 30 days after *collection*.
Revoked in-app it is **7 days**, and a deletion *request* is 7; that is the case
the sweep cannot cover. One control is built, on the dashboard and only for
people who have connected YouTube: a **Disconnect all** that revokes.
`DistillViewModel.deleteYouTube(revoking:)` takes the server first and the local
copy only if the server agreed, because a device that cleared itself on a failed
request would show an erased source while the rows sat in Postgres.
**`disconnect()` is not revocation** — it deletes our copy of the token while the
grant carries on existing in the user's Google account. `revoke()` POSTs the
*refresh* token (an access token would revoke only itself) and treats **400 as
success**, which means Google has already forgotten it; its local half runs
regardless, since the token needed to retry is what is being thrown away.

**Bringing it back needs three things, and each is weeks rather than days.**
Extended quota — a worst-case distill is ~185 units against a 10,000/day
default, and requesting it is what triggers an audit. OAuth verification — the
consent screen is in Testing, which allowlists 100 users and expires every
refresh token after 7 days, and publishing needs a Search Console **Domain**
property, a scope justification and a demo video. And, for the ontology stage,
Google's **Content Categorization and Tagging** amendment
(`developers.google.com/youtube/terms/derived-metrics-policy`) — applied for on
the same form, prospectively, so do not apply while running the unlicensed
version of the thing being applied for.

**Read in full, that amendment licenses much less than its headline clause
suggests, and the prior question is eligibility rather than sequencing.** It does
say what is usually quoted — *"You may use analysis to assign descriptive
sub-genres or tags to videos and channels. These must be additive and distinct
from YouTube's video categories"* — but two conditions sit around it, and the
first is decisive:

- **The gate is the use case, not the technique.** The permissions exist *"to
  support advanced analytics and creator tools"*, and the amendment states
  flatly: ***"Your API Service must reflect an analytics use case on YouTube."***
  This app is a dating platform building a personal taste profile, which is
  neither. That sentence conditions every numbered permission beneath it.
- **The storage relief excludes exactly what this product wants.** Accepted
  clients may keep *statistics* and *derived metrics* for 36 months, but *"other
  data (such as video titles, creator names, descriptions, and comment text) must
  still follow the 30-day refresh and deletion policy"*. Channel names are what a
  discovery card would carry, so `0016`'s sweep survives acceptance untouched.

**But it does license real mapping, and the line is *where the label attaches*
rather than categorisation against none.** Three levels, and only the middle one
turns on the amendment:

- **Read YouTube's own labels onto our vocabulary** — permitted today, no
  amendment, and already built: `Ontology.domain(youTubeTopics:creatorTags:categoryID:)`.
- **Assign our own sub-genres to videos and channels** — what §3 licenses, and a
  genuine gain. It is exactly the restraint in `domainForCreatorTag`, which
  matches whole tags against a small controlled vocabulary because inferring
  from freeform text would be a guess; licensed, that guess is permitted and the
  many untagged channels stop being unplaced.
- **Aggregate those into a claim about the viewer** — absent. The six categories
  are Custom Channel Scores, Financial Performance, Content Categorization,
  Viewer Sentiment, Gamification and Brand Suitability; five are about channels
  and videos, and the only one naming viewers does so as a restriction. So this
  stays inside III.E.4.h's general prohibition with no carve-out reaching it.

**Which is why Memories is fine and the discovery card is not.** Grouping
somebody's own channels under YouTube's own topic labels, on their own page, is
the first level and needs nothing. **And it amends III.E.4.b/c/d only, so
III.E.3.b is not in scope**: showing one user's YouTube-derived channels to
another user stays prohibited whatever is accepted. Worth noting the one place the code is already ahead of it — §4 forbids
profiling users on *"age, race, religious affiliation, political leaning, sexual
orientation, or health status"*, which is `refusedTopics` and the absence of
categories 25 and 29, written before this page was read.

**Fetched twice, and the first response was a summary** that read as a general
licence to extend processing. The clauses above are from the second. This is the
third time a summarised fetch has produced a confident wrong reading of YouTube's
terms, which is why the rule at the head of this section is what it is.

`youtube.readonly` is *sensitive*, not *restricted*, so no CASA assessment is
needed. Whatever happens, the YouTube contribution must be **separable and
reversible** — or the 7-day deletion cannot be honoured without recomputing every
profile — and **must not become load-bearing**, since a refusal would arrive
after the pipeline is built. **The day the ontology layer is enabled for YouTube,
`web/en-us/privacy/` moves in the same commit**: it describes the conservative
reading, which is a compliance statement rather than a description.

**Two things ruled out.** Takeout: the legal point is sound — API Data is data
provided *through the API services* — but a ZIP emailed days later is the
one-button rule broken at every step. And there is **no general prohibition on
merging YouTube data with other sources**; the sentence usually quoted is a
compliance-guide bullet carrying its own labelling condition, while the actual
clauses are narrower (III.E.2.a aggregation **across channels**, III.E.2.b
insight into **YouTube's own** business, III.C.5 **search-result** mixing).

**The DNS trap on `written-stl.com`:** `www` is a **proxied** `A` record to
`192.0.2.1` (TEST-NET-1, routes nowhere) answered by a dynamic Redirect Rule, and
the placeholder is the point — the request terminates at Cloudflare and the
address is never contacted. Grey-cloud it and the browser gets `192.0.2.1` and
hangs. **Not a CNAME to the apex**: the apex is a Worker custom domain, and a
proxied CNAME onto one returns Cloudflare Error 1000. The rule is dynamic
(`concat("https://written-stl.com", http.request.uri.path)`) rather than a static
redirect to the homepage, because Google's reviewer follows deep links. A free
host subdomain cannot stand in — nothing can add a DNS record to `pages.dev`.

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
  re-distill (`replaceRecords(from:with:)`) — distilling YouTube twice must not
  duplicate rows.
- **Data no longer stays on-device.** Everything leaving the device is on this
  list, and the value of the list is that it stays short and complete.
  - **Postgres, keyed to the account** — the distillation itself, via
    `SyncService`, plus the profile, the ban list and derived health signals.
    **HealthKit rows travel now — and for months this paragraph said so while
    the code did the opposite.** Measured 2026-08-10, before the fix:
    `distilled_records` held **zero** rows with `source='health'`, for every
    user ever, while five `source_connections` rows and six `health_signals`
    rows showed Health distilling normally. Nothing looked wrong because the
    half that failed was the invisible half.

    The wire filter was never the cause — `localOnlyTypes` is exactly
    `["health/biological_sex"]`, as below. **`DistillViewModel.sync` simply
    never called `push` for health**, branching it away to send only the derived
    figures. The *keep* half of that change had landed (`distillHealth` writes
    the rows to `RecordStore`); the *send* half was never written, which is why
    `sync`'s own doc comment described the opposite of the code, blaming
    `distillHealth` for discarding rows that `distillHealth` is precisely the
    function that keeps. Second-order: `apply(_:)` carries across only
    `isLocalOnly` rows, so the local copy survived exactly one launch and the
    owner's export came back empty.

    Health now takes the same path as every other source, plus its derived
    figures. One edge case needs the old `pushConnection` fallback and keeps it:
    `push` returns early when rows existed and *every* one was withheld, which
    for Health is a real shape — a library with a date of birth and a sex and
    nothing else — and without it such a person's Health would read as never
    connected.

    **The gate exists now, and it is the vault's rather than this path's.**
    `FitnessPurposeGrantService` records a `fitness_connection` grant through
    `public.record_fitness_grant` (`0061`), and the encrypted copy is withheld
    without one. This legacy push is not gated on it and does not need to be:
    it predates the contract and is what the typed envelopes replace.

    The volume argument that was once given for discarding these rows was never
    real, and that part stands: the distiller sums samples into day and hour
    buckets *before* making a record (`activity_hour` is 24 rows for the whole
    window, not 8,760), so a year is about 400–700 rows against 2,540 from one
    real Apple Music library.

    **`health/biological_sex` is the exception and is refused at the wire** by
    `SyncService.localOnlyTypes` — a per-`source/data_type` list, because the
    unit of that decision is a row rather than a source. It is a protected
    characteristic, nothing downstream asks for it, and `public.users.sex`
    already means the gender somebody *chose*. It is still kept locally and still
    in the owner's own export. `localOnlySources` survives, empty, for the next
    source that may not be stored at all — Spotify was the last.

    Row-level security is the whole authorisation layer.
  - **Lyrics providers** — `LyricsService` sends the top song's artist and title
    to lrclib.net, then music.163.com if LRCLIB has no answer. One artist and one
    title, no user id, no library, cached so a song is asked once.
- **The server is the source of truth; the device keeps a cache.** `RecordStore`
  was the only copy for a while, which is why sync pushing without ever reading
  back left a reinstall starting empty. `RestoreService.hydrate()` is the read
  half: records, `source_connections`, the user object, health signals and bans.
- **Nothing in Postgres is ever deleted, and only changes are stored.** The
  device *replaces* a source's rows in memory so a re-distill doesn't duplicate
  what the dashboard shows; the server *appends*. `append_source_records` stamps
  every row of a run with one `distilled_at`, and a `before insert` trigger drops
  any row identical to the newest version of itself. Two things make that work
  and both are easy to break: the comparison is against the **latest** version,
  not any historical one (or a value that changed and changed back is silently
  lost), and it **excludes `collected_at` / `distilled_at` / `updated_at`**,
  which differ on every pass and would make every row look changed.

  **Three exceptions, and none is a change of mind:** account deletion, the
  YouTube 30-day sweep (`0016`), and `SyncService.deleteSource(_:)` behind the
  YouTube control. All three are obligations — "we kept it, marked as removed" is
  the answer that fails an audit. **`markedRemoved` is still right for striking a
  row off**, keeping "collected then struck off" distinct from "never collected",
  but it cannot stand in for a deletion somebody is owed. `deleteSource` needs
  **no edge function**: `0001`'s policies are `for all using (auth.uid() =
  user_id)`, which covers delete. Note the trap in building that request —
  PostgREST wants a query string, and `URL.appendingPathComponent` escapes the
  `?`, turning `distilled_records?source=eq.youtube` into a request for a table
  of that name. It 404s, which is the lucky failure; the unlucky one is a DELETE
  with no filter at all. `URLComponents`, always.

- **Read through the `summary_*` views, never the tables.** They return the
  latest row per item across all runs — a union, deliberately **not** a sum: a
  HealthKit run reports sessions over a 365-day lookback and Apple Music reports
  cumulative play counts, so adding two runs would roughly double every figure.
  The views are `security_invoker = on`; without it a view runs as its owner and
  bypasses RLS.
- **Signing out erases the device** — `signOutLocalState()` clears the cache, the
  ban list, the tree seed and the OAuth tokens. A connection outlives the session
  through Postgres rather than the phone, and `AccountScope` keys each store by
  account as a second line of defence. **Local state must be cleared before the
  session is dropped**: `AccountScope` reads the stored user id to know which
  files and Keychain items belong to the account, and after
  `SupabaseAuth.signOut()` it resolves to `local` and would clear the wrong ones.
  `HomeView` is the only place wired for this, and `GrowProfileView` deliberately
  has no `onSignOut` so there is no second route that could skip it.
- `PrivacyInfo.xcprivacy` must agree with that list. It declared *nothing
  collected* for a while after the backend landed, which is the kind of claim
  that ages into a rejection.
- **A connection is a snapshot, not a subscription.** Nothing polls: a
  distillation happens the moment someone taps Connect and `collectedAt` stamps
  every row, so "connected" means *has been connected* — which is why
  `RecordStore` persists it.
- **And a connection is not the same fact as a row.** Connectedness was inferred
  from record *volume* — `TreeMetrics.metrics` answers `nil` for a modality with
  no rows — so a YouTube account with no likes and no subscriptions was
  indistinguishable from an untouched one: `nextModality` kept offering the same
  modality, no `ConnectedBar` appeared, the badge ring stayed empty and the plant
  stayed at stage zero, with **no error anywhere, because the distillation had
  succeeded.** Everything reads `branches` now. `ConnectionStore` is the local
  half of `source_connections`, which the server has always recorded correctly —
  `append_source_records` upserts the row even from an empty array — and
  `replaceRecords` is the hook, the one point every source's rows pass through.
  It matters most for **Podcasts**, where zero is the *normal* result; Calendar
  and Health keep failing loudly on nothing, because for those two an empty
  answer and a refused permission are the same answer.
- Exports are git-ignored (`written-distillation-*.csv`) — they are personal
  data and must never enter history.

## Signing in: three routes, but only one of them creates an account

**All three routes open a session; only phone creates an account.**
`supabase/functions/resolve-signin` refuses any Apple or Google session whose
`public.users` row has no phone, and deletes the orphan Supabase just made — the
`id_token` grant signs up and signs in with the same call, so "there is no
account for this identity" is only knowable *after* one has been made. Apple and
Google are therefore *sign-in for an existing, linked account*, and `SignInView`
says so on screen before the refusal can happen.

Two consequences reach beyond the sign-in screen. **An App Store or TestFlight
reviewer cannot create an account by any route they control** — see the
demo-account section below. And **`AuthError.noLinkedAccount` is the correct
behaviour**, not a bug to be fixed the next time somebody reports that Sign in
with Apple "doesn't work".

**A button that does nothing is worse than an absent one.** Three of the four
launch-screen buttons once authenticated nobody: no session, no `route(for:)`,
no `auth.users` row, and the account was gone by the next launch because
`initialRoute()` reads the Keychain. It cost a day spent in the discovery
publisher, the feed and the photo pipeline — **"the account doesn't exist" is a
hypothesis worth eliminating before any of the machinery downstream of it.**

- **Apple** — native `ASAuthorization`, identity token traded for a session.
- **Google** — the *same* PKCE machinery that connects YouTube, asked a
  different question. `OAuthProvider.googleSignIn` requests `openid email
  profile` and the `id_token` goes to Supabase's `grant_type=id_token`. No SDK,
  no client secret — a native client has none — and the dashboard side is this
  app's client ID in **Authorized Client IDs**, because Supabase validates the
  token's `aud` against that list.

  Two refusals in it are deliberate. It does **not** persist Google's refresh
  token: the one that matters is Supabase's, and saving Google's would file it
  under `AccountScope.current`, still `local` because the account being signed
  into does not exist yet. And `interactiveIdentityToken` never reuses a cached
  or refreshed token, unlike `validAccessToken` — reuse is right for reading a
  library and wrong for proving identity, where a token refreshed from the
  previous user's grant signs the wrong person in.
- **Phone** — Supabase's **Twilio Verify** provider. `sendOTP` / `verifyOTP`,
  sharing session adoption with the other two through `adopt(_:)`, which was
  lifted out of `exchange` because phone arrives from `auth/v1/verify` rather
  than `auth/v1/token` and needs the identical five steps. Two copies would be
  two places to forget the `UserDefaults` write that `AccountScope` reads.

**Route from the step, never from a constant.** `onSignedIn` calls
`route(for: onboardingStep)`. Hardcoding `.photos` is what skipped the
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

**The exposure is fraud, not traffic.** SMS pumping — driving OTPs to premium
numbers for a share of the termination fee — can burn hundreds overnight. Four
controls, in order of how much they buy:

- **Twilio Verify geo permissions, Hong Kong / Taiwan / US only.** Console →
  Verify → Settings → Geo permissions. **This is separate from Messaging geo
  permissions**, which look identical and do nothing for Verify traffic.
- SMS Fraud Guard on.
- Supabase SMS rate limit at **10/hour**, project-wide: a ~$29/day worst case.
  It is *not* per-user, so five testers in an hour is half the budget spent
  legitimately.
- **CAPTCHA deliberately not enabled.** On native iOS it means a WebView-hosted
  challenge and a token threaded into `sendOTP` — real work and real friction
  against an exposure the three above already bound. **Revisit the day that rate
  limit is raised for real volume.**

Twilio also gates sending behind **Trust Hub KYC**: an unapproved primary
compliance profile answers "Primary compliance profile is not approved" and no
SMS leaves. An Individual profile is enough for Verify and reviews in up to 48
hours; only toll-free needs a Business one.

## Launch routing: the first frame must already be the right screen

`RootView` picks one of five screens — `signIn`, `name`, `communication`,
`photos`, `home` — from a single `Route`, never a set of booleans that can
disagree. Two rules, each paid for once:

- **Decide synchronously.** Anything the first frame depends on has to be
  answerable without a network call. `SupabaseAuth.hasStoredSession` reads the
  Keychain and `restoredStep` reads `UserDefaults`; both are instant. Deciding
  from the Supabase token refresh meant the sign-in screen was drawn for two to
  four seconds and then replaced. `restoreSession` still runs and the server
  still has the last word; it corrects a route rather than choosing the first.
- **Onboarding steps are routes, not covers.** A `fullScreenCover` has to draw
  something underneath it, and the something was `SignInView` — so resuming on
  the photo page reintroduced the very flash the point above removed. Anything
  reachable *both* forwards from sign-up and by resuming a killed session belongs
  in the `switch`.

`restoredStep` mirrors two facts that live on the server (the name, and whether
the photo page has been shown), which lets a force-quit resume on the page it
happened on. Anything that moves them — `upsertProfile`, `loadProfile`,
`markPhotoStepSeen` — must call `cacheOnboardingStep()`, and `signOut` must clear
it along with `firstName` and `hasSeenPhotoStep`, or the next account inherits
the last one's answers and is never asked its name.

**`loadProfile` is the correction, and it is the whole of how a new phone skips
onboarding.** It runs inside `restoreSession`, before `RootView` recomputes the
route, and on each fresh sign-in path — `firstName` is in-memory only and
therefore nil on every cold launch. It reads all six facts `onboardingStep`
branches on and `adopt(_:)` fills any local store the device is missing, **one
direction only**: the local answer wins where it exists, because somebody may
have changed something on this phone a moment ago and be offline.

Three of those six had no column until `0034` — the interest set, the two
sliders, and `hasExplored` — and a `distilled_records` row cannot stand in for
one here, because records arrive with `RestoreService.hydrate()`, which needs
`AppShell`, which needs the route. **The data could not unlock the route that
would load the data.** Anything added to `onboardingStep` from now on needs a
column and a line in that select, or it reintroduces the same hole.

`-route birthday|name|gender|interest|communication|photos|home|signIn` opens
straight onto a screen (DEBUG only) — the onboarding pages otherwise need a real
account, which the simulator cannot provide. **`-birthday confirm|error`** seeds
a *state* rather than a screen, for the same reason `-reveal` does: both the
confirmation card and the red-bordered refusal need a tap to reach and `simctl`
can send none. `confirm` seeds a fixed date so the card reads back the same
sentence every run.

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
- New OAuth sources: add an `OAuthProvider` case rather than writing another
  auth service; `OAuthPKCEService` is provider-parameterized. Google *sign-in*
  is a second case on the same client — see `googleSignIn`, and note
  `persistsRefreshToken: false` on it.
- **`web/` is the website, and it is not part of the app target.** A static
  page, no build step, deployed as a Cloudflare Worker serving `./web` as
  assets — `wrangler.jsonc` at the repo root, and `web/README.md` for the
  deployment, the review flags and the two headless-Chrome traps.

  **Every file in that directory is published**, and the two config files being
  exceptions is what makes it easy to believe otherwise: Workers consumes
  `_headers` and `_redirects` itself so both answer 404, which reads as "notes
  are not served". They are. `README.md` was live at
  `https://written-stl.com/README.md` for a day, carrying the Google scope
  justifications. `web/.assetsignore` excludes it; **anything added there that is
  notes rather than site goes in that file in the same commit.**

  **A Cloudflare dashboard toggle can add a third-party script to this site
  without touching the repo**, and one did: Web Analytics put a
  `static.cloudflareinsights.com` beacon on every non-EU page load while
  `web/en-us/cookies/` told reviewers nothing is fetched from anywhere else. The
  CSP's `connect-src` in `_headers` refused it, so the promise held. Disabled
  2026-08-05 via Web Analytics → Manage site → **Disable**, and every `src` on
  every page is now same-origin. The check:

      curl -s -H 'Accept: text/html' https://written-stl.com/en-us/ \
          | grep -c cloudflareinsights          # 0

  **The header is load-bearing — injection keys off `Accept: text/html`, not the
  User-Agent.** A version keyed on the User-Agent answers 0 unconditionally and
  would have confirmed the analytics were off while the beacon was on all five
  pages. Run any such check while the thing is still switched on before trusting
  its zero.
- Pagination is capped by `AppConfig.maxPagesPerEndpoint` /
  `maxPlaylistsExpanded` / `maxSongsRated` so a distill finishes in seconds. A
  per-item fetch that can't be capped is a red flag — Apple Music's ratings pass
  was exactly that, one round trip per hundred library songs with no ceiling.
- **Independent fetches within a distiller run concurrently.**
  `AppleMusicDistiller.distill` is the shape to copy: one `async let` per
  independent endpoint, then the passes that depend on their results through
  `inParallel`, which keeps five requests in flight rather than all of them
  (unbounded fan-out trades a slow distill for a rate-limited one).
- **`Array.sort` is not stable in Swift.** Sorting messages on `sentAt` alone
  left rows with equal timestamps in a different order on every four-second
  poll, and the unread band — anchored to one message id — appeared to wander
  between them. Ties break on `id` now. `now()` is the *transaction* time in
  Postgres, so a batch inserted in one statement shares it exactly.
- **Version a cache file when its model gains a field whose absence means
  something.** `ChatStore` writes `Message` as JSON; `read_at` was added and
  every row written before decoded with `readAt = nil`, indistinguishable from
  genuinely unread — so an ancient message put a phantom unread band at the top
  of a thread and kept it there through every relaunch. The prefix is
  `written-chat-v2-` for that reason. **An optional that decodes to nil is a
  value, not a gap.**
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
  `nil` for *could not ask* so the caller is `if let`. A `Bool` in one file
  guarding an early return in another is a convention, not a guard.
- **A shared `lastError` is not a record of what failed.** Whoever writes it
  last wins, so a later success erases an earlier failure — a failed record
  `push` followed by a successful `pushBans` used to leave a lost distillation
  with nothing to say for itself. Anything that needs a reason takes the
  returned `String?`, which belongs to its own call. And **every `return false`
  on a push path sets `lastError` first**, or a dead session reports itself as a
  network problem.
- **Never guard a request on the stored `accessToken`.** It is a cache: a token
  lasts an hour and a cold launch has none until `restoreSession()` has been
  round the network, so somebody can be legitimately signed in with the property
  empty. `validAccessToken()` refreshes, and **`SupabaseAuth.currentUserID()`**
  is what to call when a request needs a user id — it awaits the token *then*
  reads the id. Reading `userID` first reports "not signed in" for a session
  that is merely not restored yet, which is how every fetch in `ChatService` and
  `LikeService` drew an empty Chat tab on every cold launch. `loadProfile` is
  the one deliberate exception, since `restoreSession` calls it having just
  exchanged a token and the accessor would re-enter.
- **`public.users.sex` means the gender somebody *chose*, and nothing else.**
  It was written by two things in the same vocabulary meaning different things:
  the gender step, through `Identity.columnValue`, and `pushDemographics`,
  carrying HealthKit's *biological sex*. Last write wins and Health re-distills
  every time it is connected, so HealthKit would eventually overwrite a chosen
  gender — silently, repeatedly, and worst for exactly the people it matters
  most to. `pushDemographics` now sends only `birth_year`; the `biological_sex`
  record is still in `distilled_records` for anything that genuinely wants it,
  which is a different question and should have to ask by name. **Two columns
  that accept the same words are one column with two meanings.**
- **A published contact channel is a claim; test it like one, with a round trip
  rather than a lookup.** `hello@written-stl.com` was named on all five site
  pages and in `SettingsView` while the domain had no MX record at all, so every
  data-rights request bounced. Records resolving is not delivery working — the
  same lesson as the analytics-beacon check, and `ReportSheet` had already caught
  the identical mistake with a phone number that rang nowhere.

## Iterating on the garden illustration

**Five illustrated stages, one per connected modality plus bare soil.**
`TreeSkeleton.make` maps 0-4 to sprout/shoot/branch/bough/canopy; beyond that the
generated tree takes over. Falling through to generated geometry at 4 reads as
the drawing breaking rather than as growth, which is why stage 4 has art.

**The badges' bob is driven by a clock, not by `repeatForever`.** A
`withAnimation(.easeInOut.repeatForever())` started in `onAppear` is replaced
permanently by **any** other explicit transaction touching the badge — including
its own arrival, since `hasBadgeArrived` and `hasShootBadgeArrived` flip inside
`withAnimation(.spring(…))`. Reported as "only the new icons float".
A sine of `TimelineView`'s date drives it instead: a pure function of time. The
schedule is **paused when the garden is not the visible tab** (`isVisible`, as
`ChatView` and `DashboardTab` already take one), since every tab stays mounted.
**Every badge reads the same clock with no phase offset**, so they read as one
plant breathing rather than four things drifting — and there is now literally
one clock, in `GrowProfileView.garden`, rather than one inside each badge.

**The bob goes into `.position`, never into `.offset`, and that is a rule about
the coach mark rather than about the plant.** An `.offset` is a render-time
transform: it moves the pixels and leaves the layout frame behind. The tutorial
cuts its hole from `anchorPreference`, which reports that frame — so a bobbing
badge sat up to **16.8 device pixels outside its own spotlight** against 9 of
clearance, and the obvious fix, freezing the badge under a mark, was subtler than
it looks: `TimelineView(paused:)` freezes `context.date` without resetting it, so
"frozen" meant *stopped somewhere in the cycle*, not *stopped at centre*.

`ModalityBadge.bobOffset(at:diameter:)` is static and the caller adds it to
`.position`, which *is* layout, so anchors carry it and the hole tracks the badge
frame by frame whether it is moving or held. Freezing became a decision about how
it looks. **The general rule: nothing may sit between `.tutorialTarget` and the
pixels that moves the drawing without moving the frame** — the arrival
`.scaleEffect` is the other one, and it is handled by making the mark wait for
the spring to land (`badgeSettle`) rather than by trying to see through it.

**Measured, not asserted.** `-tutorial badge` opens the step without a
connection and `tools/badge_hole_check.py` reads the screenshot: the badge's gold
ring fails a brightness test, which splits its hole into two lit components — a
ring of parchment outside the badge and the badge's interior inside it — so one
pass measures hole and badge independently and compares centres. It refuses to
measure a screenshot taken during the mark's 0.22s fade, because a partial dim
finds regions that are not holes and reports a failure that is not real.

**Badge positions must be read off `leafLift`, never off `displayedSkeleton`.**
`SeedlingArt.shoots(by:)` does not only filter by stage — past 3 it *blends*
every shoot toward its canopy shape, so one shoot id has different reach and turn
at bough and at canopy. The badge `ForEach` read the discrete `stage.extended`,
so that blend landed the instant `displayedSkeleton` was assigned — outside any
transaction, leaving `.position` nothing to interpolate, so bough-to-canopy
looked like the badges vanishing and reappearing elsewhere. `leafLift` holds the
same number, is set inside `withAnimation(extensionAnimation)`, and is what
`shootExtent` already used.

**The first shoot's badge is dropped further than the others** (`firstShootDrop`,
+0.031): every other badge is spaced from its neighbour by the pitch between two
shoots, while shoot 0's neighbour is the *cotyledon* badge, which hangs off the
leaves and is spaced by nothing. At stage 1 the two sat 7.5pt apart on 48pt
badges; they are 14.7pt apart now, with the other stages' closest pairs at 19.0,
29.1 and 46.3pt. Measuring these is easier than it looks: a badge's translucent
disc is `(236,231,223)` against `(243,239,233)` parchment, which finds filled and
unfilled badges alike — the gold ring only exists once a modality is connected.

Two things about the fourth badge. It sits *above* its shoot rather than beside
it (`shootBadge`), and it needs **full** outward travel: tucking it toward the
stem puts it on the cotyledon blade, which reaches further out at that height
than the shoot does. Shoots alternate sides going up (0.34 left, 0.52 right,
0.70 left, 0.80 right), so a new one belongs on the side the last one wasn't.
`StageSheet` derives its row count rather than hardcoding 2×2 — fixed at four
panels, a fifth stage would have been dropped silently.

The plant on "Grow your profile" (`Views/Tree/`) is hand-measured vector art
where the *loop* costs more than the change:

- **Drive stages from the launch line, never by patching the source.**
  `xcrun simctl launch <device> com.written.datingapp -route home -stage 3` seeds
  the screen as though three modalities were connected; `-stages all` renders
  every illustrated stage on one screen. **`-route home` is required unless the
  simulator holds a session** — `-stage` only takes effect inside `HomeView`. One
  build serves all of them; editing `TreeSkeleton.make` to force a stage costs
  two builds per look and leaves the tree dirty. See
  `Views/Tree/DebugLaunch.swift`.
- **One build per batch of changes**, not per constant. **One cropped,
  downscaled screenshot per iteration** — a full-resolution screenshot is ~1.5k
  tokens and answers no question a crop doesn't.
- **Measure, don't eyeball.** A script over the reference PNG costs ~50 tokens
  and gives a number; reading the image gives an impression. The watering can was
  rebuilt three times because it started from a mental archetype.
- **Reference measurements are already recorded** in the comments beside the
  constants they set (`SeedlingArt.swift`, `WateringCanOverlay.swift`).
- **Shared geometry affects every stage.** `leafTilt`, `leafletTilt`,
  `LeafSpine` and the blade profile are used by all four — a sign error in
  `leafletTilt` silently distorted stages 2 and 3 while fixing stage 4.
  `-stages all` is exactly this check.
- Rapid screenshot bursts and headless boots crash `backboardd` in the
  simulator. Recovery is `killall Simulator && xcrun simctl shutdown all`.

## The layout audit: what proves nothing overlaps

    ./tools/run_layout_audit.sh          # 5 iPhone widths x 2 text sizes
    python3 tools/layout_audit.py out/layout/*/

`WrittenUITests` dumps the accessibility frames of every reachable screen and
`tools/layout_audit.py` does the geometry, because a screenshot only proves a
screen looked right where somebody looked: the plant's four badges overlapped
and buried the seedling on an iPhone SE while a 17 Pro looked perfect. Four
things it is easy to get wrong:

- **`-solo 1` is required, and it is not a convenience.** `AppShell` mounts every
  tab and hides the rest with `opacity(0)`, `allowsHitTesting(false)` and
  `accessibilityHidden(true)`, and **XCUITest honours none of the three** — 543
  overlaps, none of them real.
- **Never `descendants(matching: .any)`.** It kills the accessibility server —
  `(ipc/mig) server died` after 167 seconds. Ask per element type instead.
- **The dumps come out of the result bundle**, via `xcresulttool export
  attachments`, which the driver script does for you; a UI test runner's `print`
  never reaches `xcodebuild`.
- **`tools/layout_allowlist.json` is judgement, not bookkeeping.** This app
  overlaps on purpose, so regenerating with `--update-allowlist` and not reading
  the diff is how the next real overlap gets buried. Keyboard keys are dropped
  (Apple's layout overlaps itself) but one of our controls intersecting the
  keyboard frame is reported as `under-keyboard`.

Widths from 375 to 440 catch geometry; the accessibility text size catches the
fact that **this app mixes two font systems** — `BrandFont` uses
`.custom(…, relativeTo:)` and scales, the 165 `.system(size:)` calls do not.
Discovery is **not** covered: it has no sample-data path and needs a real
signed-in session, unlike Chat's `-chat sample`.

## The two halves of the app

**Onboarding is a line; regular use is a tab bar.** They are different products
wearing one binary. Onboarding runs sign in → birthday → name → gender →
interest → communication style → photos → grow the plant → "People you will
see", and ends the moment **Explore** is tapped there.

**The birthday is first, and the ordering is the argument.** Everything after
it — a name, a gender, photographs — is data collected from somebody the app may
have no business collecting from until that question is answered. `minimumAge`
is 18, enforced in `DistillViewModel.setBirthday`, again in `BirthdayEntryView`
because the onboarding page runs two screens ahead of any view model, and a third
time in `HealthKitDistiller` for the date of birth Health reports. Apple's June
2026 guidance is explicit that an app teens may reach must be age-appropriate in
itself rather than leaning on platform parental controls, and reviewers test it
by typing a birth date.

**Continue on the birthday page does not leave it — it raises a card that reads
the date back in words.** `BirthdayConfirmCard`: "You're 27", "Born December 19,
1998", Edit against Confirm. This is the one answer in onboarding that cannot be
corrected later without a support request, and four glyphs in three boxes are its
least readable form. Three things about it:

- **It is an overlay, not a `.sheet`.** A sheet takes the keyboard down with it
  and gives it back on Edit, so the page would jump twice for a correction the
  user has not made yet.
- **The three refusals never reach it.** An impossible date, a date 130 years
  back, and being under 18 all stop at the field and turn the boxes red; drawing
  "You're 4" over a card asking whether that is right would read a refusal back
  as an acceptance.
- **`confirming: Date?` *is* the presentation state.** Non-nil means the card is
  up and names the date it is asking about, so the two cannot disagree — a
  separate `isShowing` flag beside a stored date can, and the failure mode is
  confirming a date the user has since edited.

**The fields are measured, not eyeballed** — three 119×56 boxes with 9-point gaps
inside 32-point margins on a 440-point screen, reproduced as equal shares so the
proportion survives a 375-point phone. `BirthdayFields.errorRed` is
`(240,72,72)`, brighter than anything else in the app on purpose. **A fill
threshold cannot measure these from a screenshot** — the boxes sit eight levels
above parchment with a soft shadow, and thresholding finds the shadow and reports
a box a third too wide. Measure off the *error* state.

**Gender is one answer and who you date is several, and the control says so.**
`GenderEntryView.Purpose.isSingleChoice` drives both the arity and the shape —
radios for one, checkboxes for many — because that shape is the only thing
telling somebody whether a second tap will replace their first. The single-choice
rows *replace* rather than toggle: a radio that can be tapped off leaves the page
with no answer and a Continue that refuses. The two pages **name the same three
cases differently** and both namings are right: "Male" is what you are, "Men" is
who you would date. **"Everyone" is a fourth row and not a fourth case** —
`DatingPreferences.Gender` still has three and that row ticks all of them; an
`everyone` case could not say "men and non-binary people".

**Every one of these steps writes its local copy first and pushes in a detached
`Task` whose result nobody reads** — right, since onboarding should not block on
a round trip for a value Postgres cannot refuse, but `needsBirthday` and
`needsGender` are answered from those *local* copies, so a push that failed is
never retried and never re-asked. `DistillViewModel.repairIdentityPush` is the
backstop, run from `restoreFromServer` on every launch and guarded on the server
actually disagreeing, in the same shape as `adoptStoredCommunicationStyle`.

**The communication step is two sliders.** It asks flirt level and response time,
because both are *boundaries* and a boundary set after the fact has already
failed at its job — which is why it comes before anything can message anyone.
Each bar is continuous under the finger and one of **four bands**
(`StyleBand.count`) to everything else: nobody can honestly place themselves at
0.62 of a flirt, and a number that precise invites a matcher to believe it. The
exact position is kept beside the band purely so the slider can be put back.
Flirt level carries **two vocabularies** and both are needed: the stored
`rawValue` is flat — `Low` … `Extremely High` — while the dashboard shows
`Platonic` / `Mild` / `Flirty` / `Freaky`, which is a good thing to read about
yourself and a poor thing to sort a database by. Response time is stored as its
tempo, and the sentence under it on the card sets the expectation.

**The flirt dial's geometry is fixed by one constraint, not chosen.** The
captions sit on **thirds of the card** and the arc's two legs stand directly
above them, which sets the opening angle:
`halfOpening = asin((0.5 - 1/3) / (diameter/2))`. So the gap is not a free
choice, and — the counter-intuitive part — **shrinking the dial widens it**,
because smaller legs still have to reach the same two points. `diameterRatio` is
60%, and the centre word is plain `.system(size: 14, weight: .semibold)` matching
`chronotype.label` beside it; scaled off the radius it grew with the dial and
read as a headline. **`FlirtGauge` owns its captions**, unlike every other card
here — "the legs stand above the words" is one geometric statement — and it is
the one thing that cancels the card's padding (`DashboardView.cardInset`),
because thirds of *the card* is not thirds of the card's content. They are a
stack row, not `position`ed below the arc, which hung them into the padding with
no gap beneath. Measure it, don't look — but **on a screenshot showing the whole
card**: `-scroll communication` pins the section under the pinned header and
hides the dial's upper half, reporting 52% for a dial that was actually 76%.
`-scroll photos` puts the card's top in view.

Two traps, both paid for while building it:

- **Adding a step re-opens onboarding for everyone who finished it.** The cached
  `restoredStep` said `done`, and it was — for the steps that existed when it was
  written. `restoredStep` therefore answers `.communication` when the cache says
  `done`/`exploring` and no style is stored, matching what `onboardingStep`
  computes live. On finishing, the next route is **asked for** rather than
  hardcoded to `.photos`.
- **The answers are collected before a view model exists**, two screens ahead of
  `AppShell`. They go to `CommunicationStyleStore` (UserDefaults,
  account-scoped), which is *also* what `needsCommunicationStyle` reads — so
  having an answer and having been asked cannot disagree, unlike
  `hasSeenPhotoStep`, which needs its own flag because that page finishes whether
  or not anything was picked. `adoptStoredCommunicationStyle` copies them into
  `user` records, after hydration rather than before, and is idempotent because
  it also runs on every launch as the repair for a sync that never landed.

Through all of onboarding the tab bar is absent: a bar would offer four exits
from a sequence whose whole point is that it has one. The garden therefore keeps
an arrow at its foot and a pull-up gesture.

**That pull-up is a reveal, and two things make it one.** `AppShell.page` hides
every unselected tab with `opacity(tab == which ? 1 : 0)`, which is right for a
bar and wrong for a drag, because during it *two* pages are on screen while `tab`
still names the one being pulled away — so the gesture revealed bare parchment
until the drag committed. `isDrawn` is the fix, the same shape of bug as
`DashboardTab` hiding the profile preview until its slide began: *a layer needed
during a transition, gated on a flag that only moves at the end of it.* The
second is **z-order**: the dashboard must be built before the garden. Hit testing
stays on `tab == which` even while both are drawn, so a finger travelling up the
screen cannot press a row it is only sliding past; and `gardenLift` returns to
**zero at rest**, since parking the garden off-screen would make every future
route out of the dashboard responsible for resetting it. `-reveal 0.5` holds the
frame and `-reveal 1` lands on the dashboard, because `simctl` can send no drag —
**the only way to screenshot Memories from a script**, since it is otherwise
behind a gesture.

**It did nothing at all for a while, and by two independent faults.** It set the
lift from a `background` `GeometryReader`'s `onAppear`, which can fire before the
parent is laid out — so `proxy.size.height` was 0 and the lift was nought. And
the two guards that zero `gardenLift` for an abandoned drag fire on becoming
active and on the first `tab` change, which is twice during launch, both times
after the flag had set its lift. Either alone was enough. `isDebugRevealing`
exempts it from both and the lift is re-applied on the size change.

Regular use is the reverse: the bar exists, so the garden gives up the arrow and
the pull-up and the dashboard drops its "Garden" button, gaining sign-out and
delete — both hidden during onboarding, since offering to destroy an account
beneath the button that carries on making one is an invitation to end the thing
by accident. `SupabaseAuth.OnboardingStep.exploring` marks the boundary and slots
into the machinery that decides the first frame synchronously, so a force-quit
mid-garden resumes correctly; `AppShell` owns the flag and every screen reads it.

## The tab bar, and why it must never inset

Four tabs: Explore, Chat, the garden, and Memories (the dashboard). Wish — the
bottle — is `ARCHIVED-WISH`: `MainTab.wish` and `BottleIcon` stay commented in
place so restoring it is uncommenting rather than redrawing. Nothing persists a
`MainTab`, so its raw values may shift when it returns.

**It overlays. It never takes layout height.** `promptsReserve` is what the
garden is measured against, so anything consuming height at the bottom of the
screen moves the plant — a regression this project has paid for four times.
Everything the bar needs comes *out* of the reserve rather than being added
under it, and `MainTabBar.overlayHeight` is derived from the bar's own height
plus its inset rather than guessed alongside it, because a guess was 22 points
wrong and cost the connected rows that space for nothing.

The garden's icon is drawn rather than named: SF Symbols has no potted plant on
iOS 16, and `tree` was standing in for something it was not.

## Discovery: the only two tables one user may read about another

Every policy in `0001` is `auth.uid() = user_id`, which made a feed of other
people impossible rather than merely unbuilt. Two tables open that up and no
more should without the same argument — and note `bookmarks` (`0035`) is *not*
a third: it names another user in a column, but only the owner may read the row.

- **`discovery_cards`** (`0007`) — a name, an age, a district, six photo seeds
  and derived `{domain, subject}` pairs. Deliberately **not** a view over
  `distilled_records`: enough for `Ontology.line(for:subject:)` to write a line,
  and nothing that could reconstruct a distillation. **Subjects only** — artist
  and channel names, things a sentence can be *about*.
- **`shared_posts`** (`0008`) — a video id and a sentence somebody chose to
  publish. `sharer_name` is denormalised for the same reason `display_name` is:
  `public.users` is `auth.uid() = id` and opening it for a byline is not a trade
  worth making.

Both split read from write, because who may *read* a card and who may *change*
one are different questions. Measured on 2026-07-29 from a real signed-in
session rather than argued from the policy text: 6 cards and 5 posts visible, 12
own records against 2528 that exist, 0 to an unauthenticated caller, and a
forged post naming another user refused with `42501`. **Re-run that probe if
these policies are ever touched** — a table opened for read is the one place in
this schema where a mistake is silent.

Six synthetic accounts populate it, seeded by `tools/seed_synthetic.py` with
full datasets rather than bare cards. It needs the `service_role` key, which is
why it is a script you run and not something the app can do. **And for a long
time they were the *only* people in it**: `DiscoveryService` reads
`discovery_cards`, the seeder writes six, and **nothing in the app ever wrote
one**, so every real signup was invisible. Not a bug in the feed — `0007` has
carried `own row` insert and update policies from the start and only the caller
was missing. `DiscoveryCardService.publish` is it, called from
`DistillViewModel.sync` so a card rides the same moment as everything else that
leaves the device. **The feed also never excluded the viewer**, now filtered in
the query with `user_id=neq.…` so it never crosses the wire: `DiscoveryModel`
already filters likes in three places that have to agree.

### Bookmarks

**A private note to yourself, and the privacy is the design.** `0035` is one
table with one policy — `for all using (auth.uid() = user_id)` — so the person
bookmarked cannot read the row, is never notified, and no trigger fires. A like
is addressed to somebody; a bookmark is addressed to nobody. Three things follow:

- **It is a real delete.** "Nothing in Postgres is ever deleted" describes the
  distillation record, not a list somebody curates, so un-bookmarking removes
  the row rather than annotating it. `0035` grants delete for that reason.
- **Bookmarking does not remove anybody from the feed**, unlike a like. Saving a
  profile is not answering it, so `bookmarked` is a set the card draws from and
  never a filter — and it stays live on a card you have already liked, because
  the heart and envelope are one invitation spent once while this is not.
- **`bookmarkedIDs()` answers `nil` for *could not ask*.** Assigning `[]` on a
  dropped request would draw every saved profile as unsaved. `load` leaves the
  set alone unless it got a real answer.

`BookmarksView` draws `DiscoveryCard` verbatim through a real `DiscoveryFeed`,
so the photograph and line selection are Explore's code rather than a second
copy. **One round, though** — `nextItems(visible.count)` and stop. The rotation
exists because discovery is endless; a saved list is finite, so repeating it
would make a list of four read as a list of forty.

It is reached from a bookmark icon **inboard of the cog** on the Memories
header, as a `fullScreenCover` like Settings — inboard because Settings is the
last thing on every bar in every app, and anything outboard of it moves the one
control people find without looking. Hidden during onboarding. The paper plane
that used to sit there is deleted rather than disabled: there is no URL scheme
and no profile page, so a share would open nothing, and an inert glyph that looks
pressable is worse than an absent one.

### The feed's rotation

`DiscoveryFeed` shows a person repeatedly with different photographs and
different lines each time — two of each, both drawn without replacement, on
independent cycles.

**The round order is fixed, and that is not laziness.** Requiring five profiles
between one person and their next means `q >= p` for everyone simultaneously
across a permutation, which only the identity satisfies; a repeated permutation
gives exactly `n - 1` every time, the most any ordering can offer.

**A like removes that person from the feed, but not on the tap — on the next
scroll.** Removing their cards the instant you double-tap takes the post out from
under the reader's thumb and hides the one piece of feedback the gesture has, a
heart they never see fill. `like` therefore touches nothing but `liked`, which
also keeps its failure path honest — nothing was removed, so an offline like that
reverts has nothing to put back.

`DiscoveryFeed` is not where the removal happens either. Its `people` is `let`,
so rebuilding the rotation to drop someone would reshuffle everybody mid-scroll.
`DiscoveryModel` filters the *output* instead, in three places that have to
agree: `load` builds the feed from the unliked, `extend` purges liked people from
`items`, and `extend` also drops them from each newly generated batch — miss that
last one and they return the moment the list grows. Three things it is easy to
get wrong. The purge sits **above** `extend`'s near-the-end guard, because a row
appearing is the only scroll signal this view has. It removes only indices
**strictly after** the one that appeared: taking out an item above the viewport
shifts everything below it upward and moves what is being read. And the top-up
loop is **bounded** — asking until six survive spins forever once everything left
has been liked, reachable with six synthetic accounts. An all-liked feed is not a
failure either: `load` must leave `failure` nil there so the empty state shows
rather than a network complaint.

Shared videos are interleaved every fourth item rather than mixed into that
machinery, since the separation rule is about people and a video is not one.
Their ids carry an **appearance number** for the same reason profiles' do: one
post recurring with one id hands `ForEach` duplicates, which is undefined
behaviour and hung the app outright.

## Embedding YouTube, which took six attempts

**The player will not run in a document with no origin, and an app-built page
has none.** Four ways of claiming one all failed:

    loadHTMLString with a base URL          -> error 152
    the same, plus an `origin` player var   -> 152 again
    loading youtube.com/embed top-level     -> 153, the referrer complaint
    a page served from a Supabase function  -> black, no error at all

A base URL resolves relative links and is not an origin, and a player parameter
is a claim. **Supabase cannot host the page** either: edge functions and Storage
both rewrite HTML to `content-type: text/plain` with
`content-security-policy: default-src 'none'; sandbox`, so the script never ran.
What works is `loadSimulatedRequest`, which gives the HTML the security origin of
a URL you name — and naming a **third-party** one, since the page had been
claiming to *be* youtube.com. It claims the project's Supabase host now.
None of that was deduced: five fixes were reasoned from a single error number
and all five were wrong, while the page's own console said `api: loaded`,
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
keychain read and the link parsing rather than sharing files. Synchronized
folders scope everything under `Written/` to the app target, and sharing files
means the `project.pbxproj` surgery that arrangement exists to avoid.

Three things the template gets wrong for this use. Its activation rule is
`TRUEPREDICATE`, which offers Written in every app's share sheet for photos and
contacts it cannot use. Its compose sheet pre-fills the text view with the
shared item, which published the URL as the caption. And **`INFOPLIST_KEY_*`
build settings beat the `Info.plist` file**, so the display name has to change in
`project.pbxproj` or the share sheet says "ShareToWritten". Where the row appears
in that sheet is iOS's business — ranked by use, no API.

## Likes and chat, and the upsert that column grants forbid

Proven end to end on a real device on 2026-08-01, against real rows: a like, an
accept, a message, a reply on the four-second poll, a decline. `0009` is fully
applied — the column grant and the `touch_conversation` trigger both confirmed by
behaviour, which is the only way to see them.

**`resolution=merge-duplicates` cannot be used on `likes`, `conversations` or
`messages`.** It compiles to `on conflict do update`, and Postgres checks
privileges when it *plans* a statement rather than when a conflict happens — so
it demands `update` on every column being inserted, whether or not the row
exists. `0009` revokes update on all three tables and grants back only the
narrow columns each side may answer with (`status, responded_at`; `read_at`),
precisely so a recipient cannot rewrite `liker_id` and forge a like. The
privilege wins, and the failure is **42501 on every attempt**. That shipped:
`LikeService.like` used it, so every double-tapped like in the feed was silently
refused — silently because the heart fills optimistically and `lastError` is
recorded and never shown. `ignore-duplicates` is the fix, giving the same
idempotence through `on conflict do nothing`. `ChatService.open` had already
documented the identical trap for `conversations` and the lesson did not travel
one file across. `SyncService` and `SupabaseAuth` still use `merge-duplicates`
and are fine: `0009` is the only migration that revokes update, so every other
table leaves `authenticated` its default privilege.

**There is a second precondition, and it is not a privilege — it is a policy.**
`on conflict do update` has to be able to *see* the row it might update, so a
table with RLS enabled and **no select policy cannot be upserted into at all**,
including when it is empty and no conflict is possible. `device_tokens` was
given insert, update and delete policies and deliberately no select policy —
one fewer place a token can leak — and every registration answered `403 … new
row violates row-level security policy … 42501`, which reads as a wrong
`user_id` and was nothing of the sort. `0021` adds it. So the rule is:
**`merge-duplicates` needs update privilege *and* a select policy.**

**A name in a chat was a copy of a copy.** `likes.liker_name` is denormalised
when a like is sent and `ChatService.open` copied *that* onto the conversation,
so a profile read "Chan Tai Man" in Explore and "Marco" in the chat header.
Names now come from `discovery_cards.display_name` through
`ChatService.cards(for:)`, alongside the photograph: it is the one place a
signed-in user may read about another, and a copy elsewhere is a second thing to
keep in step. The stored columns remain as the fallback, because `0009`'s insert
policy needs them at creation when no card may exist yet; `0031` refreshed the
rows already written. **The same gap existed on the two single-conversation
fetches**, so a thread opened from a notification tap drew the generated portrait
and the frozen name while the same thread opened from the list drew the real
ones.

**One invitation per person, and it is either a heart or a note.** Whichever was
used is red and filled and the other fades; both go inert. The card used to fill
the heart whichever route was taken and leave the envelope live, so a second
invitation could be sent to somebody who had already had one.

**`23503` means the person deleted their account.** Every foreign key in this
schema leads back to `public.users`, and deleting an account cascades from
`auth.users` through it. A discovery card outlives the account because
`DiscoveryFeed` is built once and scrolled rather than re-fetched, so liking
somebody who has just left failed with `violates foreign key constraint
"likes_liked_id_fkey"` on screen. `PostgREST.Failure` carries the error code now
rather than folding it into the message, and the feed removes them and says
"That profile is no longer available."

**Two accounts are needed to test any of this**, because RLS makes each half of
a conversation invisible to the other. `tools/chat_e2e.py` plays the second
person over REST — `users`, `like`, `reply`, `state` — and the six synthetic
accounts are real `auth.users` rows. A simulator cannot be the first person;
Sign in with Apple needs a device. **Read the database after every step rather
than trusting the screen**: the first accept in that run appeared to open a
conversation while writing nothing at all.

## Notifications: a like, a match, a message

Three events, sent from the database rather than from a phone — in all three the
person to be told is by definition not the person making the request, and their
session is the only thing that could reach their own devices under RLS. The path
is `likes`/`messages` trigger → `pg_net` → `functions/push` → APNs. **Proven end
to end on a device on 2026-08-05**, a row inserted into `public.likes` producing
the banner through a real ES256 signature and a real sandbox token.

**`pg_net` is fire-and-forget and that is the point.** `net.http_post` queues and
returns, so a slow or dead APNs cannot make a like fail. **But it is not
invisible from SQL, and believing it was cost an hour** — `pg_net` records every
response in **`net._http_response`**:

    select (content::jsonb ->> 'face') as face, status_code, created
      from net._http_response order by created desc limit 3;

The function's own log lines went unfindable for a known `execution_id`, and the
fix was to stop logging the diagnosis and *return* it. **Anything the function
needs to say should travel in the response body**, not only to `console`.

**The URL and the shared secret live in `private.push_config`**, a table in a
schema nothing is granted on, filled in by hand. Not a GUC (invisible to the
migration) and not a literal (a secret in git). The function is deployed with
**JWT verification off**, which is mandatory rather than lax: the triggers carry
no Authorization header at all, and the toggle demands a JWT signed by the
*legacy* secret, which this project disabled in the July rotation.
`PUSH_SECRET` and the `x-push-secret` header are the auth instead.

**Five things about Apple's side, each of which cost a round:**

- **A successful install proves nothing about push.** Xcode's automatic signing
  issues an `iOS Team Provisioning Profile`, and those carry
  `aps-environment: development` **whether or not the App ID has the capability
  enabled**, so the app signs, installs, and APNs even hands over a token. What
  actually checks is Apple's **Push Notifications Console**, and a *distribution*
  profile, derived strictly from the App ID.
- **It is a `.p8` key, not a certificate, and the two are not interchangeable
  here.** `functions/push` signs an ES256 JWT from a PKCS#8 key; a `.p12` has
  nowhere to go in that code, and Deno's `fetch` cannot do client-certificate
  TLS anyway. Keys never expire and need no CSR. `Certificates (0)` beside the
  capability is correct.
- **An APNs key must be created as "Sandbox & Production", and the page lets you
  create one that is not.** A single-environment key answers **`403
  BadEnvironmentKeyInToken`** against the other host — so a Sandbox-only key
  delivers every Xcode build's notification and refuses every TestFlight one.
  That shipped, and it read as *lateness* rather than failure. Two things found
  it, neither the phone: `results` in the function's response carrying APNs' own
  reason, and a send to somebody with **two** devices, where `["ok", "403 …"]`
  made the asymmetry impossible to miss. **`sent: 2` with `["ok","ok"]` is the
  only proof that both environments work.**
- **The token's environment is not bookkeeping.** APNs has two hosts with two
  separate namespaces: a development build's token answers `BadDeviceToken` at
  `api.push.apple.com`, and a TestFlight token fails the same way at the sandbox
  host. Both kinds exist here at once, so `device_tokens.environment` records
  which. `#if DEBUG` decides it.
- **Where permission is asked has been wrong twice.** iOS allows the question
  **once, ever** — a refusal is undoable only in Settings — so the moment decides
  whether notifications work for that person at all. Asked **on the first
  admirer**, it came one event *after* the like that would have used it; asked
  bare **on arriving at Explore**, it spent the single attempt cold on the page
  somebody had just tapped to see.

  It now shows **`NotificationPrimer`** — the app's own sheet, naming what
  arrives rather than asking to be allowed — and only somebody who taps *Turn
  on* is passed to iOS. A "not now" spends nothing and is offered again in three
  days. Fired from `AppShell.onChange(of: tab)` on reaching Explore or Chat,
  900ms after the transition, and deliberately nowhere near Health, which cannot
  present over anything else. **A refusal is said out loud**: `ChatView` draws
  one line for anybody in `.denied`, with a route to Settings — left unsaid,
  `device_tokens` stays empty and every notification reports
  `{"sent":0,"note":"no devices"}`, a *success*. `-push ask` exists because
  setting this up otherwise requires arranging to be liked.
- **`SUPABASE_` is a reserved prefix** and a secret using it cannot be created.
  The function reads the platform-injected `SUPABASE_SERVICE_ROLE_KEY`, which on
  a project migrated to the new key system carries the `sb_secret_…` value
  despite the stale name. A first draft preferred `SUPABASE_SECRET_KEY` — a name
  that can never exist — and would have fallen through forever without saying so.

**`create or replace function` does not replace a function whose *signature*
changed — it overloads it.** Adding `sender uuid default null` to
`private.notify` left `0020`'s five-argument version in place beside the new
one; `pg_proc` answered two rows. Nothing broke, which is the dangerous part:
every trigger passed six arguments and only the six-argument function matches
that. What was left was a **latent ambiguity** — both have four required
parameters and defaults after, so any four- or five-argument call matches both
and Postgres refuses it with `42725`, *from inside a trigger on `likes`*, where
the like fails rather than the notification. `0026` cleared the pair up and
`0027` drops before creating. **Changing a function's parameters means `drop
function` naming the old signature in full.**

### The banner is a person, not an app

`NotificationService` — the project's **third** target — turns each notification
into a communication notification: the sender's photograph on the left, their
name where the app's name would be, the message beneath. Proven on device
2026-08-05 for all three events.

**A `UNNotificationAttachment` cannot do this.** It puts a thumbnail on the
*right*, beside the app icon, and the banner still says "Written". The person
treatment needs **three things in three different places, each of which silently
does nothing on its own**:

- `com.apple.developer.usernotifications.communication` in `Written.entitlements`
- `INSendMessageIntent` in `NSUserActivityTypes`
- an `INSendMessageIntent` donated from the extension, then
  `content.updating(from: intent)`

**That Info.plist key needs a real file, because `INFOPLIST_KEY_` ignores names
it does not know.** `INFOPLIST_KEY_NSUserActivityTypes` was the obvious move and
Xcode wrote nothing at all — no error, no warning, a built plist without the key.
`Written-Info.plist` exists for that one key, at the repo root beside
`Written.entitlements` rather than under `Written/`, because that folder is a
synchronized group and a plist swept into Copy Bundle Resources ships twice.
**Read the built `Info.plist`, never the setting.**

**`updating(from:)` renames the title to the sender's display name**, which is
why `0027` passes `sender_name` and `subtitle` separately. Using the title as a
display name announces somebody called "Marco likes you"; the headline moves to
`subtitle`, which `updating(from:)` leaves alone.

**The photograph is signed server-side.** `functions/push` looks up
`public.photos`, signs a one-hour URL against the private `profile-photos`
bucket, and puts it in the payload; the extension only downloads, because
authenticating for itself would mean the shared keychain and a refresh inside a
process with a thirty-second life, for a picture. An hour because a notification
can wait on a locked phone. **Everything in the extension falls back to the plain
banner** — a missing photograph, an expired URL, a rejected intent — because a
notification that arrives looking ordinary is enormously better than one that
does not arrive.

Two smaller ones: `INPersonHandle` is `.unknown` rather than an email or phone,
because claiming either invites iOS to match against Contacts and put somebody's
saved contact photo on a stranger's profile; and `INInteraction.direction` must
be set to `.incoming`, since the default is outgoing and would teach Siri that
*you* messaged everyone who has ever messaged you. **The small app icon badged on
the avatar is iOS's** — every communication notification carries it and there is
no API to remove it.

## The semantic contract, and what it supersedes

**`Written-Semantic-System-v0.3.1` is the authority for semantic design, and
this app is not.** Its integration plan is written against this repository by
name — commit `8203353`, migration head `0041` — and says so outright: *"When
the current Swift/SQL implementation and the v0.3.1 contract disagree, the
v0.3.1 contract controls."* Its governing rule is **capture broadly in an
authorized private vault, promote narrowly into semantic evidence, expose only
purpose- and surface-authorized projections** — four separate decisions where
this app currently has one.

Everything below about the ontology, the dynamic profile, Memories and the
icebreaker is **still true of the shipping code and is now the legacy path**.
It is kept rather than deleted: the reasoning is still worth having, the code
still runs, and the cutover is six phases away. What changes is its status —
none of it is the authority any more.

| Named as superseded | Becomes |
|---|---|
| `Ontology.swift`, `mix`, `terms`, `classify` | Server-owned classification and mapping; legacy behind a flag during shadow |
| Client-authored `discovery_cards` semantics | A paginated server-owned RPC enforcing block, eligibility, revision and surface grants |
| `summary_distilled_records` as current state | Ingestion runs with membership, coverage, tombstones and validity windows |
| `seed_icebreaker` (`0036`) | Revision-bound frames requiring active match authorization; legacy themes are **not** migrated into validated facts |
| Title-keyed `BanList` removals | Assertion-specific no-reason RPCs; a title ban never becomes a concept-level negative |

**Two namespaces, and the distinction is load-bearing.** The reference chain
uses `private` for its own objects; this app already owns that schema
(`push_config`, `notify`, `collaborators`). Every semantic object is
`semantic_private` here.

**And the hazard is the grant, not the revoke** — the obvious reading is wrong,
and it took a clean replay to find out. Reference `001` revokes `service_role`'s
usage on `private`; measured on a from-empty install, `service_role` never had
it (`has_schema_privilege` answers false), and push works anyway because
`private.notify` is `security definer` and runs as its owner. What bites is
reference `002` **granting** `service_role` usage plus `select, insert, update`
on every table in the schema — widening access to `push_config`, which holds
the shared push secret, and to `collaborators`, which was put in an ungranted
schema precisely so nobody could mark themselves. "An adapted grant broadens
access" is the integration plan's own failure condition. `0042`/`0043` are
adapted for that reason and **no executable statement in either names
`private`**; re-test that whenever another reference migration is adapted.

**Which is also the argument for the replay itself.** Applying 41 migrations by
hand over weeks never proved they build a schema from nothing. Done once against
an empty project, the chain applied cleanly — and produced the measurement that
corrected this paragraph.

**The migration head is `0098` as of 2026-08-12, and everything through it is
applied to production.** `0066`–`0090` are the music concepts, the YouTube
vocabulary and policy, the scorer and its grants; the section below on the first
assertions sets out what each earned. The ledger exists now: `supabase_migrations` was absent
entirely — not empty, *absent* — because every migration had been applied by
hand, so `supabase db push` would have tried `0001` against a full database.
`supabase migration repair --status applied 0001 … 0041` came first, and
`0042`–`0049` were deliberately left unrepaired because they genuinely had not
been applied. **From now on `db push` is the deployment mechanism**, and
`supabase/DEPLOY.md` holds the procedure and the post-deploy numbers. **`0050`
went the same day on that mechanism** — one pending migration, one push, no
ledger work — and the checks came back right: RLS on with no policy, no client
role reaching it, zero rows, and the `private` ACL fingerprint identical either
side of the push.

Nothing about the product changed *at that deploy*: all seven feature flags
were seeded off, nothing in Swift read the new schemas, and the legacy path was
untouched. That is still true of the product surfaces — the legacy path still
draws every screen — but Swift now writes to the vault and records a fitness
grant, so read this paragraph as the record of one deploy rather than as the
current state. The
check that mattered came back exactly right — the app's `private` schema ACL
fingerprint is byte-identical either side of the deploy, and `anon`,
`authenticated` and `service_role` still have no usage on it.

**`0042` and `0043` ship no product behaviour.** Phase 0 installs the schema and
proves it upgrades cleanly. `004`–`006` become `0045`–`0047`, and the bridge,
projection and cutover migrations are app-specific. Nothing is read by Swift
until Phase 3 at the earliest, and §12's KMS design is a prerequisite of Phase 1
rather than a detail of it.

**That KMS decision is made: AWS**, and it is written up in
`semantic/docs/KMS_DESIGN.md`. The scheme names no vendor — `DECISIONS.md` files
the provider, the key hierarchy and the worker's host under *"not implemented or
intentionally deferred"*, all in one bullet, because they are one decision. So
choosing AWS also answers where the worker runs: Lambda on an EventBridge
schedule, which fits a worker whose CLI *requires* `--once` and which had no
host at all before, this project's only compute being three Deno edge functions
and a static site.

Two things from that document are worth knowing without reading it. **Crypto
erasure means deleting the user's wrapped-key row, never the KMS key** — one is
a routine deletion request, the other erases every user at once. And **the
ingestion identity gets encrypt-only while the worker gets decrypt**, so the
thing exposed to the internet can write into the vault and cannot read it back.

**Ingestion runs on AWS, and the argument that got it there was half wrong.**
The recorded reasoning was that a Deno function on Supabase needs a long-lived
AWS key in its environment while a Lambda assumes a role and needs no credential
at all. The first half holds; the second does not. **A Lambda cannot reach
`semantic_private` either** — RLS is on with no policy and `authenticated` has
no usage on the schema — so a write needs a Postgres credential. Hosting on AWS
does not remove the standing secret, it changes which one it is, and the two are
not equivalent: a leaked encrypt-only KMS key writes rubbish into the vault and
decrypts nothing, while a leaked `service_role` key reads and writes every table
in the project. On that reading the edge function was the *safer* host.

**`0052` is what makes AWS right rather than merely chosen.** The endpoint gets
`semantic_ingestor`, a Postgres role that can call exactly one `security
definer` function and holds no table privileges — 0 readable tables, 1 callable
function, verified in production. Leaked, it writes vault rows and reads none of
them back. Its password is set by hand and lives in AWS Secrets Manager, for the
reason `private.push_config` is filled in by hand.

**Proven by connecting, and the route was the risk.** The direct host
`db.<ref>.supabase.co` has **no A record at all** — IPv6 only — while Lambda's
egress is IPv4, so the shared pooler is the only free route, and Supabase
documents its username as `postgres.PROJECT_REF` while saying nothing about
custom roles. That was the premise the whole design rested on. Settled
2026-08-10 on the transaction pooler: `current_user` came back
`semantic_ingestor`, and reading `raw_source_records` came back **permission
denied** — which is the success case, and the entire argument for `0052`
existing rather than handing the endpoint `service_role`. Two smaller things
fell out: a project's pooler fleet is discoverable with a *deliberately wrong*
password, since Supavisor resolves the tenant before checking it and the two
failures otherwise look equally like an outage; and transaction mode does not
support prepared statements, so the Lambda's driver must have them off.

**`0053` closes a gap that only appeared while designing the Lambda, and it was
structural rather than an oversight.** Three correct facts left no way to
encrypt anything: ingestion holds `GenerateDataKey` and `Encrypt` and **not**
`Decrypt`, because §12 limits decrypt to the worker path; `0050` models one
*active* wrapped key per user, to be reused; and `0052` gives the role execute
on one function that cannot touch the key table. **A stored wrapped key is
unusable to the identity obliged to encrypt with it** — recovering it needs
`Decrypt`, and giving ingestion that would collapse the two-identity split that
is the whole point. `kms:Encrypt` on the payload is no escape either: it caps at
4 KB.

So **the data key is per *call*, which is inherent to a write-only identity
rather than a choice** — it cannot reuse what it cannot recover, and a Lambda is
stateless. `0050` already anticipated the shape: *"Retired is not deleted: rows
encrypted under it still name it."* Each call retires the previous active key
and records its own, so "active" means the one the latest ingestion used, which
is the only sense the word can carry when a key is never reused.

**The key and the rows travel in one statement**, because two calls have a
failure mode where ciphertext exists and the key to read it does not — that is
indistinguishable from data loss and no retry recovers it. And reusing a version
with a *different* wrapped key is refused outright: whichever ciphertext is not
under the stored key would be permanently unreadable, and a wrong key does not
announce itself. Refusing costs a retry; accepting costs the data.

Two traps in that migration, both paid for. **`revoke ... on schema public` from
one role does nothing**: usage there belongs to the `PUBLIC` pseudo-role, and
revoking it from `PUBLIC` would take it from `anon` and `authenticated` too. The
property that matters is the *table* count, not the schema flag. And the
`security definer` function is what avoids adding `semantic_private`'s first RLS
policies — a posture of "RLS on, no policy, everywhere" states in one sentence
and a posture with two exceptions does not.

The cost of AWS is verifying Supabase tokens ourselves, which is smaller than it
sounds — the project publishes a JWKS (confirmed live, one `ES256` key), so any
JOSE library verifies an access token against a public key **with no shared
secret**, and the user id is its `sub`.

**Phase 1 has started, and its first half ships no behaviour either.** Four
new files under `Written/Models/` — `SemanticSource`, `SourceEnvelope`,
`SourcePayload` and the `+Legacy` adapter — give the typed envelope §4 asks for.
Nothing constructs or sends one yet; `DistilledRecord` and `SyncService` are
untouched, because Phase 1 is *dual*-write and this is the half that did not
exist.

Three things about it are worth knowing without reading the files:

- **`health` against `healthkit` is a real seam.** Every distiller writes
  `source: "health"`; `semantic_private.sources` calls it `healthkit`. Neither
  is wrong and renaming either rewrites history in a table that is append-only
  by design, so the translation lives in exactly one function
  (`SemanticSource.appSourceCode`) and a test pins it there.
- **A `data_type` now has to mean something.** `actionsByDataType` maps all 31
  distinct ones the shipping app can emit onto one of three answers: an action the server
  weighs, a real signal it does **not** weigh yet, or structurally not an act.
  Those are three different states and collapsing the middle one into the last
  is how the list of things still owed a decision disappears. It currently holds
  five: `heavy_rotation`, `library_music_video`, `top_track`, `top_artist` and
  `location/place` — and `top_track` is the sharp one, carrying an explicit
  `rank=N` and being the strongest listening claim either music source returns.
- **The vocabulary is checked from both ends, because neither end can see the
  other.** `semantic/tests/test_ios_envelope_contract.py` reads the distillers
  and fails if a `data_type` is unmapped; `tools/replay_contracts.sh` asks the
  *built* schema whether each claimed action is one that source actually
  weighs, since five migrations touch `action_weights` and reconstructing it by
  parsing SQL would be a third copy of the thing under test. Both were proven to
  bite by perturbation rather than assumed.

**The client half is built and switched off.**
`SemanticIngestionService` batches envelopes to the endpoint;
`PendingEnvelopeStore` is its durable queue, shaped like `PendingPhotoStore`
because that queue was memory-only and died with the app.
`AppConfig.semanticIngestionEnabled` is `false`, so `submit` and `flush` return
having done nothing at all — no queue, no request, no cost.

Three decisions in it worth knowing:

- **It is independent of `SyncService` in every direction**, which is the
  safety property rather than tidiness: nothing in it can make a distillation
  fail, and it neither reads nor writes that actor's `lastError`. A shadow path
  that can break the live one is not a shadow.
- **A batch is written to disk before anything is sent**, so a force-quit
  mid-upload leaves work to retry rather than losing it, and the bytes retried
  are the bytes that failed.
- **A permanent refusal is dropped, not retried.** A malformed batch the
  endpoint will never accept fails identically on every launch, so keeping it
  means uploading the same rejection forever. **401 is transient**, though,
  which is the non-obvious half: the token expired, the batch is fine, and
  treating it as permanent would throw away a distillation because somebody
  reopened the app after an hour.

**Dual-write is on for every source but YouTube and Spotify**, both of which
are excluded on licensing grounds rather than readiness — III.E.4.h and IV.2.1.a
forbid what the semantic stage is for. Apple Music went first, on 2026-08-11:
**1,225 rows in three batches**, 1.07 MB of AES-GCM ciphertext, one ingestion
run, three wrapped keys (one per call, one active).

**Per source rather than per build** — `AppConfig.semanticIngestionSources`.
Turning it on everywhere at once throws away the only thing shadow running is
for: a disagreement found in one source is a diagnosis, and in nine it is a
shrug. **The list now holds nine sources including `youtube`**, and the note
that used to sit here — that `music_library` is excluded because a subscriber's
phone returns the same library twice — no longer describes the code: it is in
the set. Whether that was decided or drifted is unrecorded, so treat it as
undecided rather than as the reasoning above still holding.

**Eight of ten data types matched the legacy count exactly.** The two that did
not are both the comparison's fault rather than the pipeline's, and getting them
wrong twice is worth recording:

- **`distilled_records` is append-only across every run**, so comparing against
  the table counted history. Read through `summary_*`, which is this file's own
  standing rule.
- **The summary view is a *union of items across runs*, not a snapshot.**
  `recommendation` reads 266 there against 171 in the vault because Apple
  returns a different set daily and the union keeps them all; the one
  `apple_music/apple_music_subscription` row is a historical item from a build
  that filed it under `apple_music`, where the distiller now writes `user`.
- **And the legacy path stores only *changes*** — `append_source_records`' trigger
  drops rows identical to the newest version — so this run wrote 118 legacy rows
  against the vault's 1,225 first-sight rows. Neither number is wrong and they
  are not comparable. **The comparison that means something is the *second*
  distillation**, where the vault should store roughly the delta the legacy path
  does, its fingerprint idempotency doing the same job as that trigger.

**`0048`'s provenance fix ran on real data for the first time.**
`AppleMusicDistiller` emits the subscription state as a `user` record during an
Apple Music run; it is in the vault as `user` evidence with connector
`apple_music`, which was structurally impossible before `0048` and needed
`0052`'s matrix row to be allowed at all.

**Two more findings from the second run, both the same shape: a value that
changes every pass makes a check vacuous.**

- **A pure-duplicate batch was still recording a key.** Re-sending the
  unchanged 1,225 rows stored nothing and wrote three more wrapped keys; four of
  nine protected nothing. `0053` accepted that trade on the grounds it would be
  rare, and it is not — key rows would grow with how often somebody distils
  rather than with what they have. `0054` writes the key *after* the rows and
  only if any survived the conflict, which is free because the function is one
  transaction and there is no foreign key demanding the key exist first.
- **`ingestion_run_live_identity_idx` can never fire**, and that one is
  recorded rather than fixed. It is a unique index on
  `(user_id, source_code, input_hash, connector_version)` over live runs — the
  contract's guard against opening a second run for the same input. Our
  `input_hash` is a SHA-256 over the *encoded records*, which carry `observed_at`
  and `ingestion_id`, so it differs every run and the index has nothing to
  catch. **Making it content-based is not a safe fix on its own**: runs are
  never finalized, so a live run lingers forever and a content-identical
  re-distill would then be blocked rather than deduplicated. Both halves belong
  to Phase 2, together.

**Runs finalize now, and finding out what that needed was the work.** Before
`0055`, production held 1,227 encrypted rows, seven runs all still `running`,
and `current_source_items`, `observations` and `ingestion_run_items` all empty:
capture was built and promotion did not exist, so nothing downstream could tell
that any row was *currently observed*.

`finalize_ingestion_run_v031` refuses a run with no **scope manifest**, counts
`ingestion_run_items` per scope, advances `source_state_heads`, updates
`current_source_items`, mints a revision and enqueues a worker job — and
`ingest_source_records_v031` wrote neither scopes nor items. `0055` adds both
and calls the finalizer on the batch the client marks `final`, **from inside**
rather than by granting it, so `semantic_ingestor` still reaches exactly one
function and `0052`'s assertion stays honest.

Three things the schema decided rather than us:

- **A scope is `(source, data_type, action)`, because
  `ingestion_run_scopes.action_type` is `not null`.** So a row with no action
  belongs to no scope, gets no run item and is never promoted — a `user/bio`, a
  calendar container, the subscription flag. Captured, encrypted, and not
  evidence. That is *capture broadly, promote narrowly* falling out of the
  schema rather than being imposed on it, and it is product-visible.
- **`partial`, never `complete`.** Only `complete` licenses expiring an item
  that went missing, and every Apple Music read is capped — so claiming a
  complete snapshot would be inferring absence from omission, which §10 forbids
  outright. Seen working: a `complete` scope with a wrong count is refused by
  name, and the whole transaction rolls back, so a failed run changes no current
  state.
- **A duplicate still needs a run item.** The insert is `on conflict do
  nothing`, so a duplicate returns no id — but the item was *seen* this run, and
  a head that missed it would read as the item having gone away. Ids are
  resolved by lookup, not only from `returning`.

**An Apple Music distillation is sometimes partial, and reports success either
way.** Two consecutive runs, measured: 17:01 returned **four** data types —
`recently_played`, `recommendation`, `library_album`, `library_artist` — and
17:08 returned all **nine**. Nothing was dropped in transit; the endpoint logged
zero refusals and the batch counts match exactly. The distiller simply returned
less. `AppleMusicDistiller.distill` runs its endpoints concurrently with one
`async let` each, so a failure in the library passes leaves the catalog ones
intact and the distillation still reports success — a partial result that looks
exactly like a complete one.

**The cause is one line, and it was a deliberate fix that was never finished.**
`distill` fires nine requests concurrently and every one is
`(try? await task) ?? []` — so **a failed request is indistinguishable from a
person who owns nothing**, and the error is discarded where it happens. Only
`MusicAuthorization` can end the run. Best-effort is right: library reads used to
be mandatory, so one refusal threw away recommendations and heavy rotation too.
What was missing is that best-effort was never made *visible*.

Three endpoints failing cost five data types, because two feed later work:
`library/songs` also carries `rating` (which works from its id list), and
`library/playlists` also carries `playlist_item`. It says so now —
`AppleMusicDistiller.Report` keeps each failure, `SourceStatus.partial` carries
it (`.done` could not say "worked, partly"), `shortfallMessage` names the
missing types in words on the prompt card, and the vault records a **`truncated`
scope with no items** for each, so a lost data type leaves a trace instead of
the run merely looking smaller. Why those three failed is still unproven — the
error was thrown away — but the shape points at throttling rather than a
permission state, since two library endpoints succeeded while three did not.

**This is what `completeness = 'partial'` was for, and it earned its keep on the
first occasion it could have.** Had those scopes been declared `complete`,
finalizing the 17:01 run would have expired **five entire data types** from
current state — 714 items, silently, because some fetches failed. Instead
`current_source_items` still holds all nine types and 1,427 items. §10's
"partial runs cannot infer absence from omission" is not a formality; it is the
difference between a bad afternoon for one connector and somebody's library
disappearing.

**`observations` is non-zero: 2,417, from real Apple Music distillations.**
The first semantic evidence this system has produced, across all nine music data
types, with `user/apple_music_subscription` absent because it carries no action.

**And the fingerprint no longer depends on the encoding, which is the actual
fix.** `fingerprintContent` unwraps the payload's discriminator and drops
`schema_version`, so both wire forms hash identically and the next encoding
change churns nothing. The near-miss inside that change is the part to remember:
its first version reduced any unrecognised payload shape to its first key, so
`{title}` and `{title, playCount}` hashed the same — a changed record skipped as
a duplicate and lost, which is the worst failure this function has. It unwraps
only shapes it recognises now and hashes anything else whole.

**It doubled the vault, and that was the price of the v2 wire form.**
`record_fingerprint` is computed over the payload, so changing the payload's
encoding changed every fingerprint and the whole library re-stored as new rows —
1,227 became 2,441. The append-only model doing exactly what it says: a changed
record is a new row, and the encoding changed even though the content did not.
Paid once, at 1,225 rows, which is the cheapest it was ever going to be. The v1
rows carry no observations and are history.

**Calendar dual-writes, and since Phase 2 it describes something.** 109 rows —
101 events, 8 calendars — under `calendar_distillation`, with the event count
matching the legacy path **exactly**. The eight `calendar` rows promote to
nothing at all, being containers rather than acts, and `event` produces *two*
scopes — `booked` and `scheduled` — which is the per-row refinement working, and
the reason the Calendar source exists.

**HealthKit dual-writes now, behind a consent somebody actually gave.** 390
rows — 366 `activity_day`, 24 `activity_hour` — under `fitness_connection`,
matching the legacy path exactly. The 24 is the
design in a number: an hour bucket for the whole year rather than 8,760 rows,
because the question is which hours somebody moves in. No `workout` rows, which
is the already-recorded absence rather than a loss — no test device has an Apple
Watch — and the legacy path agrees, which is what makes it an absence.
`biological_sex` never reached the vault, because `dualWriteToVault` asks
`SyncService.isLocalOnly` rather than reimplementing the rule.

**The grant is `0061`: `public.record_fitness_grant`, subject `auth.uid()` with
no parameter for it**, because a function that let a caller name whose consent
it recorded would be a function for forging consent. In `public` rather than
`api`, which is not an exposed schema. All four permission booleans are false —
matching, bio naming, icebreaker naming, controlled explanation — and
`FitnessPurposePrimer` says those refusals out loud, since a consent screen
listing only benefits asks agreement to something unstated. **Declining costs
nothing**: Health still connects and distils, and only the encrypted copy is
withheld.

**The old note, kept because it is why any of this exists:**
`guard_raw_healthkit_grant` refuses an active HealthKit row unless
`healthkit_use_grants` holds an active grant, and there are none. Enabling it
today would have every batch refused and — because
`SemanticIngestionService` drops a permanent refusal — the data would vanish
quietly. A grant is a recorded consent decision with its own `consent_version`
and four booleans gating matching, bio naming, icebreaker naming and controlled
explanation; writing one unasked would be fabricating consent, which is exactly
what that fail-closed guard prevents. §4's `FitnessPurposeGrantService` is the
work that unblocks it, and it is a product decision before it is a technical
one.

**Evidence is written by ingestion, not by the worker, and the schema is what
decided that.** `guard_observation_ingestion_run` refuses any observation whose
run is not still `running`, while `finalize_ingestion_run_v031` enqueues
`recompute_user` *after* the run closes — so a worker claiming that job finds a
`succeeded` run and every insert is refused. No grant fixes it. Classification
belongs where the plaintext already is: the ingestion Lambda holds it before it
encrypts it, and runs while the run is open. `ingestion_run_items` carrying both
`raw_source_record_id` and `observation_id`, with a check requiring at least
one, says the same from the other side.

**And the split survives, which is the part that had to be checked rather than
assumed.** `ingest_source_records_v031` is `security definer` owned by
`postgres`, so the observation insert — and the six `security invoker` triggers
it fires — run as the definer. `semantic_ingestor` gains **no table privilege at
all**: still one callable function, still zero tables, still unable to read a
row back. `0059` asserts exactly that, because it is the migration that could
have broken it.

**Calendar and HealthKit are captured and describe nothing.**
`private_observation_projection_is_valid_v03` demands a sanitised shape for
those two that is a *classifier's output* rather than a transcription, and §7
permits only the current Calendar classifier over Calendar rows. The endpoint
sends no `normalized_payload` for them, so their rows are stored encrypted and
contribute zero evidence — which is what §10's Calendar gate asks for rather
than a limitation.

**The worker exists, and it is the other half of the split.** `0057` gives it
`semantic_worker`: `bypassrls` and an **enumerated grant list** — ten tables
read, two written, nothing outside `semantic_private`, all asserted from the
catalog at migration time. Policies would have been the wrong tool: RLS here is
keyed on `auth.uid()`, which a batch processor with no JWT can never satisfy, so
a policy for this role could only be `using (true)` — a second mechanism that
decides nothing while the table grants still decide everything. `semantic_private`
therefore still has **no policies anywhere**, which remains statable in one
sentence.

`aws/worker` is the **vendored package**, not a reimplementation: `SemanticWorker`
and `PostgresJobQueue` come from `written_ontology`, with its lease tokens,
attempt limits, contract validation and fail-closed unhandled-job behaviour
already tested. Writing a second queue in another language would have meant the
thing in production was not the thing the tests cover.

**It builds the HealthKit coverage snapshot, and it no longer writes
observations at all.** `project_user` was removed from the handler in Phase 2,
which is the second half of `0059`: `guard_observation_ingestion_run` takes a
`for key share` lock on the run, needing `update` on `ingestion_runs` on top of
`select` — and a worker that could update a run could mark somebody's capture
complete. The privilege was the visible half; the real one is that an
observation belongs to the run that captured it, and a worker running minutes
later has no running run of its own. It failed every invocation with `42501` and
took the whole job down with it, which is how it blocked the fitness snapshot
sitting behind it. **~1,224 music rows captured before `0059` still have no
observation**, all behind a single run left `running` from before finalization
existed — the zombie-run problem rather than a projection one, and reviving that
call would have written their evidence into a run that will never finalize.

**Two packaging traps, both paid for.** `typing_extensions` must be named
explicitly — psycopg 3 needs it below Python 3.13 and pip drops it under
`--platform`, surfacing as the package's own *"install the postgres extra"*
message, which swallows the real `ImportError` and points somewhere else
entirely. And wheels must be resolved for `manylinux2014_x86_64`, or an Apple
machine bundles arm64 binaries that fail at *import* in a way that reads like a
typo. `build.sh` now checks the staged tree for every expected module, so both
fail at build rather than at invoke.

**The vault has been read back, and that is the premise nothing else could
substitute for.** 1,227 payloads had been encrypted and not one decrypted: if
the crypto were wrong the vault would be garbage and nothing anywhere would say
so. Measured 2026-08-11 — KMS unwrapped the data key **with the encryption
context**, which is what proves the per-user binding rather than merely the
cipher; AES-GCM decrypted; the envelope parsed.

**And the first row ever read back showed a defect.** Swift's synthesised
`Codable` for an enum puts the associated value under `_0`, a *compiler*
detail, and that was the wire form in the vault. Three reasons it matters more
here than it looks: the reader is Python and would have to know a Swift
convention to find the payload; **the vault is append-only and the ingestion
identity has no `Decrypt`**, so a row's encoding can never be rewritten; and if
Swift changed that convention, old rows would silently stop matching new code.
`SourcePayload` now encodes `{"kind": …, "value": …}` by hand and
`schema_version` is `written-source-envelope-v2` — **v1 rows exist forever and a
reader must handle both**, which is exactly what that field is for and its first
real use. Confirmed on a fresh vault row: `kind`/`value` present, `_0` absent.

**Proven on a real distillation.** Apple Music finalized with 9 scopes, 9
heads, 1,224 run items, 1,224 `current_source_items` and one worker job — and
the number that matters is 1,224 against 1,225 captured. Every action-bearing
pair promoted one for one; `user/apple_music_subscription` promoted **zero**,
because a fact about an account is not an act. The rule shows up as an integer.

**And `0055` could throw away a whole batch, which the first probe after it did.**
A run of entirely unpromotable rows has no scope, the finalizer refuses that,
and because finalization shares the insert's transaction **the rollback took the
captured rows with it** — production went from seven runs to seven and stored
nothing. Not a probe defect: every `user` distillation has that shape, since
all its data types are `notAnAction`. `0056` finalizes only when the run has a
scope and otherwise leaves it `running` and inert. **Capture must not depend on
promotion**, which is the governing rule read the right way round.

**Dual-write runs on its own detached task, and that is the safety property.**
`DistillViewModel.sync` calls
`dualWriteToVault`, which derives envelopes and submits them on **its own**
detached task at `.background` — never sharing a task or `syncFailure` with the
legacy push, since a slow endpoint must not delay the real outcome and a shadow
problem must not be reported as a lost distillation.

**It applies `SyncService.isLocalOnly` before deriving anything**, and that is
the single most important line in it: `health/biological_sex` never leaves the
device, which is a promise in `PrivacyInfo.xcprivacy` and on the website, and a
second upload path is precisely how such a promise stops being true without
anybody deciding to break it. The rule is *asked for* rather than reimplemented,
because refusing to send and refusing to forget are one decision made in one
place.

**Refusals are counted, never swallowed.** A `data_type` nobody has mapped would
otherwise show up as a batch quietly smaller than the distillation it came from
— the hardest kind of gap to notice, because the numbers still look plausible.

**Coverage measured against every row production has ever held: 6,148 of 6,148
derive**, none unmapped. 6,082 carry an action the server weighs, 61 are
structurally not acts (40 + 2 calendar containers, 4 subscription-state rows, 15
`user` profile facts) and 5 are `location/place`, which the server gives no
weight by its own decision. The comparison itself is **printed, not stored** —
there is no consumer yet, and giving it a table would be building Phase 2 early
in a codebase whose standing defect is results nobody reads.

**`-probe-ingest 1` is what settles the last premise**, in the manner of
`-probe-isrc` — and **the simulator cannot settle it**, which is worth knowing
before trying. Run there it correctly answers *no access token: you're signed
out*: a simulator holds no session, Sign in with Apple needs a device, and phone
sign-up needs an OTP. That exercises the flag, the wiring and the failure
message, and nothing past them. The endpoint needs a signed-in device or the
demo account's test OTP. only a signed-in device holds a Supabase access token, and only a
real token exercises the Lambda's issuer check, its KMS calls and
`ingest_source_records_v031` together. It writes a real encrypted row into the
prober's own vault, which is the point — a probe that avoided writing would
leave the write path exactly as unproven. Run it twice: the second receipt
should read `stored 0, duplicates 1`, which is the fingerprint idempotency
working. **`SUPABASE_ISSUER` on the Lambda is the one setting never checked
against a token Supabase actually minted**, and a wrong one refuses every
request identically.

**`SourcePayload+Legacy.swift` is scaffolding and is meant to be deleted.**
Deriving a typed payload by re-parsing `key=value;key=value` inherits every bit
of that string's lossiness — a value containing `;` or `=` was already
unrecoverable before the adapter saw it. The end state is distillers emitting
`SourcePayload` directly. It exists so dual-write can start without rewriting
nine distillers first, and so the coverage comparison Phase 1 asks for has two
paths to compare.

**And the keys have somewhere to live: `0050`.**
`raw_source_records` has carried `encryption_key_version not null` and
`encrypted_payload` since `0046` — the envelope pattern assumed and never
completed, with nowhere to put the wrapped key the version names.
`semantic_private.user_encryption_keys` is that place, `service_role` only with
RLS on and no policy, one live key per person by partial unique index. Its
behaviour is verified against a real chain rather than read off the DDL: a
second *active* key is refused, retire-then-insert works and is rotation, a
malformed ARN is refused, and **deleting the account cascades the keys to zero**,
which is crypto-erasure with nothing to remember to call. It ships no behaviour
and nothing writes it yet.

**The plan's three reserved numbers were overtaken entirely, and stopped being
worth tracking.** It allocated a bridge, then server projections, then cutover;
sixteen migrations of real work have landed since, so **projections and cutover
have no number yet and should simply take the next free one.** §5 permits it:
never *reuse* a number, skipping one is fine. What `0049`–`0065` actually went
to is the record worth having:

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

**That one character is worth keeping.** `0050` admitted a colon in
`key_version`; `raw_source_records.encryption_key_version`, which *names* that
version, does not — so a key could be created, used to encrypt, and then be
unstorable on the very row obliged to name it, with the refusal arriving at
ingestion time one service away from the mistake. It is this codebase's own
*two columns that accept the same words* defect with the sign flipped: two
columns that must accept the same words accepting different ones. `0046` wins,
because it is adapted from the contract and `0050` invented something. `0051`
also **asserts the two patterns match, reading them out of the catalog at
migration time** rather than trusting its own comment — proven by perturbing
the other side and watching it refuse.

**So the plan's numbers are no longer the app's, and its §-quotes are written in
the plan's.** §10's gate reads *"existing push/chat/profile behavior remains
green through 0048"* and §9 says *"do not reverse 0050 in place"* — the first
still means our `0048`, the second now means our `0055`. Read a number in
`WRITTEN_REPOSITORY_INTEGRATION.md` as a **role**, not as a filename;
`application_migrations` in the baseline manifest carries the mapping, which is
why each entry has a `role` beside its name.

Projections belong to Phase 4 and cutover to Phase 6, for three reasons, and the
third is the one that bites: `0048` **is** the additive boundary by §10's gate;
projections must match a `SemanticSurfaceService` that does not exist and their
acceptance gate — two adversarial users against real assertions — is unrunnable
before Phase 2; and cutover is irreversible by contract while **this project has
no migration ledger at all** — `supabase_migrations` is not an empty schema, it
is an absent one — so a routine `supabase db push` after linking would apply it
and break `DiscoveryCardService`, `DiscoveryService`, `MatchProfileService` and
`ChatService` for every installed build.

**What `0048` has to carry, and the reason it is not bookkeeping:**
`0042`–`0047` reference `auth.users` 31 times and legacy `public.*` tables zero
times, so the semantic schema is completely decoupled today and `0048` is the
single point where the two worlds meet. Its load-bearing change is a foreign
key: `0042:482-484` constrains
`(ingestion_run_id, user_id, source_code) → ingestion_runs`, which *encodes*
the provenance defect — an observation's source must equal its run's source, so
a `user` row inside an Apple Music batch is stored as Apple Music evidence.
`connector_source_code` and a repointed FK are what fix it, and
`finalize_ingestion_run_v031` (`0047:526`) has to be replaced to partition by
record source.

**One trap in `0043` that `0048` must not walk into.** It grants
`select, insert, update on all tables in schema semantic_private to
service_role`, and **`on all tables` binds at execution time, not going
forward** — so every table `0048` adds gets no grant unless `0048` grants it
explicitly.

### The first assertions, and the four faults between capture and them

**542 `concept_scores`, 81 `user_assertions`, and 13 concepts reaching two
independence groups** — measured 2026-08-12, on the first run that produced any.
Nothing in this system had ever had more than one group, and `motif_rules`
requires two as a check constraint, so until this every motif rule was
unsatisfiable by construction. (Those two figures are a snapshot of that first
run and not the current state: **65 active assertions per account** after the
hub, performer, era and sphere work later the same day.)

**And the scorer could raise a claim and could not withdraw one**, which is the
defect that outlived all four faults below. Its eligibility test sat *before* the
assertion lookup, so `UPDATE_ASSERTION` was reachable only with state
`eligible` — and the comment above it, *"an assertion that stops being evidenced
becomes `inactive`"*, described something the control flow made impossible.
Found by making hubs never assert, deploying, re-scoring, and watching three hub
assertions come back `eligible` from a run that had not touched them.

Two statements fix it, because only one of the two ways a claim stops holding is
iterated: scored-and-no-longer-eligible is demoted in the loop, never-scored-at
-all is swept afterwards. Both are `assertion_origin = 'inferred'` only — a
declared assertion is what a person said about themselves, and no absence of
evidence overrules it — and **the sweep is guarded on the run having scored
something**, since a fallen-over resolver must not read as somebody who likes
nothing. Its first application withdrew 27: three hubs plus **24 classical
performers the album-breadth change had disqualified weeks earlier and been
unable to retire**.

`score_user` had no unit test because it wants a database, which is why this
survived. It has one now, and what it asserts is **which statement ran** rather
than what was scored — the bug was never in the arithmetic.

`creator:le_sserafim` at strength 0.684, breadth 2, three sources: listened to
on Apple Music and watched across **nine separate repost channels** on YouTube.
That is the shape the whole exercise was for — `apple_music`, `music_library`
and `spotify` all carry the `music` group by design, so no music source can
ever be the second witness. The rest of the thirteen are the same K-pop cohort
plus `genre:classical` 0.963, `genre:pop` 0.941 and `genre:electronic`, those
last three arriving through `0076`'s provider-topic mapping.

**The scorer is `aws/worker/score.py`, inside the resolver's own run.** Not a
second run: a score belongs to the mappings it came from, and
`finalize_semantic_run`'s staleness check covers both only because they share
one. `strength` saturates rather than sums — `w/(w+6)` — because one concept
carries 3,893 `library_song` mappings and a hard cap would tie every strong
concept at 1.0. `stability` is 0.0 on a first run and that is a refusal: 1.0
would assert a property from the absence of observation.

**Four faults stood between a correct client and this, and each hid the next.**
They are worth keeping because none of them announced itself:

- **A 500 that should have been a 400.** A projection refusal is the *caller*
  sending a forbidden shape, and `SemanticIngestionService` classifies
  permanence by status code — `500...599` transient, everything else permanent.
  So one Calendar batch, staged by a build predating `semanticDataType` and
  carrying `event`/`entered_by_user` where the projection demands
  `calendar_event`/`scheduled`, was re-sent on every distillation for thirteen
  hours at the head of a FIFO queue, starving three YouTube distillations
  behind it. Nothing could see it: the queue drains only when new work arrives,
  and that actor deliberately shares no error state with the app.
- **A trigger error that named no row.** `private observations require an exact
  closed projection` is raised by a guard, so the operator got a bare 500.
  `projectionDiagnostic` reports each rejected row's *shape* — field names,
  payload keys, presence rather than value, deduplicated with a count — and
  named the cause on its first run. **It found in one line what four rounds of
  reading code had not.**
- **Fuzzy matching nobody reads.** `resolve_alias` falls back to a
  `SequenceMatcher` against every alias for any term with no exact hit. Music
  never noticed — its terms are curated aliases. Uploader tags are arbitrary
  free text: ~5,500 on one library, almost none matching, each scanning 1,512
  labels. **≈8.3 million comparisons a run, the entire 300-second Lambda
  timeout** — and every result was already discarded, since the fuzzy path
  returns only `CANDIDATE` or `REJECTED` and the loop skips non-accepted
  lexical matches. `exact_terms_only` drops those terms before the mapper sees
  them: 300s to 9s, removing no mapping that was ever written. It is also what
  `0078`'s resolver model already specified — `whole_tag_only`, `fuzzy: false`.
- **Row-at-a-time inserts** through a transaction pooler, now `executemany`.
  `pg_stat_statements` blamed the `semantic_runs` insert at 116s max, which was
  really later jobs blocking on `semantic_run_live_identity_idx` while the first
  held its transaction open — **parallel invocations manufacturing the
  contention being diagnosed.** Invoke the worker serially.

**And five migrations found five grants by watching five invocations fail**
(`0086`–`0090`, after `0063` and `0070`–`0073`). Each cost a deploy and a run to
learn a fact that was static the whole time. `0090` stopped guessing: read
`pg_trigger` for the tables being written, follow what each trigger calls, grant
the set. **That should be the first move, not the sixth.** One caution from
`0089`, whose first draft asserted so broadly it demanded privileges for Phase
4's dyad and surface paths and correctly rolled itself back — a check broad
enough to demand privileges nobody asked for is an argument for granting them.

### Classical performers, and why a code deploy re-scores nothing

**A performer is weighed by how many distinct albums they appear on, not how
many rows.** Measured: Pygmalion has 276 rows — the most of anyone in the
library — across *one* album, the St Matthew Passion counted once per movement.
Perlman has 47 across six, Hadelich 97 across three, the Berlin Philharmonic 100
across thirteen. One album means the performer came with a recording; several
means they were chosen more than once.

Below two albums a classical credit is weighed `0.02` rather than dropped — the
term still has to exist, because this file's own rule is that unresolved terms
feed `EmergentTermMiner` and *"dropping them would be dropping the ontology's
growth path"*. Three tests caught the first attempt, using Hilary Hahn as the
fixture, who is one of the performers the change exists to protect.

The final state, after the owner's review asked for it:

| kept | | dropped | |
|---|---|---|---|
| Bach 0.95, Mozart 0.73 | composers | Pichon, Pygmalion | 0.187 |
| Hadelich 0.82, Perlman 0.66 | soloists | Gardiner, Monteverdi Choir, EBS | 0.078 |
| Berlin Philharmonic 0.70 | 13 albums | Gilels, Podger | 0.078, 0.027 |

**A flat weight could not have done this**, and the arithmetic is why: `strength`
saturates as `w/(w+6)` and that curve is nearly flat where these concepts sat,
so a 70% cut moved Pichon 0.92 → 0.85. `0.02` is chosen *against the 0.35
eligibility bar*, not picked: 69 units become 1.4, which saturates to 0.19.

**Two escapes cost three rounds each, and both were found by grouping mappings
on `evidence_weight`** rather than by reading code — 138 rows at 0.02 beside 68
at 1.0 pointed straight at the cause both times:

- **`genres: null` on 68 of 276 rows** of one recording. `_is_classical` read
  the genre and never the title, on the principle that a stated label beats a
  derived one — correct when a label exists, silent when there is none. It falls
  back to a catalogue number *only* when no genre is stated at all.
- **`"Part II"` matched `Part`, an ASCII alias for Arvo Pärt.** The false
  composer stripped the title's prefix, `classical_work` then found no catalogue
  number, and 92 Monteverdi Choir rows read as non-classical. Fixed as a class
  rather than an instance: a composer prefix must *be* the prefix, since
  `Glass`, `Reich`, `Berg` and `Ives` were the same hazard waiting.

**And deploying resolver code re-scores nothing.**
`semantic_run_live_identity_idx` keys a run on
`(user, ontology version, resolver model, scorer model, input_revision,
input_hash)` — **the code version is not in it**, so a second run against
unchanged input returns `already_resolved` and does no work. That is right for
idempotency and it means a deploy alone can never change a score. Three levers
force a fresh run: a new distillation (bumps `input_revision`), a new ontology
version, or a new resolver model id. A distillation is the cheapest, and it is
the one to reach for.

**And when the library stops changing, a distillation is not a lever at all.**
There were two more gates behind that one and each was invisible until the
previous cleared. `finalize_ingestion_run_v031` enqueues `recompute_user` **only
inside `if changed_count > 0`** and keys the job on the revision alone — so four
ingestion runs of an unchanged library produced zero jobs. Ingestion is the only
thing that enqueues and it cannot see a model publish, so promoting a model
changed what the system *would* compute and nothing it had.
`semantic_private.enqueue_recompute_on_analysis_change` (`0093`) is the second
entry point, keyed on the revision **and** all three analysis ids, skipping any
user a run already covers. It is owner-only, so a migration is the only caller —
deliberately: enqueuing work for every user is not a client's to do.

**So the rule is: a migration that publishes an ontology version or activates a
model ends with that call.** `0093` wrote the rule and `0095`/`0096` broke it
within the hour, needing `0097` to supply what they owed. `0098` carries its own.

**And a model version that lags its code makes `semantic_runs` state something
untrue.** `missing_aware_late_fusion` 0.1.0 produced eight runs while the scorer
changed twice beneath it; `ontology_first_resolver` 0.1.0 did the same. Both are
versioned properly now (`0092`, `0094`, `0098`) — scorer 0.3.0, resolver 0.2.0 —
and the parameters live on the model row, where a later reader looks, rather
than in a commit message.

**One thing that had to be found by reading the logs: `prepare_threshold=None`.**
psycopg 3 auto-prepares a statement after five executions, and Supabase's
transaction pooler hands each transaction to whichever backend is free — so the
*second* of two back-to-back invocations tries to `PREPARE` a name the first
left behind and fails `42P05`. It failed for one account and succeeded for the
other, which reads as bad data rather than a driver setting. This file has
asserted since the pooler was chosen that *"the Lambda's driver must have them
off"*; nothing implemented it, and nothing had ever run five times on one
connection until the scorer's demotion statement arrived.

### An era is an axis; a scene is the claim

**A decade means nothing on its own, and this was measured before it was
believed.** `era:1970s` at 0.403 rested on ABBA, Stevie Wonder, Frankie Kao's
姑娘的酒渦 and Fritz Kreisler — anglophone pop, Mandopop and a violin recital,
three unrelated worlds under one assertion. The owner's reading: *"eras strongly
interact with language sphere — 1970 UK music vs 1970 cantopop is very
different."*

So `0095`/`0096` mint two families and the second is the point of the first:
**`sphere:*`**, five language spheres, and **`scene:<decade>_<sphere>`**, thirty
composites. Bare eras are scored and never asserted, through
`NEVER_ASSERTED_KEY_PREFIXES` rather than by kind — `era:`, `sphere:` and
`scene:` are all `concept_kind = 'topic'`, so the kind cannot separate the axis
from the claim.

That **implements** the owner's earlier *"80s German music would be a strong
personality"* rather than reversing it: that example is itself a scene, and the
composite did not exist when the era had to carry it alone.

Four things about it, and three were mistakes worth keeping:

- **A marked genre silences the unmarked ones on its row.** Apple writes both —
  Frankie Kao's rows are `Mandopop|Music|Pop`. Read as equals, a Taiwanese
  singer produced `sphere:anglophone` and his five 1970s rows became evidence
  for `scene:1970s_anglophone`, which then carried **all thirteen** of
  `era:1970s`'s mappings: the composite spanning exactly the worlds it was built
  to separate. The union across *rows* survives, so a bilingual act keeps both.
  Every anglophone figure fell when this landed, which is how you see it work.
- **Classical periods are never crossed with a sphere.** Baroque music is
  baroque in every language, so `scene:baroque_anglophone` would describe
  nothing and would compete with `era:baroque` for the same evidence. Thirty
  concepts, not sixty-five.
- **`0095` minted 35 concepts that could never resolve**, and its own assertions
  passed: it counted concepts and edges, and counting the right number of
  unreachable things is what a structural check gets wrong. The resolver matches
  a term against `normalized_label`, and `era:1970s` carries an `alternate`
  label of exactly `1970s` — prose labels never meet suffix terms. `0096`
  asserts *resolvability* instead, and its first draft stored the underscore
  form that `normalize_text` turns into a space, reintroducing the same silent
  failure inside its own fix.
- **That check then flagged `era:classical_period` and was wrong.** It stores
  `classical period` and resolves correctly. **The data was right and the check
  was wrong**, which is the more useful half of the lesson.

**The classical era distortion this started from does not exist.** `takes_decades`
gates decades to `DECADE_GENRES`, `Classical` is absent from it, and the 2022
Bach recording never contributed to `era:2020s`. The real gap was the opposite
shape: Apple files the passions as plain `Classical`, so `classical_eras`
returned nothing, classical rows got **no era at all**, and the six period
concepts had sat since `0044` with zero assertions. `COMPOSER_PERIODS` reads the
period off the composer — a fact about the work, not about the listener, and the
same distinction `classical_work` already draws. `era:baroque` scores 0.958 on
417 mappings now, `era:classical_period` 0.853 on 100.

### Phase 2, whose four bullets are all satisfied

§8 asks for four things: backfill under §7, run every source classifier and the
worker, compare old display terms against new assertions for diagnostics, and
**review every Calendar/HealthKit promotion plus a stratified sample of
abstentions** — that last one is a person reading output and is not
self-certifiable. All four are done as of 2026-08-12, on two accounts.

| | |
|---|---|
| backfill | **a no-op, by doing rather than arguing.** §7 prefers a fresh distillation to an import, the only account with legacy rows and no vault presence was Demo, and Demo distils from the same device. Re-distilled instead: 2,583 rows, 7 sources. No `legacy_backfill` run exists and none is needed. |
| classifiers and worker | running for both accounts, all sources |
| shadow comparison | `tools/shadow_compare.sql` |
| the human review | the owner read every Calendar promotion; all right |

**What is not finished is Phase 2's *premises*, and they are the entries in
Known gaps rather than in this list.** The eight zombie runs still hold ~1,224
unpromoted music rows; nobody has read the assertions end to end, only the
strongest of them; and the ontology is one library's.

**And the phase's outputs moved three times in the hour it closed.** Spheres,
scenes and composer periods landed after the shadow comparison was run, so its
16 / 44 / 37 split describes a scoring model two versions old. Re-run it before
quoting those numbers: the comparison is cheap and the assertion set is not
stable yet.

Where it started, for scale: measured 2026-08-11, **2,518 observations and every
table downstream of them zero** — `observation_mappings`, `concept_scores`,
`user_assertions`, `assertion_evidence`. Today both accounts hold **65 active
assertions** each, over 6,654 scores.

**Music resolution is blocked on content, not on code.** `ontology.concepts`
holds 45 rows — 19 `activity:*`, 13 `hub:*`, 5 `routine:*` and a few identity
and place seeds — and **not one of them is musical**, so resolving the 2,417
music observations would abstain on essentially all of them. Concepts have to be
authored before a resolver is worth running.

**HealthKit classifies, and correctly produces nothing.** `fitness.py` in the
worker runs the vendored `ingest_healthkit_rows` and records what it found in
`fitness_feature_snapshots`: 390 accepted, **0 rejected**, 366 activity days, 24
hours, no workouts, coverage `aggregate_only`. Zero habit candidates is what §10
requires of aggregate-only HealthKit, because every `activity:*` and
`routine:*_workouts` concept is derived from *typed workout sessions* and no
test device has an Apple Watch. Recording the abstention as a row is what makes
it reviewable rather than merely absent. `rejected = 0` is the load-bearing
number: `_parse_activity_day` refuses a row it recovered nothing from, so 366
days surviving is what proves the adapter's keys were read rather than silently
absent.

**`first_move` never reached the vault, and it was provable without decrypting
anything.** `HealthKitDistiller` writes `first_move=06:00` and `FitnessPayload`
read it with `extraInt` — `Int("06:00")` is nil, on all 366 days. The chronotype
signal, dropped at the envelope boundary with nothing saying so, because
`"%02d:00"` always emits a colon and `Int.init` always refuses one. `extraHour`
parses it now and `activity_hour.share` was added beside it. **A typed field
reading a string shape it cannot parse is the *two columns that accept the same
words* defect one level down**, and the check worth repeating is the one that
found nothing else: every other numeric extra is written as a plain integer.

**The classifier must read `current_source_items`, never `raw_source_records`.**
Nothing supersedes a prior revision — a row whose payload changed is captured
beside the old one and both stay `active` — and `ingest_healthkit_rows`
quarantines **both** sides of a lineage whose record fingerprints disagree,
having no trustworthy revision order in the legacy row shape. So the `first_move`
fix would have taken coverage from 390 to zero on the next distill, reading as
HealthKit having stopped working. Same rule as reading through the `summary_*`
views rather than the tables, one layer down.

#### Calendar: the classifier runs in its own Lambda

**Observations may only be appended to a still-`running` run** and `run_kind`
allows only `connector` and `legacy_backfill`, so there is no reprocessing run a
worker could open: classification has to happen at ingestion time, where the
plaintext is. Ingestion is 823 lines of JavaScript and
`written_ontology.calendar_semantics` is 1,283 lines of Python, so
`written-semantic-calendar-classifier` holds the vendored classifier and
ingestion invokes it synchronously. §7 permits only *the current Calendar
classifier* over Calendar rows, and a port would not be it — the same argument
that vendored the worker's queue.

**Titles go in and do not come back.** The package's own contract is that the
private title *"participates only in the HMAC lineage and is not returned"*, and
the stored payload is at most four keys: schema version, record kind,
`classification_state`, and an `artifact_type` from a closed set. A test asserts
no fragment of a title, address, organiser or email domain survives into it. The
classifier's IAM role holds `kms:GenerateMac` on the lineage key and **nothing
else** — no database, no `Decrypt`, no `GenerateDataKey` — and its lineage signer
is salted per user, because `content_lineage_hmac` is a column that exists to be
joined on and an unsalted digest would be a cross-account correlation handle.
**A classifier failure must never fail a distillation**: the rows are captured
either way and `CALENDAR_CLASSIFIER_ARN` unset is a deliberate off switch.

**101 events, 101 observations, 5 candidates** — 4 `travel_itinerary`, 1
`public_ticket`, each with a lineage; 96 excluded with none. The 68
`excluded_unknown` is the allowlist working rather than a gap: an event is
excluded unless positively recognised as a booking or an itinerary.

**Reviewed by the owner on 2026-08-12, and every promotion was right.** §10's
gate is a person reading output, so this is the only way it could close. All
nine promotions across both accounts — five flights and one tour booking, four
of the flights duplicated by Google Calendar — were confirmed, and the sampled
abstentions were confirmed as correctly refused in every stratum: work meetings
and webinars, public holidays and birthdays, and five surgical and outpatient
entries under `excluded_sensitive`, which is the category the allowlist exists
for.

**Reading it needed a tool, because the vault cannot answer the question.**
`observations.normalized_payload` is four keys and no title, and
`source_item_hmac` is salted with a KMS key only the classifier's role may use —
so *"review every Calendar promotion"* is unanswerable from stored evidence, by
design. `tools/calendar_review.py` re-derives each decision from the legacy row
with the same classifier and the same four offline catalogs, and a test pins the
constructor arguments because a missing catalog would silently reclassify and
produce a confident review of a classifier nobody deployed.

**It counted history on its first run**, reporting 9 promotions against the
vault's 5: `distilled_records` is append-only, David's 106 events are 158 rows,
and four flights were classified once per distillation. The `summary_*` rule
again. Demo matched at 9 and 9 on the same broken code because its duplicate
rows happened not to be promotable, so **only running both accounts caught it** —
which is the argument for the agreement check rather than for trusting the tool.

**The whole row speaks the schema's language, and that was learned twice.**
`0064` was written against `0060`'s eleven-argument body after `0062` had added
a twelfth, so `create or replace` **overloaded** rather than replaced — a lesson
this file already carried. Worse, its premise was wrong:
`guard_ingestion_run_item_v031` requires

    raw_row.data_type           = scope_row.data_type
    observation_row.data_type   = scope_row.data_type
    observation_row.action_type = scope_row.action_type

so an observation cannot hold a vocabulary of its own. A calendar row has to say
`calendar_event` **from the device onward**, which is why the fix lives in
`SemanticSource.semanticDataType` — the second translation seam beside
`appSourceCode`, and pinned by the same test, which also asserts nothing else is
translated. **`entered_by_user` became `scheduled` on the same evidence**: the
projection allows a calendar observation only `scheduled` or `booked`, so the old
action could be captured and could never become evidence — rows that land
successfully and describe nothing. The distinction it carried is intact under the
new name. Only `action_weight` still diverges, and no renaming reconciles it:
`sources` weighs `scheduled` 0.9 while the projection is pinned at exactly 0.0.

**Flights need the canonical title and bookings do not.** `_FLIGHT_TITLE_RE`
matches `FLIGHT to Los Angeles (UA 1103)` and nothing else — "Flight to Los
Angeles" is `excluded_unknown`, and the space is load-bearing since
`[A-Z0-9]{2,3}` is greedy and `(UA1103)` parses as carrier `UA1`. Reading the
pattern says what it accepts, not what a calendar contains: four real flights
matched. The booking path is far broader, recognising Eventbrite, Ticketmaster,
a dining reservation and a hotel stay, largely off the verified vendor host in
the `url=` extra the app already captures.

**Renaming a `data_type` re-stores every row and orphans its current items.**
`data_type` is part of the fingerprint, so the 101 events stored again as new
rows and `current_source_items` holds **202** for `apple_calendar` — the old
`event` items still `present` beside the new `calendar_event` ones. They carry
no observations and no scope the device still sends, and a `partial` scope
licenses no expiry, so nothing removes them. Inert history, the same class as
the v1 payload rows, and it will read as double counting to anyone coming to
that table cold.

### The dynamic profile

The official way one match presents themselves to another — distinct from the
dynamic *bio* (a line on a discovery card) and the *icebreaker* (a tip in a
thread). Laid out like an Instagram account, with three figures where posts /
followers / following sit: a follower count is a claim about how many people
know you, while these are what somebody's attention is made of, and there is
nothing to inflate.

**Reachable from exactly two places** — the avatar on an invitation
(`AdmirerRow`) and the avatar on a chatroom banner (`ConversationView`) — and
**the rule is in Postgres, not in which buttons exist**. `match_profile()`
(`0037`) is `security definer` and returns rows only to somebody holding a like
*from* this person or a conversation *with* them. A page reachable from two
buttons is a drawing; a function that returns nothing is a rule.

**The split is by how identifying a field is.** Name, age, district, photographs
and the ontology mix are on `discovery_cards`, which every signed-in account may
read. **The school and the bio are not, and must not be** — those come back only
through the gated function. Anything added to this page has to be sorted into
one of those two piles before it is drawn. **`match_profile` returns zero rows
for a refusal *and* for a match who filled in neither field, deliberately** —
distinguishing them would tell a caller whether an account exists.

**Switching the ontology stage on was the prerequisite, not a detail.** Exactly
one line in the app ever attached a `Domain` to real data and `Ontology.classify`
had **zero callers**: thirteen cases, one used. `Ontology.mix` is the wiring —
music by song count, `health_sports` straight to `playedSport`, podcasts and
calendar events through `classify`. Four things about it:

- **YouTube is not a parameter and must never become one.** Applying a term list
  to a channel name is *"infer or estimate the content category/type of a video
  or channel"*, which III.E.4.h prohibits. The absence is structural rather than
  a filter somebody has to remember.
- **Sports bypass `classify` by construction** — it skips `.playedSport` on
  every pass, because a term list matched against a title cannot tell watching a
  sport from playing one. A `health_sports` row already settles that.
- **The denominator is placed items, not all items.** Somebody with 300 songs
  and 4 podcasts is not "98% music" in any sense worth printing.
- **The three shares usually will not sum to 100**, which is honest.
  Normalising them would imply the other domains do not exist.

**`classify` matches substrings**, so "art" inside "Bartholomew" places a
podcast under `.art`. Tolerable for a percentage and not for a caption — which
is why captions only ever name *subjects*, which are never classified. Coverage
against a real library is unmeasured; **the Memories page below is what will
measure it**, being the first screen that puts a domain heading over a named
thing where anybody can see it is wrong.

### Phase 3: Memories draws assertions, and the legacy cards stay beside it

**Built 2026-08-12, and the server half already existed.** `0048` had shipped
the whole narrow-RPC surface §8 asks for — `api.list_assertions`,
`confirm_assertion`, `add_assertion`, `suppress_assertion`, `restore_assertion`
and `record_assertion_exposure`, every one `security definer` and scoped to
`auth.uid()` with no parameter for whose. Phase 3 was pointing the app at them.

**The difference from the legacy cards below is what a row *is*.** There a row
is a string a source produced, filed under a domain `Ontology.classify` guessed
at by substring, and striking one off goes through `BanList.Kind`, which removes
**every row whose name matches** — so banning an artist also bans a YouTube
channel called the same thing. Here a row is a concept with an id, and
`suppress_assertion` names one assertion. The contract forbids a title ban
becoming a concept-level negative; this is what makes that true rather than
intended. Both are on screen at once deliberately: §8 cuts Memories over while
discovery, the bio and the icebreaker stay legacy, so the two readings can be
compared.

**Two switches, and they are not redundant.**
`AppConfig.semanticSurfacesEnabled` decides whether the app asks;
`memories_reads` decides whether the server answers and is §9's rollback
contract, throwable without a release. `0102` is what made the flags decide
anything at all — they had existed since `0048` with **zero callers**, and
`emergency_privacy_kill_switch` described itself as a master stop and stopped
nothing.

**The `api` schema had to be exposed by hand**, which no migration can do:
Settings → API → Exposed schemas. Until it was, every RPC answered `PGRST202`
naming **`public.list_assertions`** — which reads as a missing function rather
than an unexposed schema. Found with one request from outside the app, before
any Swift was written, precisely so it would not be diagnosed from inside it.
`PostgREST.callFunction` sends both `Content-Profile` and `Accept-Profile`,
because an RPC is a POST that reads and setting one sends half the calls to
`public`.

**Three defects, all the same shape, and each hid the next.** The recurring one
this file names — *a call that can fail, a result nobody reads*:

- A **required exposure passed as `NSNull`**. `suppress_assertion` ends with
  *"matching assertion exposure is required"*: an answer must name the exposure
  it answers, so "I disagree" refers to a particular label at a particular rank
  computed by a particular score version. `record_assertion_exposure` was never
  called at all.
- The exposure then **requested and unparseable**. A `uuid`-returning function
  answers `"a1b2-…"`, a top-level JSON fragment, which `JSONSerialization`
  refuses by default — so the id read as nothing and the answer never ran. The
  request had succeeded; only the reading of it had not.
- **Both invisible**, because the failure was stored on the service and drawn
  nowhere. A refused removal looked exactly like an accepted one: the row
  vanished optimistically, returned on the next load, and nothing said why.

Every confirm and suppress failed from the moment they were written until the
owner tapped remove and asked whether it had stuck. **A probe proved the reads
and nothing proved the writes**, and the surface was called "behaving" on the
strength of the half that could be seen.

**`-probe-surface 1` is the read half's proof** and needs a device: a simulator
holds no session, so it correctly answers *"could not ask"* there. It reads and
never writes, unlike `-probe-ingest` — confirm and suppress are somebody's own
answers about themselves, and a probe that recorded one to test a network call
would be putting words in their mouth.

**What the page shows is `concept_kind`, and the owner drew the line.** *"These
blanket terms serve internal processing, but serve no purpose for user edit —
the terms shown should be well defined enough to strike off or understand,
either artists like Shiina Ringo or ABBA, or franchises like Re:Zero and
Footloose."* So `0108` filters `list_assertions` to `creator`, `work` and
`activity`, and the page went from 65 rows to 36.

**It filters one page and nothing else, which is worth stating because `0108`'s
own comment overstates it.** That comment says suppressing a blanket term
*"would quietly change how everything else is weighed"*. It would not:
`assertion_preferences` is read by the six `api` functions and two Calendar
guards, and **the scorer never reads it**, so a suppression removes a row from
one page and does nothing else. The migration is left as the record of what was
deployed — `supabase_migrations.schema_migrations` stores each migration's
statements, and editing an applied file is the `ARCHIVED-YOUTUBE` drift one
layer down — so the correction lives here. **The argument that survives is the
owner's own and needed no help**: *"1990s English-language"* is not a
well-defined thing a person can strike off or understand.

The 13 genres and 16 scenes/spheres remain asserted, scored and evidenced, and
are what Phase 4's server-owned discovery will match on. `sphere:korean` at
0.927 is in `user_assertions` untouched.

**An allowlist, so a new kind is withheld until somebody decides it belongs** —
the Calendar classifier's shape, and for the same reason: an internal kind
appearing on somebody's profile is worse than a nameable one being missed,
because only the first is invisible to whoever added it. **A user's own term
always survives it**, having no concept and therefore no kind, which is why the
rule is written as *a user term or an allowed kind* and why addition needed no
server change.

**Restore can only be an undo, and that is a gap rather than a design.**
`restore_assertion` takes three arguments where its siblings take four — no
exposure, correctly, since a suppressed assertion is filtered out of
`list_assertions` and was never on screen. But **nothing returns suppressed
assertions at all**, so a person cannot see what they have hidden in order to
press anything on it: a row hidden today cannot be recovered tomorrow.

**The work bar is 0.25 and is a judgement, not a measurement.** A creator
accumulates across everything they touch — Bach is on 417 mappings — while a
work is attested only by the songs belonging to it, so the same strength means
more evidence. Set from the owner's reading of three of their own: Footloose in
at 0.266, BanG Dream! out at 0.237, Re:Zero out at 0.047. It went in at 0.20
first, deliberately below both of the first two, on the grounds that seven
mappings against six is not a difference the scale can resolve; **what was
missing was a label on the second row, not a finer threshold**. One library and
one reviewer.

### Memories is the ontology's surface

**Still drawn, and now beside the assertion card rather than alone** — see the
Phase 3 section above. Everything below describes the legacy path.

`Ontology.terms` groups everything distilled under the domain it landed in, and
`DashboardView.domainSections` draws one card per domain. It replaced five cards
named after *sources* — MUSIC, MEDIA, PODCASTS, EVENTS, LIFESTYLE — which were a
picture of the plumbing. **Every term is the source's own string**: an artist, a
composer, a channel, a show, an event title. Nothing on that page is a word this
app invented, which is what keeps it a reading of somebody's data rather than a
set of labels applied to them.

**Striking a term off goes through `BanList.Kind`, never a new `.term` kind.**
`banTerm` carries a name *and* any id, dispatches to the existing kind, and
lands in `applyingBans` — so the records behind it are `markedRemoved` and stop
feeding the mix, the discovery card and the icebreaker. A ban that only hid the
row from this page would make the website's *never used, never shown, never
counted* untrue.

**YouTube goes through a different door, and it is structural rather than a
rule to remember.** `Ontology.youTubeTerms` cannot reach `classify`: placing a
channel under a domain by matching a term list against its name is exactly
*"infer or estimate the content category/type of a video or channel"*. It reads
`topics`, `tags` and `category_id` out of `extra` — the keys `YouTubeDistiller`
already writes — and a channel carrying none of the three is **absent, not
placed plausibly**. The premise usually offered for this page is backwards and
worth stating once: III.E.3.b forbids showing Authorized Data to *anyone other
than* its owner, so channel rows on somebody's own page are the permitted case,
while *aggregating* them is the restricted one.

Two consequences. **The YouTube cards empty themselves**: `0016` deletes those
strings 30 days after collection, so they vanish for anybody who has not
re-distilled in a month, and that must never be drawn as a failure. And **a
user-editable term list derived from YouTube data is Google's Content
Categorization and Tagging feature** — reading labels YouTube supplied is not
that feature, applying our own term table would be.

**The readings are not terms and stayed behind.** `lifestyleSection` still draws
the chronotype and the step average, because there is no entry behind "You start
at 06:40" for anybody to agree with. Sports left it — a sport is a named thing —
and live under `.playedSport`.

### Which sources may feed a model, and who may say so

**Four may, two may not, and consent does not move the line.** Apple Music,
Apple Podcasts, Apple Calendar and HealthKit carry no term restricting what is
done with what they return — Apple's rules are about the permission sheet and
what is disclosed, not about downstream use. **YouTube and Spotify both forbid
it**: III.E.4.h and IV.2.1.a respectively, the latter naming *"train a machine
learning or AI model or otherwise ingesting Spotify Content into"* one.

**A person can grant rights over their own data and not over a platform's.**
Spotify says so outright — IV.2.5 covers derived and aggregate data *"even if a
user consents to such transfer or use"* — so a willing collaborator changes the
consent question and not the licensing one.

Training data comes from collaborators rather than users, which is why the
published policy needs no new purpose: `web/en-us/privacy/`'s *Why we collect
it* describes what happens to a user's data, and a separate agreement covers a
collaborator's. **`private.collaborators` (`0041`) is how the two are told
apart** — a table in the schema nothing is granted on, filled in by hand, for
the reason `private.push_config` is there. A column on `public.users` would have
been settable by the account it describes: `0001`'s policy is `auth.uid() = id`
and `0009` is the only migration that revokes update, so anyone could have
marked themselves and put their own rows in a corpus. The query, source
exclusions included, is written at the foot of that migration.

**`Ontology.subjects` was reading a `data_type` that has never existed.** It
filtered `dataType == "song"`; `AppleMusicDistiller` writes `library_song`,
`heavy_rotation`, `playlist_item` and `recently_played`. So it answered `[]` for
every real library, and `discovery_cards.top_subjects` was empty for a reason
nobody had found. It reads `MusicHighlights.songTypes` and
`MusicHighlights.deduplicatedSongs` now, both made internal precisely so there is
one list rather than two that drift. **The preview fixture had the same disease
in reverse** — it wrote `top_track`, which no distiller emits, so the simulator
showed a populated music card while every code path that reads music saw an empty
library.

**Photo captions degrade subject → domain → nothing.** Two real libraries share
one or two specific things and almost never six, so captioning all six with
subjects would mean inventing four. The fallback is `Domain.sharedLine`, which
is still true and about both people; when that runs out the photograph carries
no caption, because a commonality that does not exist is the one thing this
feature must not manufacture. Each line is used once.

The bio is a `user` record like education and occupation, so it owns no column
and applies locally at once. **Capped at 30 characters at the keyboard**, not on
save: a sheet that accepts forty and then refuses is a dead end that cannot
explain itself. `-chat profile` opens the page with a sample whose captions
deliberately run out.

### The icebreaker

`0036` fills six columns on `conversations` at match time — a shared `theme`,
its `theme_kind`, a subject per side and a pronoun per side — and the app draws
one sentence at the top of the thread:

> You two both listen to J-Pop. You can talk about Ado, or ask her about Fujii
> Kaze!

**The first specific is the reader's own and the second is the partner's, so the
sentence differs per reader** — and the version shown to one of them must never
be shown to the other. That rules out a `messages` row twice: `sender_id` is
`not null`, so a system message has no sender, and one row is read by both
participants. It is drawn instead, which is also what makes it dynamic prompting
rather than a fixed greeting. **The flip happens once**, in
`ChatService.conversation(from:me:)`, the only place that already knows which
side the reader is; anything downstream deciding for itself whether `subject_a`
is "mine" is a second copy of that decision, and the day they disagreed somebody
would be told to ask their match about their own favourite band.

**Ingredients in SQL, language in Swift.** The trigger does set intersection and
knows no English; `IcebreakerCard` picks the verb, which varies by kind — "both
listen to J-Pop" against "both play tennis". Same reasoning that keeps
`Ontology.line(for:subject:)` in Swift: copy that needs a migration to change
will not get changed.

**Drawn as `DayDivider`'s pill, prefixed `Tips:`** — the same card fill,
hairline, shadow and muted 12pt, in a rounded rectangle rather than a capsule
only because it runs to several lines. A day pill is the one thing already in a
thread that is *about* the conversation rather than part of it, so matching it
puts the tip in that category without a label. **It must never read as a bubble.**
`-chat icebreaker` opens the sample thread with **no messages**, which is the
tip's habitat; `-chat thread` runs nine days deep and pushes the pill above the
fold, where `simctl` — which can send no scroll — cannot follow it.

Four things about the trigger:

- **It must read the base tables, never `summary_distilled_records`.** Those
  views are `security_invoker = on` — load-bearing everywhere else — which means
  a `security definer` function reading one is *still* filtered by the invoker's
  RLS. It would find the caller's rows, silently none of the partner's, and
  never error. The latest-row-per-item is done inside the function instead.
- **`source <> 'youtube'` is explicit and must stay.** No YouTube rows exist
  today, but an icebreaker derived from YouTube data is derived data under
  III.E.4.h, and the filter belongs there before the source returns.
- **`before insert`, unlike `0022`'s `after`.** That one writes a different row
  and must wait for this one to exist; this fills in columns on the row being
  written, which is only possible beforehand.
- **It never recomputes.** Fixed at match time — an opener that changed each
  time the thread opened would not be an opener. Stale after more distilling,
  which is accepted.

**No overlap means no card**, not a generic one, and a theme whose subjects came
back empty is discarded at the trigger rather than papered over in the view.
**Both pronouns sit on a row both participants read, deliberately**: gender stays
off `discovery_cards`, which every signed-in user may read, and this is the
narrow channel instead — two people who have matched and are about to address
each other. Anything unrecognised is **them**, including null, and a name is
never used to guess.

**It is not an embedding.** This is overlap counting over genres, sports and
creators. It produces the right shape of sentence and should not be described as
the same mechanism — when the ontology stage lands, this scoring is what it
replaces.

### The invitation becomes the first message

`0018` let a like carry a note, and once accepted that sentence had nowhere to
go — the admirers row disappeared with the like and the thread opened empty. A
trigger on `conversations` insert copies it in as a message from the liker,
stamped with the *like's* `created_at`.

**A trigger rather than app code, and that is forced.** The conversation is
created by the accepter, the message must come from the liker, and `0009` gives
`messages` an insert policy of `auth.uid() = sender_id`. The only client
positioned to write the row is the one person forbidden from writing it.

**It notifies nobody, tested by timestamp rather than a flag.** A message
carrying the like's time necessarily predates a conversation that exists only
because the like was accepted. Anything typed in gets `now()` and is later by
construction.

### An attachment with no caption

`0010` relaxed the body constraint so a photo could travel without words, and the
app satisfies `not null` with an empty string. The notification passed it through
unread, so an uncaptioned attachment produced the sender's name and **a blank
line** — worst with voice notes, since nothing in the app ever pairs text with
one. It says `📷 Photo` / `📹 Video` / `🎤 Voice message` now, and a caption still
wins where there is one.

**Emoji rather than SF Symbols, and that is the medium.** An APNs alert body is
plain text rendered by SpringBoard — no attributed string, no reach into the
symbol set the app draws with. The chat list uses `camera.fill` / `video.fill` /
`mic.fill` for the same three. While checking it, `ChatView.lastLine` turned out
to test only for `audio` and let everything else fall through to a camera, so
**an uncaptioned video called itself "Photo"**.

### Unread, which nothing had ever counted

`read_at`, its policy and its column grant have existed since `0009` and nothing
used them until `0030`.

**The icon badge is set from two ends and needs both.** The count travels with
every message notification, which is what keeps it right while the app is
closed — the only time anybody looks at it. The app recomputes on opening Chat,
on opening a thread and on each poll while one is open, because the server cannot
know something has been read until somebody reads it. A **null** badge means
*leave the number alone*, which is what a like and a match send: neither is an
unread message, and a 0 would wipe a badge that is correctly showing one.

**One request answers both the icon and the rows.** `unreadByConversation()`
returns a count per thread; the chat list draws each as a gold capsule and the
icon draws their sum. It needs no conversation filter and that is not an
oversight — `messages` is readable only to participants, so a bare query for
unread rows you did not send returns exactly yours. RLS is doing the join.

**The band in a thread is snapshotted before anything is marked read**, because
opening a thread marks everything read — that is what clears the badge — so the
boundary exists only in the first fetch, and recomputing would make it vanish
while somebody was reading towards it. **And it is read off the fetch, never off
`messages`**: that array is seeded from `ChatStore`, and a cached row whose
`readAt` is absent decodes as nil, which reads as *unread* and put a phantom band
at the top of a thread that `markRead` had nothing left to clear.

**Opening position is bottom when the unread fits and centred when it does not**,
decided by scrolling to the end and asking whether the band survived it — no
height arithmetic, and no guessing from a count that one photograph would
falsify. A band `LazyVStack` never built reports nothing, which *is* the answer.

**Taps route.** `NotificationRouter` records the destination rather than acting
on it, because a tap that launches the app is delivered during start-up, before
`AppShell` exists. `AppShell` moves the tab, `ChatView` opens the page, and a
conversation not yet loaded is fetched by id rather than waited for.

### Offline: the cache existed, and the failure erased it

**The chat list was empty offline, and it was not a missing cache.** `ChatStore`
has held the threads all along and `ChatModel.conversations` is seeded from it,
so they draw before any request is made. What emptied the screen was the fetch
that followed — and it did not merely blank the list, it **wrote its empty answer
back to `ChatStore`**, so the threads were gone until the next successful load.

`ChatService.conversations()` opened `guard let me = await currentUserID() else
{ return [] }`. Offline that guard is what fires: `currentUserID()` awaits
`validAccessToken()`, the refresh cannot complete, and it answers nil. **A guard
against exactly this existed and could not see it** — it tested `lastError`, and
that return path set none:

    let chatFailed = await ChatService.shared.lastError != nil   // false
    if !fetched.isEmpty || !chatFailed { conversations = fetched; ChatStore.save(fetched) }

`LikeService.admirers()` had the identical opening and emptied the admirers
banner the same way. **The fix is the type, not another boolean**: both return an
optional now — nil for *could not ask* — so the caller is `if let fetched { … }`.
Same treatment as `PhotoService.paths()` and `unreadByConversation()`, which were
already right.

Three things fell out of it, all about not asserting what was never asked:

- **`hasLoaded` moves only on a real answer.** It meant *a load finished*, which
  is why it was already wrong for notification routing.
- **The empty state has two sentences.** "No conversations yet" is a claim about
  an account; offline with no cache the app cannot make it. `couldNotReach`
  picks the other one.
- **No second banner while offline.** `AppShell`'s offline banner covers every
  tab, and the service's own message on that path is "You're not signed in" —
  true of the token it could not refresh, and nonsense to somebody on a train.

**Nothing about synchronisation changed**: the server is still the source of
truth, the cache is still replaced wholesale by every successful fetch, and only
an *unsuccessful* fetch stopped being mistaken for a successful empty one.
Threads themselves were never affected — `ConversationView.merge` unions the
fetch onto what it holds.

## Photos

`PhotoService` uploads to a private `profile-photos` bucket at
`<user_id>/<position>.<ext>`. **The position *is* the order somebody meant**, so
re-picking slot 2 overwrites slot 2 rather than leaving a seventh photograph
behind, and `slots()` keeps the position that `paths()` throws away — packing
0, 2, 5 into 0, 1, 2 would silently rearrange a profile its owner laid out.

**Nothing uploads on edit; edits are staged and flushed on the way out.**
`PhotoGrid` takes an optional `onEdit`, and which surface passes it is the whole
difference between the two callers: onboarding waits for its Continue button,
because somebody arranging pictures may yet skip. The dashboard has no button, so
the departure is the button — `stagePhoto` records, `flushPhotos` sends, fired
from `AppShell` on leaving the tab, on the app going away, and before signing
out. The staging map is keyed by position, so **the last write to a slot wins**.

- **`.inactive` is what catches a force-quit**, not `.background`: raising the
  app switcher makes the app inactive before the swipe kills it. A background
  assertion buys ~30s rather than ~5, and it must wrap **the work, not the
  call** — taken around `flushPhotos()` it covered a function that returned
  immediately at the re-entrancy guard while the real upload ran unprotected.
  Its expiration handler is not optional: a background task that runs out
  without one takes the app down.
- **The queue survives the app**, through `PendingPhotoStore` — Application
  Support, one directory per account through `AccountScope`, because a queue
  flushed into the wrong account uploads somebody else's face. **The intent is
  the file name, not a manifest**: `3.jpg` is a pending upload for slot 3,
  `3.removed` a pending removal. A directory listing cannot disagree with itself.
- **Encoded at staging, not at send**, so a retry after a crash sends the same
  bytes. That is why `flushPhotos` awaits outstanding staging tasks before
  deciding it has nothing to do, and why onboarding awaits staging before the
  route changes — it is a JPEG encode and a file write, not a round trip.
- **The flush is driven by staged edits and never by the array's contents.** A
  grid that has not hydrated yet is six empty slots, and anything reconciling
  the array against the server reads that as *delete everything*.
- **Removal is two writes**, and the object goes first: a row pointing at a
  missing file draws a broken picture, while a file with no row is merely
  unreferenced. **Saving is two writes as well** — the object and the
  `public.photos` row — and both must be checked, because an object in the
  bucket whose row failed leaves `paths()` answering "no photographs", which
  makes `DiscoveryCardService.publish` decline by design. That person then has
  **no discovery card at all, permanently, with no error anywhere.**
- The card is republished after any change, since it carries the paths.

**One photograph is enough, and nought is not.** `publish` refuses on an empty
`photoPaths`, so nought means no card ever. One is fine: `DiscoveryFeed.draw`
asks for `min(count, pool.count)`, so a person with one photograph shows one and
the card draws no dots, and `MatchProfileView` uses `photoPaths.first` as the
avatar. This paragraph used to claim two was the floor because the feed drew two
per appearance — it does not, and has not since `draw` took that minimum.

**The six boxes take photographs only, and that is a deliberate stop.**
`matching: .images` filters inside Apple's own picker process, so videos are
absent rather than shown and refused — `PhotoService.encode` has no re-encoding
pass and would upload a video as picked, failing at the bucket's 15 MB door
after the person had waited. Restoring it is `.any(of: [.images, .videos])`, the
encoder's commented branch, the MIME types and the `kind` column's `video`
option in `0015`, and the `AVAssetExportSession` that was the actual missing
piece. The view's five video branches stay in place and marked dormant; `load`
branches on what the item *is*, so the safety does not rest on the picker's
filter. **Chat attachments are a different feature and still take video** —
`chat-media`, 50 MB.

**`GeometryReader` lays its content out at top-leading, not centred.** A
`ZStack` takes the union of its children and `CropView.imageLayer` sizes itself
to *cover* the crop frame, so a landscape picture is wider than the phone and
all of it hung off the right — putting "Use photo" half off screen. Pin the stack
to the container it was handed, and not with `.clipped()`: the backdrop and
dimming layer deliberately `ignoresSafeArea`.

**Some things can be set but never changed** — the shape of bug to watch for on
the next field. A value captured once during onboarding, on a screen nobody
returns to, is a value with a typo in it forever. The name had this until
`NameSheet`; the biographics rows had it from the other side, rendering only
once they held a value, so nobody could put a first one in.

## Credentials

**Never commit `sb_secret_…`.** It is the successor to `service_role` and is
subject to no row-level security whatsoever. `tools/seed_synthetic.py` and
`tools/chat_e2e.py` need one; both read `SUPABASE_SECRET_KEY` from the
environment with no default, and that is the pattern for anything like it.

**Four keys have been exposed and every one of them went the same way: a chat
transcript, never the repo** — checked rather than assumed, `git log --all -S`
found none of them in any commit. The July pair were still live when checked
eight months later, which is the argument for rotating at the time.

**Rotate, then verify the old key is dead with a request** rather than trusting
the dashboard — a revoked key that still answers `200` is the failure this check
exists for. The project runs on JWT signing keys, so the legacy secret is
verification-only and there is no rotate button: what kills an exposed
`service_role`/`anon` JWT is **disabling the legacy API keys**.

**Nothing that ships is ever affected**: both targets carry only
`AppConfig.supabaseAnonKey`, a `sb_publishable_…` value that is public by intent.
If rotating a secret ever *does* require a rebuild, something has been put in the
app that should not be.

## Shipping: build numbers, TestFlight and review

**Every upload needs `CURRENT_PROJECT_VERSION` bumped, and it appears once per
configuration per target.** All of them must move together — the app and every
embedded extension sharing a build number is a hard requirement of the upload.
**Count it, never remember it**, including from this paragraph:
`grep -c CURRENT_PROJECT_VERSION project.pbxproj`. The number grows with every
target, and **un-embedding a target does not reduce it**.

**Held-back features are hidden by one line and marked `ARCHIVED-`, never
deleted**; `grep -rn "ARCHIVED-"` is the whole inventory. Two shapes:

- **A source** leaves `Modality.sources`. Its distiller, `OAuthProvider` case,
  `AppConfig` scopes and every read path stay compiled, so restoring it is an
  edit rather than a rewrite — proven by Spotify, which went back in one string
  with nothing to rebuild. Side effect: `recordSources` derives from `sources`,
  so `Modality.owning(source:)` answers nil for an archived source and its rows
  belong to no branch — harmless with no rows, which is why Spotify needed
  `purgeArchivedSources` and Google Calendar did not. **Less harmless than it
  reads, though**: `applyingBans` gates on `recordSources` too, so an archived
  source with rows silently stops honouring the ban list.
- **A whole target** is **un-embedded**, not deleted and not `FALSEPREDICATE`'d.
  It still builds and signs; it is simply not copied into the app. A
  `FALSEPREDICATE` activation rule would still ship the bytes and still demand
  the build number in lockstep.

**Verify in the archive, never in the build settings** — both of these, because
each only becomes true once baked in:

    A="$(ls -dt ~/Library/Developer/Xcode/Archives/*/*.xcarchive | head -1)"
    ls "$A/Products/Applications/Written.app/PlugIns/"
    plutil -p "$A/Products/Applications/Written.app/Info.plist" | grep MinimumOSVersion

**An embedded extension's `IPHONEOS_DEPLOYMENT_TARGET` must not exceed the
app's.** Xcode gives a new target the *SDK* version by default, so
`ShareToWritten` was created at 26.5 against the app's 16.0 and shipped that way
twice — anyone below 26.5 got an app with no share extension in it.

**A purpose string is demanded for the API you *could* call, not the one you
do — and the deployment target decides which key's name.** `ITMS-90683`, twice:
`NSHealthUpdateUsageDescription` for an app that never writes to Health (the
entitlement permits writing, so the string is required), and
`NSCalendarsUsageDescription` alongside `NSCalendarsFullAccessUsageDescription`,
because `requestFullAccessToEvents` is iOS 17+ and the app deploys to 16.0.
Adding a source that touches protected data means adding *every* key its
framework can reach, back to the deployment target. Both arrive after a
successful upload.

**Since 2026-04-28 a submission must be built with the iOS 26 SDK or later** —
unrelated to the deployment target, and a silent blocker that only appears at
upload. `DTSDKName` in the archive is the check.

**"Uploaded" is four states short of "a tester has it", and the gap is silent at
every step:**

    archived -> uploaded -> processed -> in a tester group -> review-approved -> Testing

Testers sat on build 1 for a week because build 8 was never *submitted for Beta
App Review* and App Store Connect held it at **Ready to Submit**. The
`Distributions` array in `.xcarchive/Info.plist` answers "was it sent" offline,
but `success` there means only that the bytes reached Apple — build 6 carries
that stamp and shows **Failed** in App Store Connect. **Read the TestFlight tab
for anything past the upload leg.**

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
working contact address all still bind — and 90 days is a commitment, since
testers lose the build.

**The unattended upload does not work on this machine; uploading does.**
`xcodebuild -exportArchive` sees no Apple ID and no App Store Connect API key,
so it cannot mint or use a *distribution* certificate — the only identity in the
keychain is `Apple Development`. Two ways out:

- Organizer → Distribute App → **App Store Connect**. Needs 2FA every time.
  **Not "TestFlight Internal Only"**, which sits directly above it in the same
  list and is a one-way door: it stamps the *build* as undistributable to
  external TestFlight or the App Store, and the only way out is a higher build
  number.
- **An App Store Connect API key** — Users and Access → Integrations, role App
  Manager. `AuthKey_<KEYID>.p8` in `~/.appstoreconnect/private_keys/`, then
  `-authenticationKeyPath/-KeyID/-KeyIssuerID`. The `.p8` downloads **once** and
  is a credential; treat it like `sb_secret_…`.

### The reviewer cannot create an account without help

Sign-up is phone-only and verified by SMS, and Twilio Verify's geo permissions
allow Hong Kong, Taiwan and the US only — so a reviewer outside those cannot
receive a code, and one inside still needs a number they control. Apple and
Google cannot rescue it: they refuse any identity that is not already linked.
**Apple can never be a demo route for any app** — `ASAuthorization` signs in
whoever the device is signed into, so there is no credential to hand over.
Guideline 2.1 rejections for "we could not sign in" are routine and slow.

**The answer is a test phone number.** Supabase maps a number to a fixed OTP
(`SMS_TEST_OTP`, bounded by `SMS_TEST_OTP_VALID_UNTIL`) and sends no SMS,
sidestepping the geo restriction, the Twilio cost and Google's 2FA at once —
while exercising the real sign-up path rather than a bypass. `auth.users` gets
the phone, `0033`'s trigger fires, and `resolve-signin` sees a real account. The
demo account was built this way on 2026-08-07 and its credentials live in App
Store Connect → App Review Information and nowhere else. **Remove the number
after approval**, or let the expiry do it — while it is live, anyone who guesses
the pair can open an account.

Two ways to get this wrong, both silent:

- **The username must be the ten *national* digits.** `PhoneNumberView` defaults
  to `Country.unitedStates` and `Country.format` truncates to ten
  (`Country.swift:58`), so a pasted eleven-digit `1XXXXXXXXXX` becomes
  `1XXXXXXXXX`, still passes `isValidNationalNumber`, and sends the code to a
  number nobody holds.
- **The Notes field is not optional here.** A reviewer who taps "Sign in with
  Apple" — the obvious button — is refused by `resolve-signin` with no way to
  know that *Create account* is the only door. The notes must name it.

**Do not build a demo mode that hides restored data until a Connect tap.**
Considered and rejected: it makes Connect report data that did not come from the
device, for one account only, which is 2.3.1(a) — *"no hidden, dormant, or
undocumented features"* — and 2.1 permits a built-in demo mode only *"with prior
Apple approval"*.

**`supabase/auth#1252` did not bite.** It reports that Twilio Verify always
routes to Twilio and ignores the test OTP. Tried 2026-08-07: the number works.
Kept only because it is the first place to look if that ever stops being true.

## Known gaps

Open as of 2026-08-08, ordered by what hurts soonest. **Delete an entry when it
stops being true** rather than letting the list rot — everything deleted from
this file is in `git log -p CLAUDE.md`.

- **A restore has never been run on a device that didn't already have the
  data.** `RestoreService` is wired into launch and checks out on inspection,
  which is an argument, not a test. Sign in to the demo account on an erased
  simulator and confirm the profile, the photographs and the garden come back —
  **this is also the reviewer's first launch.**
- **Notifications are proven on sandbox and untested on production.** Every
  `device_tokens` row so far reads `sandbox`; a TestFlight build mints a
  **production** token against a different host. Confirm a row reading
  `production`, then send one message and check the face still arrives.
- **The plant's position is checked now, and `(858, 1626)` turned out to be
  unrunnable rather than unrun.** That pair sat here from 2026-07-29 described as
  *the check that has caught every layout regression*, and **nothing anywhere
  recorded what it measures** — not the commit that added it, not the constants
  in `SeedlingArt.swift`, not any tool. A number with no method cannot fail, so
  it cannot catch anything. `tools/plant_position_check.py` replaces it: launch
  `-route home -stage 2`, screenshot, measure the illustration's dark mass, and
  compare against a baseline the tool itself produced. Verified 2026-08-12 on an
  iPhone 17 simulator — the garden renders correctly at stage 2, nothing
  overlaps, and the figures are in the tool. **It reports the base rather than
  the centroid**, because the centroid moves when a leaf is redrawn while the
  base is what `promptsReserve` and the header budget control, which is what all
  four recorded regressions were about.
- **Nothing lists a suppressed assertion, so a hidden row cannot be recovered
  the next day.** `list_assertions` filters `display_state = 'suppressed'` and no
  other function returns them, so restoration is reachable only as an undo in
  the moment it is removed — which makes a mis-tap permanent. It wants a server
  decision rather than a client change: a second RPC, or a parameter on
  `list_assertions`. The question underneath is what somebody is owed over
  their own profile, which is why it has not been guessed at.
- **Exposures are recorded when an answer is given, not when a row is drawn.**
  Honest for anchoring — the row was on screen, somebody just pressed it — and
  cheap, against one call per row per visit for a page most people only read.
  The cost is that `assertion_exposures` cannot answer *"what was shown and not
  acted on"*, which §10 lists among the shadow metrics and which wants
  display-time recording. Three orphan exposures from the failed attempts are
  already in that table, so it overstates what was considered.
- **Connecting Google Calendar on a phone that already has the Google account
  duplicates every event, and it has now happened.** Measured 2026-08-12 on the
  Demo account: **four flights promoted twice**, once under `apple_calendar` and
  once under `google_calendar` — same carrier, same flight number, same start
  time, different `item_id`. This is precisely what `hasGoogleAccountOnDevice()`
  exists to prevent, and the Apple rows say so themselves, carrying
  `cal_type=caldav` and `calendar=davidmok1998@gmail.com`.

  **The guard behaved as designed and its design has the hole**: it reads
  `EKEventStore().sources`, and *"returns false when calendar access has not
  been granted"* on the stated grounds that letting somebody connect a redundant
  source beats hiding one they needed. But the person who has not yet granted
  calendar access is exactly the person being offered Google Calendar, so the
  fallback fires in the common case rather than the rare one. Deciding it after
  Apple Calendar has been connected, or re-deciding once access exists, is the
  fix; `append_source_records` dedupes within a source and cannot see this.
- **The assertions have been read down the strong end and not to the bottom.**
  The owner reviewed the ranked list on 2026-08-12 and it produced a design
  change rather than a tick — the era/sphere work above came out of one question
  about what `era:1970s` contained. Confirmed as far as `creator:frederic_chopin`
  at 0.362, which is the concept nearest the 0.35 bar and therefore the useful
  place to stop. **65 active assertions per account now**, and what is unread is
  the middle: the K-pop and J-pop creators between 0.38 and 0.72 nobody has
  looked at one by one.

  One thing to check when that happens: **`genre:asian_music` at 0.942 is a
  container in all but name.** It is a `broader` parent of k_pop, j_pop,
  cantopop and mandopop, so it scores once for everything those four score for —
  the same tautology as `hub:music` one level down, and the hub rule cannot
  catch it because its kind is `genre`.
- **Whether HealthKit habit candidates are within the grant is unanswered.**
  The consent says *keep and use my activity to describe me to myself*, with all
  four booleans false; the next HealthKit unit computes fitness *assertions*.
  Keeping them off every surface is what the booleans do — whether computing
  them at all is inside what was agreed is a different question, and moot until
  a device records workouts.
- **Eight ingestion runs are stuck `running`** from before finalization
  existed, and one of them holds ~1,224 music rows that will never get an
  observation: evidence belongs to the run that captured it, and that run will
  never finalize. Deciding what to do with a zombie run is the prerequisite for
  making `input_hash` content-based, which is the other half of
  `ingestion_run_live_identity_idx` being able to fire at all.
- **App Store privacy labels are not filled in.** The manifest declares eleven
  data types — it gained `PhoneNumber`, `PhotosorVideos` and
  `EmailsOrTextMessages` on 2026-08-05 — and the questionnaire still says
  nothing. **The three answers that must agree are `PrivacyInfo.xcprivacy`,
  `web/en-us/privacy/` and the questionnaire**; a disagreement is a routine
  rejection and none of the three checks the others.
- **Identity linking is unbuilt.** Three sign-in methods mean one person can
  hold three accounts — a duplicate in the pool. Deferred for the beta; it wants
  deciding before launch.
- **A failed record upload is recorded but undrawn.** `sync` keeps the first
  failure on `DistillViewModel.syncFailure` and nothing renders it. A quiet
  surface on the dashboard is the open half.
- **Watch `birth_date` the first time somebody completes the birthday step.** As
  of 2026-08-07 it was null for every account, explained by all of them
  predating `c1a47d8` — which also means the age gate has never been observed
  reaching Postgres.
- **`health_sports` being empty is correct, and only one thing about it is still
  open.** Settled 2026-08-10 three ways. The database: 5 `health` connections
  and 6 `health_signals` rows carrying real data (`days_observed` 310–366,
  `average_daily_steps` 2,985–11,606), so HealthKit is answering. The code:
  `SyncService.swift:367` writes `health_sports` in the same `do` block as the
  `health_signals` POST at `:353`, which succeeded every run — so the only path
  past it is `sports.isEmpty`, and `LifestyleHighlights.swift:139-156` draws
  that list solely from `dataType == "workout"`. Zero sports means zero
  `HKWorkout` samples; the push is not broken and the derivation drops nothing.
  And the v0.3.1 handoff §4, analysing the real export independently, found 365
  `activity_day` + 24 `activity_hour` rows, no workouts, coverage
  `aggregate_only` — *"a correct abstention for missing modality"*.

  The likely cause is that **no test device has an Apple Watch**; steps come
  from the iPhone's motion coprocessor and arrive for everyone, while
  `HKWorkout` needs something recording sessions. **What is still open:** a
  declined Workouts toggle is indistinguishable from no workouts, since
  HealthKit returns a refused read as an empty set
  (`HealthKitDistiller.swift:560`) and nothing records the sample count. One
  line in the distiller's `Trail` (`:213-238`) would settle it.
- **The append/change-only path has never run from the app.** `0004`–`0006` were
  exercised directly against the database — an unchanged 553-row replay wrote 0
  rows, a change wrote 1 — but no distillation has gone through
  `append_source_records` from the phone. Distil Apple Music twice and confirm
  the second run writes only what moved.
- **CAPTCHA is off for phone sign-in**, with the 10/hour SMS rate limit standing
  in for it. **Revisit both together.**

### Deferred by decision

**Google OAuth verification, deferred until the hubs exist.** Decided
2026-08-05: submitting earlier means shooting the demo video against a pipeline
about to be replaced, and the same form carries the derived-metrics request,
which needs the ontology stage to describe. **Nothing about that defers the
policies themselves** — they bind every API Client, verified or not. Two traps
for whoever picks it up: Search Console must be verified as a **Domain**
property signed in as an Owner of Cloud project `672788849005` (verifying as the
wrong account is the standard rejection and Google does not say so), and the
consent screen at `console.cloud.google.com/auth/branding` must carry
`https://written-stl.com/en-us/` and `.../en-us/privacy/` **character for
character**, matching `SignInView.swift` — not `/privacy`, which 301s, and a
redirect is not agreement.

**YouTube and Google Calendar are archived, so nothing is blocked on this
today.** The Disconnect control has never been exercised against a real Google
account and the published privacy policy makes a 7-day claim resting on it; that
has to happen before YouTube comes back, not before the next release.

### Standing traps, not gaps

**The site is written from the app and goes stale silently** — a page cannot
fail to compile. It once described a one-sign-in-method app with no Google
Calendar and no notifications for a day after all three shipped, and promised
six times across three pages an in-app control for removing a single source,
which existed for nothing. **Adding a source, a sign-in method, or anything else
that leaves the device means editing `web/en-us/privacy/` in the same commit.**

**It happened again and worse: four pages said in six places that Written "no
longer connects to a YouTube account" and collects "no new YouTube data", while
YouTube was live with 731 rows.** A published compliance document asserting that
a live source collects nothing is the most expensive form this trap takes.
Corrected 2026-08-12, and the scope table gained `youtube.readonly` — that table
is what Google's verification form points at, so a missing scope is the one
omission it cannot afford.

**And the deploy target was wrong the whole time.** `wrangler.jsonc` named
`written-site`; `written-stl.com` is a custom domain on a Worker called
`written`. Every `npx wrangler deploy` created a *second* Worker and published
to it — success, every asset uploaded, a version id printed, nothing reachable
changed. It was convincing in the wrong direction: the apex served the old copy
**with our own `_headers` CSP on it**, `cf-cache-status` said `HIT`, and a
cache-busting query returned `HIT` too. Purging the zone changed nothing because
nothing was stale. What settled it was the account, not any amount of `curl`:

    GET /accounts/{id}/workers/domains  ->  written-stl.com -> written

The corrected deploy confirmed itself — *"Uploaded 4 of 4 assets (19 already
uploaded)"*, exactly the changed files diffed against what was genuinely live.
**Verify a site deploy by diffing a live page against the repo file**, not by
reading wrangler's success line.

Two words it uses precisely: **struck off** is the `BanList` pass, where
`markedRemoved` annotates `extra` and *keeps the row* — so the site says never
used, never shown, never counted, and does not say deleted. **Deleted** is
account deletion, the YouTube sweep and `SyncService.deleteSource(_:)`, which
are real deletes. The mandatory 7-day deletion clause is answered for YouTube by
its Disconnect control and for everything else by account deletion and written
request; deletion is immediate in every case, so 7 days is a ceiling kept for
the backups.

**One network sinkholes `written-stl.com`, and it is the network rather than the
machine.** On `wusm-wifi.wucon.wustl.edu` it resolves to
`sinkhole.paloaltonetworks.com` — newly-registered-domain filtering, and
`example.com` resolving correctly from the same resolver is what makes that a
decision rather than a fault. **Do not diagnose a deployment from a sinkholed
resolver.** Resolve over DoH and pin the answer:

    curl --resolve written-stl.com:443:104.21.7.174 https://written-stl.com/en-us/
