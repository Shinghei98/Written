# Written — project guide

Written is an iPhone dating platform. Two coined terms carry the product, and
they mean specific things here:

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
preferred mechanism. In-app browser login with automated download is the
fallback, to be discussed per app — never a default. When adding a source, the
question "how many taps and does the user type a password?" outranks how much
data the integration could theoretically reach.

The current sources honor this as follows:

| Source | Auth | Friction |
|---|---|---|
| YouTube | Google OAuth (PKCE, `ASWebAuthenticationSession`) | Sheet shares Safari cookies → tap account, tap Allow. Refresh token in Keychain ⇒ later distills zero-tap. |
| Apple Music | MusicKit | One system permission dialog, no login at all — uses the device's Apple Music account. |
| Apple Health | HealthKit | One system sheet listing the four types read, no login. |
| Apple Calendar | EventKit | One system sheet, no login. Works in the simulator, unlike MusicKit. |

## The extraction rule: if it can be distilled, distil it

**Take whatever is technically possible, whether or not it looks useful at first
glance.** The ontology and embedding stages decide what matters, and they can
only decide it about data that was kept. A field dropped at the parse cannot be
recovered without re-distilling everybody, which is not something that can be
done quietly — so the default is to keep, and the exception needs an argument.

This has already cost something twice. `AppleMusicDistiller` fetched
`composerName`, `albumName`, `releaseDate` and duration on every request and
discarded all of them at one line; classical listening was invisible as a result,
since the "artist" of a Bach partita is whoever performed it. YouTube's
`categoryId` sat inside a snippet that was already being decoded.

Two things this rule does **not** license, because they are different questions:

- **It is not a licence to ask for more permissions.** Health's sheet lists only
  the types actually read, and widening it for something speculative is the one
  thing that rule exists to stop. "Technically possible" means with the consent
  already given.
- **It is not a licence to widen the list of what leaves the device.** That list
  is kept short and complete on purpose, and `PrivacyInfo.xcprivacy` has to keep
  agreeing with it.

Within one already-granted permission, though, take everything: extra fields on a
response already fetched, extra `part=` on a request already being made, a second
query against a library already open.

**And an absence is not a refusal.** Distil what is reachable and explain what
is missing — never stop because one route came back empty.

**But do not assume the other route saves you.** Measured on one device, Sync
Library on and then off: `MPMediaQuery.songs()` went **320 to 0**, cloud items
304 to 0, while podcasts held at 2 throughout — that last number is the control
proving the library was still readable, so the zero is an absence rather than a
refusal. Not even the sixteen non-cloud rows survived; they were Apple Music
tracks downloaded for offline play, which read as local and are not.

So **a person without an Apple Music subscription gets no music from this app at
all** — not from MusicKit, whose library endpoints read the same cloud library,
and not from the device library that was added to cover for it. `CLAUDE.md` calls
Apple Music the source the product depends on, and for anybody who only streams,
that dependency is total. `MusicLibraryDistiller` still earns its keep for people
who *own* music — iTunes purchases, a synced collection — which is real but
uncommon.

## Supported apps and what each yields

Scope comes from `written_api.xlsx` (the source of truth for what each platform
exposes; consult it before adding a source). Implemented today:

- **YouTube** (`YouTubeDistiller`) — subscriptions, liked videos, playlists and
  playlist contents. Watch history is **not** reachable: API doesn't expose it,
  and Takeout/Data Portability is EU-only. Don't plan around it for US users.
- **Apple Music** (`AppleMusicDistiller`) — library songs/albums/artists/music
  videos, playlists + contents, recently added, recently played, heavy rotation,
  personalized recommendations, like/dislike ratings.
- **Spotify was dropped, and is back for the beta only — take it out before the
  App Store build.** Both original objections stand and neither is fixed. Its
  Developer Terms forbid storing Spotify Content in a third-party database, so
  once Postgres became the source of truth it was the one source that could
  never be restored to a new device — and its rows *are* synced like every other
  source's, which is the part the terms do not allow. It also cannot leave
  development mode: five test users, the developer must hold Premium, and
  extended quota needs 250,000 monthly active users, closed to individuals since
  May 2025. **Apple Music is still the music source the product depends on.**

  What changed is only the purpose. The TestFlight beta exists to gather
  listening data, five testers is enough for that, and a second music source is
  worth a few weeks of it. That is a reason to run it *now*, not a reason the
  objections went away.

  **Removal is a condition of shipping, not a tidy-up.** It is one commit:
  `SpotifyDistiller.swift`, the `spotify` case in `Modality.sources`,
  `displayName` and `systemImage`, `spotifyStatus` / `spotifyOAuth` /
  `distillSpotify` in `DistillViewModel`, `OAuthProvider.spotify`, and the four
  `spotify*` constants in `AppConfig`. Everything carries a "beta only" comment
  so `grep -rn "beta only"` finds the set. It was removed once already in
  `be4eea1` and restored from `be4eea1^`, so the diff to reverse is on record.
**Apple Podcasts *is* readable through `MPMediaQuery.podcasts()`** — measured on
a device on 2026-08-03. Same framework as `AppleMusicDistiller`, same
`NSAppleMusicUsageDescription` already declared, so it is a permanent one-tap
source with no OAuth and no third party.

**It returns downloaded episodes and nothing else**, and that is now evidenced
rather than assumed. Four routes agree on the same two items — the unfiltered
library, a raw `mediaType` predicate, a different grouping, and
`MPMediaQuery.podcasts()` — so the convenience query hides nothing. The control
that settles it is **304 cloud items in the same library**: it lists non-local
content happily for music and holds zero cloud podcasts. Following a show does
not enumerate its back catalogue either; *Crime Junkie* appeared with one item
against hundreds of published episodes.

**Which fields Apple actually fills in**, measured on two real episodes:

- **Populated:** `podcastTitle`, `title`, `artist`/`albumArtist` (the publisher —
  "Audiochuck", "The New York Times"), `releaseDate`, `dateAdded`,
  `playbackDuration`, `bookmarkTime`, artwork, `assetURL`.
- **Empty:** `genre`, `playCount`, `lastPlayedDate`, `skipCount`, `rating`,
  `comments`, `composer`, `isExplicitItem`, `isCloudItem`.

So there is **no play history** — `playCount` was 0 and `lastPlayedDate` nil on
episodes that had demonstrably been played. `bookmarkTime` is the only
behavioural fact available, and it is real: 50.8s of 4191.8s, 48.9s of 2381s.
`genre` is absent, so a category would have to come from the iTunes Search API by
show name.

**Whether the source is worth having at all is unresolved**, and it turns on one
question: does Apple Podcasts auto-download episodes of followed shows? If it
does, the library is a rolling window over what somebody follows and costs them
nothing. If it does not, it reflects only deliberate downloads — which almost
nobody does — and the source would be empty for nearly every user. Both episodes
on the test device were downloaded by hand, so there is no evidence either way
yet. **Do not ship it until that is settled**; an empty source that looks
connected is worse than no source.

`MPMediaQuery.audiobooks()` is **untested, not unavailable** — it returned 0 on a
phone with no audiobooks, which proves nothing. Same `MPMediaItem` fields apply.

**The way this was nearly lost is worth more than the finding.** A first run
returned 329 songs and 0 podcasts, and that was written up here as proof the
framework does not expose them. The phone's Podcasts app had never been opened.
The songs count existed *precisely* to stop a zero being misread — and it only
rules out one confound, an unauthorized or unreadable library. Songs come from
the Music library; podcasts come from a different provider into the same one, so
one says nothing about the other. Two confounds, one control, conclusion drawn
anyway. Following one show and downloading one episode turned 0 into 2.

**A zero is a finding only when something ought to have been found** — the same
rule HealthKit teaches, broken here while citing it. Any probe of the form "does
this API return anything" needs a positive control *in the thing being asked
about*, not merely nearby.

Everything else was considered and ruled out. MusicKit has no podcast types
(Podcasts is a separate service that never got it). iCloud sync uses Apple's
private container. Now Playing metadata for another app is private API.
`DeviceActivity` can measure time spent in Podcasts but seals it inside an
extension, names no shows, and needs the Family Controls entitlement. The Data &
Privacy export (privacy.apple.com → Apple Media Services) *does* hold full
subscriptions and play history, but arrives as an emailed ZIP days later, which
is the opposite of the prime constraint. `JournalingSuggestions` (iOS 17.2+)
vends real listened-to podcasts, but one user-picked item at a time, above this
app's deployment target, and through a framework meant for journaling.

**So the only routes left are a share and a third party**, and neither is a
library: `podcasts.apple.com` links through the share extension — which already
appears in Apple Podcasts' share sheet, since its activation rule takes any web
URL — resolved by the public iTunes Search API for show, artist and genre; or
Spotify's `/me/shows`, which inherits Spotify's removal date.

- **Apple Podcasts** (`PodcastDistiller`) — through `MPMediaQuery.podcasts()`,
  one `MPMediaLibrary` permission, no login. **Audiobooks were built alongside it
  and removed**, and the reason is worth keeping so nobody adds them again:
  audiobooks belong to **Books**, a fourth app unrelated to Music, TV or
  Podcasts since the 2019 iTunes split. Apple publishes **no API for a user's
  Books library** — the only book APIs are MDM ones for managing purchases — and
  its audiobooks are DRM-protected M4B that never leave the Books container, so
  the media library cannot see them. Audible, Spotify audiobooks, Libby and
  OverDrive each keep their own storage too. What `MPMediaQuery.audiobooks()`
  *can* see is the iTunes-era leftover: DRM-free files synced from a computer,
  which is close to nobody. The zero measured on a test device was neither "no
  audiobooks" nor a broken API — the query points somewhere modern audiobooks
  never reach. It was added without consulting `written_api.xlsx`, which is
  exactly the check that exists to prevent this.
- **Apple Calendar** (`CalendarDistiller`) — **the first source not in
  `written_api.xlsx`.** The reasoning is that a calendar collects two things
  nothing else reaches: bookings that ticketing sites write in by themselves
  (Eventbrite, Ticketmaster, Dice), which is a far stronger claim than a followed
  artist because it cost money and a Saturday; and what people type for
  themselves, which is behaviour rather than inference. `url` and `organizer` are
  kept precisely because they are what tells a booked event from a typed one —
  see `booked=1` in `extra`.
  **Events are stored whole and synced**, unlike HealthKit, because the titles
  *are* the signal. That is a deliberate trade and it puts other people's names
  and locations in the database; `PrivacyInfo.xcprivacy` says so. Windows are
  `AppConfig.calendarLookbackDays` / `calendarLookaheadDays` — both directions,
  because a ticket bought today for November only exists ahead of now — capped by
  `maxCalendarEvents`. Two traps: `predicateForEvents` silently returns nothing
  across more than four years, so the fetch is chunked by year; and on iOS 17+
  the old `requestAccess(to:)` grants *write-only*, which reads nothing and looks
  exactly like an empty calendar, so `requestFullAccessToEvents` is required.
- **Apple Health** (`HealthKitDistiller`) — the spreadsheet's scope is "recorded
  sport type/duration, activity intensity/duration", so: one record per workout
  (sport, duration, energy, distance, recording app) and one per day (exercise
  minutes, active calories, steps). Two windows, not one:
  `AppConfig.healthWorkoutLookbackDays` and `healthActivityLookbackDays`, both a
  year today. They are kept apart because the underlying asymmetry is real —
  workouts are sparse, quantity samples are dense — so the activity window is
  the dial to turn first if a distillation is ever genuinely slow. Note it was
  turned once already, wrongly: a hang that looked like slowness was the
  *authorization request* never returning, with no query having run at all. Only
  the types actually read are requested — workouts, date of birth, biological
  sex, exercise minutes, active energy, steps, and walking/running distance.
  HealthKit authorizes per type, so asking for vitals we have no use for would
  widen the sheet for nothing; equally, *reading* a type that was never
  requested is what makes it answer `errorAuthorizationNotDetermined`, which is
  how distance came to be queried for months without ever being returned. A **declined read looks
  exactly like no data** — HealthKit never says which reads were refused — so an
  empty distill is surfaced as a failure rather than silently growing a branch.

HealthKit sits in between: the permission sheet and API **do work in the
simulator**, but its database starts empty, so add samples in the simulator's
Health app or every distill comes back empty. On device it needs HealthKit
enabled on the App ID — and note that with no `DEVELOPMENT_TEAM` set, Xcode
silently strips the entitlement at packaging (the built `.xcent` is empty), so a
device build fails to read Health with no obvious cause. **`CODE_SIGNING_ALLOWED=NO`
does the same thing to a simulator build**, and HealthKit reports the result as
`Missing com.apple.developer.healthkit entitlement` through `log show` and as an
ordinary authorization failure on screen — so it looks like a bug in the app.
Two verification runs were spent on that. `xcodebuild test` signs correctly;
building with that flag and hand-installing from DerivedData does not.

**HealthKit does not draw its own permission sheet, and that is the whole of the
first-run bug.** It asks SpringBoard to launch `com.apple.HealthPrivacyService`
and hosts a remote view from it. If anything else owns the screen, or that
process is still cold-starting, it cannot present — and it does not report a
refusal or wait. It gives up:

    Asking defaultShell to open app viewservice com.apple.HealthPrivacyService
    App will resign active
    FAILED prompting authorization request …, error Authorization session timed out
    Request successful: <BSProcessHandle: HealthPrivacySe:10724>

— the service finishing its launch *four seconds after* HealthKit stopped
waiting. Three consequences, each paid for:

- **Never raise another permission alert near this one.** The alert that was
  stealing the screen was the location fix, fired from `DashboardView.task` —
  and `AppShell` mounts all five tabs, so it ran at launch from a screen the user
  had never opened. Any permission asked for on `.task`/`.onAppear` in this app
  must be gated on that tab's `isVisible`.
- **One retry is not optional, it is how the sheet gets drawn at all.** Measured
  on an erased simulator with nothing else on screen: request at 12:33:39,
  `HealthPrivacyService` bootstrap success at 12:33:49, `Authorization session
  timed out` at 12:33:49.991. HealthKit allows its sheet host about **ten
  seconds** to launch and a genuinely cold start can take all of it, so the first
  attempt loses on its own. The second finds the process warm and the sheet
  appears — verified. A refusal never arrives as an error here (a denied read is
  reported as success with no data), so an error from `requestAuthorization` is
  always infrastructural and always worth one more go.
- **Distinguish our timeout from a wrapped one.** `stage` wraps *every*
  underlying error as `stageFailed`, so a retry guard reading "don't retry
  `stageFailed`" refuses `[com.apple.healthkit 100]` — the one error it exists
  for. That shipped in a build and the retry never ran once.
  `HealthError.stageTimedOut` is now a separate case and only it is terminal.

**The sheet's Allow button is disabled until a category is switched on**, and
nothing about that is obvious. Every toggle opens off, "Turn On All" is a link
rather than a default, and `Allow` renders as a grey pill while `Don't Allow`
stays white and live. A user who reads the list and taps Allow gets nothing, taps
again, gets nothing — and reports the app as frozen, which is exactly how it was
reported. Nothing can be drawn over the sheet once it is up, and no message
afterwards reaches somebody who never got past it, so the only place to say so is
**before**: `SourcePickerSheet.row` carries a second line on the Health row
alone. `detentHeight` counts it, because that detent is a fixed height and would
otherwise crop the very sentence that prevents the dead end.
- **It only happens to people who have never been asked**, which is why it
  survived so long: on any device that has answered once, the call returns
  instantly with nothing to present. Testing Health on your own phone proves
  nothing about a new user's phone.

**A failure has to be drawn against the branch that was attempted.**
`GrowProfileView`'s prompt card asked `nextModality` what went wrong, which is
right only while the two agree. Connect a source out of sequence — Lifestyle when
Media is next — and the error is recorded against Lifestyle while the card
interrogates Media, gets nil, and draws "Ready to grow?" as though nothing had
been tried. That is what the whole first-run report reduced to: the watering can
runs, the screen returns to exactly how it was, and with no ending drawn there is
no way to tell that it ended. Reported as "it just keeps loading and never
ended".

**A `withThrowingTaskGroup` cannot impose a timeout on a call that never
returns.** `HealthKitDistiller.stage` raced the work against a sleeper and
claimed to survive a hung callback; it could not. A task group **awaits every
child before it returns**, `cancelAll()` only sets a flag, and a task suspended
in `withCheckedThrowingContinuation` never observes it — so the group waited
forever on the one case the timeout existed for. Surviving a continuation nobody
will resume means declining to wait for it, which requires an unstructured task
that is deliberately abandoned.

**Resetting HealthKit for a first-run test:** deleting the app does **not** do
it — Health keeps the app listed with its toggles and a reinstall inherits them —
and `simctl privacy` has no `health` service. `xcrun simctl erase` is the
simulator's only reset; Settings → General → Transfer or Reset iPhone → Reset →
**Reset Location & Privacy** is the device's, and it is device-wide.

Testability differs and this trips people up: **YouTube works in the simulator**
(it authenticates against a web account inside a browser sheet).
**Apple Music requires a physical iPhone** signed into Apple Music, plus a paid
developer team and MusicKit enabled on the App ID — MusicKit mints its developer
token from the signing identity, so ad-hoc-signed simulator builds fail with
"Failed to request developer token".

## Output pipeline

```
Distiller (per source)  →  [DistilledRecord]  →  CSVExporter  →  CSVDocument
                                                                      ↓
                                                        .fileExporter (Files app)
```

- Every source normalizes into the **same** `DistilledRecord` schema, so the
  downstream ontology/embedding work consumes one shape regardless of platform:
  `source, data_type, item_id, name, creator, detail, extra, collected_at`.
- `extra` is a `key=value;key=value` string for platform-specific context
  (genres, play counts, dates, ranks). Put platform quirks there rather than
  widening the schema.
- `DistillViewModel` holds records in memory and replaces per-source on
  re-distill (`replaceRecords(from:with:)`) — distilling YouTube twice must not
  duplicate rows.
- **Data no longer stays on-device.** It did until the Supabase backend went in;
  the rule now is that everything leaving the device is on this list, and the
  value of the list is that it stays short and complete.
  - **Postgres, keyed to the account** — the distillation itself, via
    `SyncService`, plus the profile, the ban list and derived health signals.
    **Raw HealthKit rows are never uploaded**, and that is now enforced twice:
    the device derives its signals and *discards* the raw workouts and activity
    samples without writing them to disk, and `SyncService.localOnlySources`
    refuses the source outright. Only the chronotype, sport levels, hourly
    profile and step average travel. Row-level security is the whole
    authorisation layer — see the migrations.
  - **Lyrics providers** — `LyricsService` sends the top song's artist and title
    to lrclib.net, then music.163.com if LRCLIB has no answer. One artist and one
    title, no user id, no library, and cached so a song is asked once.
- **The server is the source of truth; the device keeps a cache.** `RecordStore`
  was the only copy for a while, which is why sync pushing without ever reading
  back left a reinstall starting empty. `RestoreService.hydrate()` is the read
  half: records, `source_connections`, the user object, health signals and bans.
- **Nothing in Postgres is ever deleted, and only changes are stored.** The
  device *replaces* a source's rows in memory so a re-distill doesn't duplicate
  what the dashboard shows; the server *appends*. `append_source_records` stamps
  every row of a run with one `distilled_at`, and a `before insert` trigger drops
  any row identical to the newest version of itself — so re-distilling YouTube
  five minutes later writes the one newly-liked video and nothing else. Two
  things make that work and both are easy to break: the comparison is against the
  **latest** version, not any historical one (or a value that changed and changed
  back is silently lost), and it **excludes `collected_at` / `distilled_at` /
  `updated_at`**, which differ on every pass and would make every row look
  changed.
- **Read through the `summary_*` views, never the tables.** They return the
  latest row per item across all runs — a union, deliberately **not** a sum: a
  HealthKit run reports sessions over a 365-day lookback and Apple Music reports
  cumulative play counts, so adding two runs would roughly double every figure.
  The views are `security_invoker = on`; without it a view runs as its owner and
  bypasses RLS, which is the whole authorisation layer.
- **Signing out erases the device**, and nothing is retained afterwards —
  `signOutLocalState()` clears the cache, the ban list, the tree seed and the
  OAuth tokens. A connection still outlives the session, but through Postgres
  rather than the phone: signing back in restores the garden as it was. This
  reverses an earlier decision that kept everything on sign-out, which was only
  ever safe because `AccountScope` keys each store by account. That keying stays
  as a second line of defence.
- **Local state must be cleared before the session is dropped.** `AccountScope`
  reads the stored user id to know which files and Keychain items belong to the
  account; after `SupabaseAuth.signOut()` it resolves to `local` and would clear
  the wrong ones. `HomeView` is the only place wired for this, and
  `GrowProfileView` deliberately has no `onSignOut` so there is no second route
  that could skip it.
- `PrivacyInfo.xcprivacy` must agree with that list. It declared *nothing
  collected* for a while after the backend landed, which is exactly the kind of
  claim that ages into a rejection.
- **A connection is a snapshot, not a subscription.** Nothing polls, nothing runs
  in the background: a distillation happens the moment someone taps Connect and
  `collectedAt` stamps every row. "Connected" in the UI therefore means *has been
  connected* — a durable fact — which is why `RecordStore` persists it rather
  than the app rediscovering it each launch.
- Exports are git-ignored (`written-distillation-*.csv`) — they are personal
  data and must never enter history.

## Launch routing: the first frame must already be the right screen

`RootView` picks one of four screens — `signIn`, `name`, `photos`, `home` — from
a single `Route`, never a set of booleans that can disagree. Two rules, each paid
for once:

- **Decide synchronously.** Anything the first frame depends on has to be
  answerable without a network call. `SupabaseAuth.hasStoredSession` reads the
  Keychain and `restoredStep` reads `UserDefaults`; both are instant. Deciding
  from the Supabase token refresh instead meant the sign-in screen was drawn for
  two to four seconds and then replaced — a flash of the wrong screen on every
  launch for someone already signed in. `restoreSession` still runs and the
  server still has the last word; it just corrects a route rather than choosing
  the first one.
- **Onboarding steps are routes, not covers.** A `fullScreenCover` has to draw
  something underneath it, and the something was `SignInView` — so resuming on
  the photo page reintroduced the very flash the point above removed. Anything
  reachable *both* forwards from sign-up and by resuming a killed session belongs
  in the `switch`.

`restoredStep` mirrors two facts that live on the server (the name, and whether
the photo page has been shown), which is what lets a force-quit resume on the
page it happened on. Anything that moves them — `upsertProfile`, `loadProfile`,
`markPhotoStepSeen` — must call `cacheOnboardingStep()`, and `signOut` must clear
it along with `firstName` and `hasSeenPhotoStep`, or the next account inherits
the last one's answers and is never asked its name.

`-route name|photos|home|signIn` opens straight onto a screen (DEBUG only). The
onboarding pages otherwise need a real Apple account, which the simulator cannot
provide, so this is the only way to check them without a device.

## Encoding: every generated file must support every language

**Any file this project writes must be UTF-8 with a BOM (`\u{FEFF}`), not just
UTF-8.** Users' libraries are full of Korean, Japanese, Chinese, Cyrillic, and
emoji; a distillation is worthless if the titles arrive as mojibake.

The subtlety that already bit us once: plain UTF-8 is *correct* but Excel
doesn't assume it — without the BOM it falls back to a legacy Western encoding
and non-Latin text renders unreadable. Numbers and pandas are fine either way,
so the bug only appears for the person opening the file in Excel. `CSVExporter`
prepends the BOM for this reason; keep it, and apply the same rule to any new
export format (JSON, TSV, reports). For pandas, read with `encoding='utf-8-sig'`.

Related: CSV escaping is RFC 4180 (quote fields containing comma/quote/newline,
double embedded quotes). Titles genuinely contain commas and quotes — don't
hand-roll a simpler join.

## Setup that lives outside the code

Client IDs are in `AppConfig.swift` and are committed deliberately: iOS OAuth
client IDs are not secrets (they ship in the binary; PKCE is what secures the
flow). No client secret belongs in this app.

Portal-side setup — Google Cloud (YouTube Data API v3 + iOS OAuth client + test
users on the consent screen), Apple Developer (MusicKit on the App ID) — is documented step-by-step in `README.md`. Both
Google gates unverified apps to an explicit tester allowlist; a 403
after a successful login almost always means the signed-in account isn't on it.

## Conventions

- SwiftUI + async/await, MVVM: `Models/`, `Services/`, `ViewModels/`, `Views/`.
- Xcode 16+ synchronized-folder project — new files under `Written/` are picked
  up automatically, no pbxproj surgery.
- New OAuth sources: add an `OAuthProvider` case rather than writing another
  auth service; `OAuthPKCEService` is provider-parameterized.
- Pagination is capped by `AppConfig.maxPagesPerEndpoint` /
  `maxPlaylistsExpanded` / `maxSongsRated` so a distill finishes in seconds. A
  per-item fetch that can't be capped is a red flag — Apple Music's ratings pass
  was exactly that, one round trip per hundred library songs with no ceiling.
- **Independent fetches within a distiller run concurrently.** Apple Music has
  nine top-level endpoints to YouTube's four, and awaiting them one after another
  was the whole reason it felt slower to connect — not richer data, just a longer
  chain of round trips. `AppleMusicDistiller.distill` is the shape to copy: one
  `async let` per independent endpoint, then the passes that depend on their
  results through `inParallel`, which keeps five requests in flight rather than
  all of them (unbounded fan-out trades a slow distill for a rate-limited one).
- Per-source failures are surfaced in that source's card (`SourceStatus.failed`)
  and never abort the other sources.

## Iterating on the garden illustration

**Five illustrated stages, one per connected modality plus bare soil.**
`TreeSkeleton.make` maps 0-4 to sprout/shoot/branch/bough/canopy; beyond that the
generated tree takes over. Four briefly shared the bough, before there was art
for it — worth knowing because falling through to generated geometry at 4 is what
that avoided, and it reads as the drawing breaking rather than as growth.

**The badges' bob is driven by a clock, not by `repeatForever`.** It used to be
`withAnimation(.easeInOut.repeatForever())` started in `onAppear`, and **any
other explicit transaction touching the badge replaced it** — permanently, since
nothing restarted it. Its own arrival is one: `hasBadgeArrived` and
`hasShootBadgeArrived` flip inside `withAnimation(.spring(…))`, so a badge
stopped floating a moment after it appeared, and the filling progress ring did
the same. What survived looked arbitrary — whichever badge had most recently
escaped a transaction was the one still moving, which is how it was reported
("only the new icons float"). `ModalityBadge` now offsets by a sine of
`TimelineView`'s date: a pure function of time, with no animation to interrupt.

Two things about it. The schedule is **paused when the garden is not the visible
tab** (`isVisible`, as `ChatView` and `DashboardTab` already take one) — every tab
stays mounted, so an unpaused clock would redraw four badges at display rate
behind Explore for the life of the app.

And **every badge reads the same clock with no phase offset, so they rise and
fall together.** Staggering them was tried and rejected. The argument for it was
that the old per-badge `onAppear` repeats were never synchronised, so syncing
them was a change in character — but what a stagger actually looks like is four
things drifting independently, which reads as the badges being loose. In step
they read as one plant breathing, which is the thing they hang off.

**Badge positions must be read off `leafLift`, never off `displayedSkeleton`.**
`SeedlingArt.shoots(by:)` does not only filter by stage — past 3 it *blends*
every shoot toward its canopy shape, so one shoot id has different reach and
turn at bough and at canopy. The badge `ForEach` read the discrete
`stage.extended`, so that blend landed the instant `displayedSkeleton` was
assigned — which happens outside any transaction, leaving `.position` nothing to
interpolate. Bough-to-canopy therefore looked like the badges vanishing and
coming back somewhere else. `leafLift` holds the same number and is set inside
`withAnimation(extensionAnimation)`, and it is what `shootExtent` already used:
the list and the positions were reading the plant at two different moments.

**The first shoot's badge is dropped further than the others** (`firstShootDrop`,
+0.031). Every other badge is spaced from its neighbour by the pitch between two
shoots, which the drawing sets; shoot 0's neighbour is the *cotyledon* badge,
which hangs off the leaves rather than off a shoot and so is spaced by nothing.
At stage 1 the two sat 7.5pt apart on 48pt badges and read as one object; they
are 14.7pt apart now, with the other stages' closest pairs at 19.0, 29.1 and
46.3pt. Dropping *every* shoot instead would have left the crowding exactly as
it was, since they would all have moved together.

Measuring these is easier than it looks: a badge's translucent disc is
`(236,231,223)` against `(243,239,233)` parchment, which finds filled and
unfilled badges alike — the gold ring only exists once a modality is connected,
so looking for gold finds half of them.

Two things about the fourth badge. It sits *above* its shoot rather than beside
it (`shootBadge`), and it needs **full** outward travel: tucking it toward the
stem, which seems right with no neighbouring badge to clear, puts it on the
cotyledon blade — the cotyledons reach further out at that height than the shoot
does. And shoots alternate sides going up (0.34 left, 0.52 right, 0.70 left, 0.80
right), so a new one belongs on the side the last one wasn't.

`StageSheet` derives its row count rather than hardcoding 2×2. It was fixed at
four panels, so a fifth stage would have been dropped silently — the one failure
this harness cannot afford, since its whole job is showing what a change did.

The plant on "Grow your profile" (`Views/Tree/`) is hand-measured vector art with
four stages, and refining it is the one task here where the *loop* costs more
than the change. These rules exist because each was paid for once already.

- **Drive stages from the launch line, never by patching the source.**
  `xcrun simctl launch <device> com.written.datingapp -route home -stage 3` seeds
  the screen as though three modalities were connected; `-stages all` renders
  every illustrated stage on one screen. **`-route home` is required unless the
  simulator holds a session** — `-stage` only takes effect inside `HomeView`, and
  without it the app opens on sign-in and the flag does nothing. One build serves
  all of them. Editing
  `TreeSkeleton.make` to force a stage costs two builds per look and leaves the
  tree dirty. See `Views/Tree/DebugLaunch.swift`.
- **One build per batch of changes**, not per constant. Adjust every number you
  believe is wrong, then look once.
- **One cropped, downscaled screenshot per iteration.** A full-resolution
  screenshot is ~1.5k tokens and answers no question a crop doesn't.
- **Measure, don't eyeball.** When the question is a length, an angle or a
  ratio, a script over the reference PNG costs ~50 tokens and gives a number;
  reading the image gives an impression. The watering can was rebuilt three
  times because it started from a mental archetype instead of a measurement.
- **Reference measurements are already recorded** in the comments beside the
  constants they set (`SeedlingArt.swift`, `WateringCanOverlay.swift`). Don't
  re-derive them.
- **Shared geometry affects every stage.** `leafTilt`, `leafletTilt`,
  `LeafSpine` and the blade profile are used by all four. After changing one,
  check the stages the change wasn't aimed at — a sign error in `leafletTilt`
  silently distorted stages 2 and 3 while fixing stage 4. `-stages all` is
  exactly this check.
- Rapid screenshot bursts and headless boots crash `backboardd` in the
  simulator. Recovery is `killall Simulator && xcrun simctl shutdown all`, then
  reopen — one more reason to take fewer screenshots.

## The layout audit: what proves nothing overlaps

    ./tools/run_layout_audit.sh          # 5 iPhone widths x 2 text sizes
    python3 tools/layout_audit.py out/layout/*/

`WrittenUITests` dumps the accessibility frames of every reachable screen;
`tools/layout_audit.py` does the geometry. A screenshot proves a screen looked
right *where somebody looked*, which is how the badge bug survived: the plant's
four badges overlapped each other and buried the seedling on an iPhone SE while
a 17 Pro looked perfect. That was found by measuring, and this generalises it.

Five things about it, each of which cost a run to learn:

- **A UI test runner's `print` never reaches `xcodebuild`.** A clean 14-screen
  run reports `** TEST EXECUTE SUCCEEDED **` and not one marker. The dumps come
  out of the result bundle — `xcresulttool export attachments` — and the driver
  script does that for you. Both channels are still written; only one works.
- **`-solo 1` is required, and it is not a convenience.** `AppShell` mounts all
  five tabs and hides four with `opacity(0)`, `allowsHitTesting(false)` and
  `accessibilityHidden(true)`. **XCUITest honours none of the three.** Without
  the flag every dump contains Explore's empty state and Wish's note stacked on
  whatever you asked for: 543 overlaps, none of them real.
- **Never `descendants(matching: .any)`.** It kills the accessibility server —
  `(ipc/mig) server died` after 167 seconds. Ask per element type instead.
- **The system keyboard is Apple's layout.** Its keys overlap each other by
  design, so anything inside `app.keyboards` is dropped. What is *kept* is the
  useful half: one of our own controls intersecting the keyboard frame is
  reported as `under-keyboard`, which is a real hazard on a 667pt screen.
- **The allowlist is judgement, not bookkeeping.** This app overlaps on purpose
  — the tab bar draws over content, pinned headers have content sliding under
  them — so `tools/layout_allowlist.json` records those once, by widget identity
  rather than by coordinate. Regenerating it with `--update-allowlist` and not
  reading the diff is how the next real overlap gets buried.

Two axes, and the second is where the bodies are. Widths from 375 to 440 catch
geometry; the accessibility text size catches the fact that **this app mixes two
font systems** — `BrandFont` uses `.custom(…, relativeTo:)` and scales, the 165
`.system(size:)` calls do not. Ten files use both.

Discovery is **not** covered: it has no sample-data path and needs a real
signed-in session, unlike Chat's `-chat sample`. Say so rather than implying the
sweep is complete.

## The two halves of the app

**Onboarding is a line; regular use is a tab bar.** They are different products
wearing one binary, and most of the layout rules below only make sense once that
is clear.

Onboarding runs sign in → name → communication style → photos → grow the plant →
"People you will see", and ends the moment **Explore** is tapped there.

**The communication step is two sliders, and three things about it are
deliberate.** It asks flirt level and response time, because both are
*boundaries* and a boundary set after the fact has already failed at its job —
which is also why it comes before anything can message anyone. Each bar is
continuous under the finger and one of **four bands** to everything else
(`StyleBand.count`): nobody can honestly place themselves at 0.62 of a flirt, and
a number that precise invites a matcher to believe it. The exact position is kept
beside the band purely so the slider can be put back, which is a drawing concern
rather than a fact about the person.

Flirt level carries **two vocabularies** and both are needed. The stored
`rawValue` is flat — `Low` … `Extremely High` — and the dashboard shows
`Platonic` / `Mild` / `Flirty` / `Freaky`. "Freaky" is a good thing to read about
yourself on your own profile and a poor thing to sort a database by. Response
time is stored as its tempo, and the sentence under it on the card is what
actually sets the expectation.

**The flirt dial's geometry is fixed by one constraint, not chosen.** The
captions sit on **thirds of the card** and the arc's two legs stand directly
above them, which is what sets the opening angle:
`halfOpening = asin((0.5 - 1/3) / (diameter/2))`. So the gap is not a free
choice, and — the counter-intuitive part — **shrinking the dial widens it**,
because smaller legs still have to reach the same two points.

Note this is *not* what the reference does: its legs are at ±29% of the card
width against captions at ±17%, so its arc oversails them. Aligning the two was
asked for.

`diameterRatio` is 60%, arrived at from both sides — 54% read as a token sitting
in a card rather than as the card's subject, and the reference's own 74% was
overbearing on a card that is half a phone wide and has to share its row. The
centre word is plain `.system(size: 14, weight: .semibold)`, matching
`chronotype.label` beside it; scaled off the radius it grew with the dial and
read as a headline rather than as the same kind of reading.

Two things about the layout, each of which cost a pass:

- **`FlirtGauge` owns its captions**, unlike every other card here. "The legs
  stand above the words" is one geometric statement, and splitting it across two
  views is how they drift apart. It is also the one thing that cancels the
  card's padding (`DashboardView.cardInset`), because thirds of *the card* is
  not thirds of the card's content — 6pt apart, and visible.
- **They are a stack row, not `position`ed below the arc.** Placed by absolute
  offset they landed past the bottom of the gauge's own frame, so they hung into
  the card's padding and had no gap beneath them at all. Laid out as a row they
  take their own height and the card's padding does its job.

Measure it, don't look — but **on a screenshot showing the whole card**.
`-scroll communication` pins the section under the pinned header, which hides the
dial's upper half; measuring the diameter there reported 52% for a dial that was
actually 76%. `-scroll photos` puts the card's top in view.

Two traps, both paid for while building it:

- **Adding a step re-opens onboarding for everyone who finished it.** The cached
  `restoredStep` said `done`, and it was — for the steps that existed when it was
  written. Left alone, an established user's shell would build with no tab bar
  and correct itself a second later, which is exactly the disagreement `Route`
  exists to prevent. `restoredStep` therefore answers `.communication` when the
  cache says `done`/`exploring` and no style is stored, matching what
  `onboardingStep` computes live. On finishing, the next route is **asked for**
  rather than hardcoded to `.photos` — someone who onboarded before this page
  existed has already seen those.
- **The answers are collected before a view model exists**, two screens ahead of
  `AppShell`. They go to `CommunicationStyleStore` (UserDefaults, account-scoped),
  which is *also* what `needsCommunicationStyle` reads — so having an answer and
  having been asked cannot disagree, unlike `hasSeenPhotoStep`, which needs its
  own flag because that page finishes whether or not anything was picked.
  `adoptStoredCommunicationStyle` copies them into `user` records, after
  hydration rather than before, and is idempotent because it also runs on every
  launch as the repair for a sync that never landed. Through all of it the tab
bar is absent: a bar would offer four exits from a sequence whose whole point is
that it has one. The garden therefore keeps an arrow at its foot and a pull-up
gesture, because with no bar it has to carry the way onward itself.

**That pull-up is a reveal, and two things make it one.** `AppShell.page` hides
every unselected tab with `opacity(tab == which ? 1 : 0)`, which is right for a
bar — you are on exactly one tab — and wrong for a drag, because during it *two*
pages are on screen while `tab` still names the one being pulled away. Keying on
the selected tab alone made the whole gesture reveal bare parchment: the
dashboard did not appear until the drag committed and flipped the tab, which is
after the reveal is over. `isDrawn` is the fix, and it is the same shape of bug
as `DashboardTab` hiding the profile preview until its slide began — *a layer
needed during a transition, gated on a flag that only moves at the end of it.*
The second is **z-order**: the dashboard must be built before the garden, or
being visible simply means covering the page the finger is lifting.

Two smaller things fell out of it. Hit testing stays on `tab == which` even
while both are drawn, so a finger travelling up the screen cannot press a row it
is only sliding past. And `gardenLift` returns to **zero at rest** — parking the
garden off-screen after a commit is one fewer moving part here and a trap
everywhere else, since every future route out of the dashboard would have to
remember to reset it, and the one that forgot would show an empty garden tab.
`-reveal 0.5` holds the frame, because `simctl` can send no drag.

Regular use is the reverse. The bar exists, so the garden gives up the arrow and
the pull-up — a second route to a place a tab already reaches is chrome. The
dashboard likewise drops its "Garden" button, and gains sign-out and delete,
which are hidden during onboarding: offering to destroy an account beneath the
button that carries on making one is an invitation to end the thing by accident.

`SupabaseAuth.OnboardingStep.exploring` marks the boundary and slots into the
machinery that already decides the first frame synchronously, so a force-quit
mid-garden resumes correctly. `AppShell` owns the flag and every screen reads
it, so the bar arriving and the arrow leaving cannot disagree.

## The tab bar, and why it must never inset

Five tabs: Explore, Wish, Chat, the garden, and Memories (the dashboard). Wish
and Chat are unbuilt and say so rather than rendering blank; they exist in the
enum from the first build so the bar's geometry never shifts under them.

**It overlays. It never takes layout height.** `promptsReserve` is what the
garden is measured against, so anything consuming height at the bottom of the
screen moves the plant — a regression this project has paid for four times.
Everything the bar needs comes *out* of the reserve rather than being added
under it, and `MainTabBar.overlayHeight` is derived from the bar's own height
plus its inset rather than guessed alongside it, because a guess was 22 points
wrong and cost the connected rows that space for nothing.

Two of its icons are drawn rather than named. SF Symbols has no
message-in-a-bottle and no potted plant on iOS 16, and `sailboat` and `tree`
were each standing in for something they were not.

## Discovery: the only two tables one user may read about another

Every policy in `0001` is `auth.uid() = user_id`, which made a feed of other
people impossible rather than merely unbuilt. Two tables open that up and no
more should without the same argument:

- **`discovery_cards`** (`0007`) — a name, an age, a district, six photo seeds
  and derived `{domain, subject}` pairs. Deliberately **not** a view over
  `distilled_records`: enough for `Ontology.line(for:subject:)` to write a line,
  and nothing that could reconstruct a distillation.
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
why it is a script you run and not something the app can do.

**And for a long time they were the *only* people in it.** `DiscoveryService`
reads `discovery_cards`, the seeder writes six, and **nothing in the app ever
wrote one** — so every real signup was invisible, reported as "I could not find
the new test accounts in the discovery page". Not a bug in the feed: `0007` has
carried `own row` insert and update policies from the start and only the caller
was missing. `DiscoveryCardService.publish` is it, called from
`DistillViewModel.sync` so a card rides the same moment as everything else that
leaves the device — a card is worth publishing once there is a distillation
behind it.

**Subjects only**, per that migration's own header: artist and channel names,
things a sentence can be *about*. Nothing that could rebuild a distillation. This
is the one table every signed-in user can read, and it stays worth that by
staying thin.

**The feed also never excluded the viewer.** Harmless while the only cards were
synthetic — no real account had one to be shown its own — and immediately wrong
once everybody publishes. Filtered in the query with `user_id=neq.…` so it never
crosses the wire, rather than after it: `DiscoveryModel` already filters likes in
three places that have to agree, and a fourth thing to remember is a fourth thing
to forget.

### The feed's rotation

`DiscoveryFeed` shows a person repeatedly with different photographs and
different lines each time — two of each, both drawn without replacement, on
independent cycles.

**The round order is fixed, and that is not laziness.** Requiring five profiles
between one person and their next means, for a person at position `p` in one
round and `q` in the next, that `q >= p` — for everyone simultaneously, across a
permutation. Only the identity does that. Measured over three thousand
reshuffles the worst gap was 1, not 5, including with a "don't start a round
with whoever ended the last" guard that looked sufficient. A repeated
permutation gives exactly `n - 1` every time, which is the most any ordering can
offer.

**A like removes that person from the feed, but not on the tap — on the next
scroll.** Removing their cards the instant you double-tap was tried and is
wrong: it takes the post out from under the reader's thumb and hides the one
piece of feedback the gesture has, a heart they never see fill. `like` therefore
touches nothing but `liked`, which also keeps its failure path honest — nothing
was removed, so an offline like that reverts has nothing to put back.

`DiscoveryFeed` is not where the removal happens either. Its `people` is `let`,
so rebuilding the rotation to drop someone would reshuffle everybody mid-scroll.
`DiscoveryModel` filters the *output* instead, in three places that have to
agree: `load` builds the feed from the unliked, `extend` purges liked people from
`items`, and `extend` also drops them from each newly generated batch — miss that
last one and they return the moment the list grows.

Three things it is easy to get wrong. The purge sits **above** `extend`'s
near-the-end guard, because a row appearing is the only scroll signal this view
has and "they go on the next scroll" needs all of them, not just the last three.
It removes only indices **strictly after** the one that appeared: taking out an
item above the viewport shifts everything below it upward and moves what is being
read. And the top-up loop is **bounded** — asking until six survive spins forever
once everything left has been liked, which is reachable with six synthetic
accounts. An all-liked feed is not a failure either: `load` must leave `failure`
nil there so the empty state shows rather than a network complaint.

Shared videos are interleaved every fourth item rather than mixed into that
machinery, since the separation rule is about people and a video is not one.
Their ids carry an **appearance number** for the same reason profiles' do: one
post recurring with one id hands `ForEach` duplicates, which is undefined
behaviour and hung the app outright.

## Embedding YouTube, which took six attempts

**The player will not run in a document with no origin, and an app-built page
has none.** Four ways of claiming one all failed, and each failure is worth
knowing so nobody tries them again:

    loadHTMLString with a base URL          -> error 152
    the same, plus an `origin` player var   -> 152 again
    loading youtube.com/embed top-level     -> 153, the referrer complaint
    a page served from a Supabase function  -> black, no error at all

A base URL resolves relative links and is not an origin. A player parameter is a
claim. And **Supabase cannot host the page**: both edge functions and Storage
rewrite HTML to `content-type: text/plain` with
`content-security-policy: default-src 'none'; sandbox`, an anti-phishing measure
for the whole project, so the script never ran.

What works is `loadSimulatedRequest`, which gives the HTML the security origin of
a URL you name — and naming a **third-party** one. The page had been claiming to
*be* youtube.com, which nothing on the real web does, and which the player has
every reason to refuse. It claims the project's Supabase host now.

None of that was deduced. Five fixes were reasoned from a single error number
and all five were wrong; the page's own console said `api: loaded`,
`player: ready`, `error: 152` and pointed straight at the cause. `EmbedWebView`
still forwards `console`, `window.onerror` and player errors through `onLog` —
nothing draws them, and the next blank player will want them back.

Playback follows the card nearest the middle of the screen, muted, one at a
time. Muted is load-bearing: WebKit blocks unmuted autoplay outright, so an
unmuted player would simply never start. Sound is a preference of the *reader*,
so unmuting one video unmutes the feed — and resets on launch, because opening
an app to unexpected sound is worse than tapping once to ask for it.

## The share extension

`ShareToWritten` is a second target — the first this project has had. It needs
three things on **both** targets: the App Group, a shared keychain group so the
extension can read the session and post as that user, and matching bundle ids.
Verify entitlements in the *signed* binary, not the `.entitlements` file; Xcode
has silently dropped one here before.

It is **deliberately self-contained**, repeating the host, the anon key, the
keychain read and the link parsing rather than sharing files. Synchronized
folders scope everything under `Written/` to the app target, and sharing files
means the `project.pbxproj` surgery that arrangement exists to avoid.

Three things the template gets wrong for this use. Its activation rule is
`TRUEPREDICATE`, which offers Written in every app's share sheet for photos and
contacts it cannot use. Its compose sheet pre-fills the text view with the
shared item, which published the URL as the caption. And **`INFOPLIST_KEY_*`
build settings beat the `Info.plist` file**, so the display name has to change in
`project.pbxproj` or the share sheet says "ShareToWritten".

Where the row appears in that sheet is iOS's business — ranked by use, no API.

## Likes and chat, and the upsert that column grants forbid

Proven end to end on a real device on 2026-08-01, against real rows rather than
fixtures: a synthetic account likes you, the admirer appears, accepting creates
the conversation, a message reaches it, a reply arrives on the four-second poll,
and declining marks the row. `0009` is fully applied — the column grant and the
`touch_conversation` trigger both confirmed by behaviour, which is the only way
to see them: an anonymous caller is refused either way, so probing from outside
cannot tell a missing grant from a working one.

**`resolution=merge-duplicates` cannot be used on `likes`, `conversations` or
`messages`.** It compiles to `on conflict do update`, and Postgres checks
privileges when it *plans* a statement rather than when a conflict happens — so
it demands `update` on every column being inserted, whether or not the row
exists. `0009` revokes update on all three tables and grants back only the
narrow columns each side may answer with (`status, responded_at`; `read_at`),
precisely so a recipient cannot rewrite `liker_id` and forge a like. The
privilege wins, and the failure is **42501 on every attempt**.

That shipped: `LikeService.like` used it, so every double-tapped like in the feed
was silently refused — silently because the heart fills optimistically and
`lastError` is recorded and never shown. `ignore-duplicates` is the fix, giving
the same idempotence through `on conflict do nothing`, which needs no update
privilege. `ChatService.open` had already documented the identical trap for
`conversations` and the lesson did not travel one file across.

`SyncService` and `SupabaseAuth` still use `merge-duplicates` and are fine:
`0009` is the only migration that revokes update, so every other table leaves
`authenticated` its default privilege.

**Two accounts are needed to test any of this**, because RLS makes each half of
a conversation invisible to the other. `tools/chat_e2e.py` plays the second
person over REST — `users`, `like`, `reply`, `state` — and the six synthetic
accounts are real `auth.users` rows, so one of them can be it. A simulator
cannot be the first person; Sign in with Apple needs a device. **Read the
database after every step rather than trusting the screen**: the first accept in
that run appeared to open a conversation while writing nothing at all.

## Known gaps

Real, deliberate, and unfinished as of 2026-07-28. Ordered by what would hurt
soonest. Delete an entry when it stops being true rather than letting the list
rot — a stale gap list is worse than none.

**`hasExplored` is local only.** The two onboarding steps before it mirror
columns on `public.users`; this one lives in `UserDefaults`, so a reinstall walks
someone through the garden a second time. A column and a migration fixes it.

**The plant's position is unverified.** `(858, 1626)` at stage 2 is the check
that has caught every layout regression here, and CoreSimulator has been
unusable since it crashed on 2026-07-29 — several changes have shipped on
arithmetic alone since. Restart the simulator and re-run it.

**App Store privacy labels are not filled in.** The manifest now declares what
is collected; App Store Connect's own questionnaire is a separate answer and
still says nothing. So does the privacy policy, which Google's OAuth verification
and external TestFlight both need anyway.

**Account deletion has never been run end to end.** Both halves exist and are
deployed — the app deletes its own `public.users` row through RLS, which cascades
every table, then calls `supabase/functions/delete-account` to remove the
`auth.users` record, which only `service_role` can do. Confirmed `ACTIVE` with
`verify_jwt` on, but confirming the *function* is not confirming the *flow*: it
has never actually deleted an account, because the only account to test with is
the developer's. Redeploy with:

    SUPABASE_ACCESS_TOKEN=<pat> npx supabase@latest functions deploy \
        delete-account --project-ref fwnezkbesjoazlpaflbq

**A restore has never been run on a device that didn't already have the data.**
`RestoreService` is built and wired into launch, but the only way to know it
works is a genuinely empty install — a fresh simulator or a reinstall — signing
in and getting the garden back. Until that is done, "a new device starts empty"
is fixed in code and unproven in practice.

**A distillation's sync failures are still invisible, and that has cost time
twice.** `SyncService.lastError` is recorded, and for the *upload of records* it
is still never displayed. Deliberate — a failed upload must not interrupt the
garden — but the next silent one will look exactly like the last: a table emptier
than expected with nothing to say why.

**The biographics half of that silence is closed, because it cost a whole
session.** The trade itself is right and stays: **Postgres is the record, so
nothing is shown that the server did not accept.** Those rows used to apply
locally and push in a detached task, so a rejected write left the device
displaying an age or a gender the server had never heard of — true until the next
restore quietly replaced it. `pushUserObject` returns whether the row landed, and
`setBirthday`, `setGender` and `setPlace` write the local record only if it did.

What was wrong was the *other* half. A refusal looked exactly like the confirm
button being broken: the sheet closed, the row stayed on "Add your age", and
nothing said why — which is precisely how it was reported ("no matter what i edit
it doesnt save"). The value still waits for the server; the reason now surfaces
through `DistillViewModel.biographicsError`, drawn by the one `statusBanner` in
`AppShell` and carrying PostgREST's own message. `saveName` was the same bug in
its cheapest form — a `try?` on the call site throwing the message away.

**What it turned out to be, once the message was on screen: "no session to write
a profile with" — thrown at a user who had one.** `upsertProfile` and
`markPhotoStepSeen` guarded on the stored `accessToken` property; every other
write in the app goes through `validAccessToken()`, which refreshes. The raw
property is nil far more often than it looks — an access token lasts an hour, and
a cold launch has none at all until `restoreSession()` has been round the
network. `RootView` decides the first screen from the Keychain *precisely so it
need not wait for that*, so someone can be legitimately signed in, looking at
their garden, with the property still empty. Both now use the accessor.

Three things generalise from it:

- **Never guard a request on the stored `accessToken`.** `validAccessToken()`
  exists because the in-memory token is a cache, not the session. `loadProfile`
  is the one deliberate exception, and only because `restoreSession` calls it
  having just exchanged a token — the accessor there could re-enter it.
- **Read `userID` *after* awaiting the token, never before.** The refresh is what
  fills the id in on a cold launch. Guarding on it first reports "not signed in"
  for a session that is merely not restored yet — the same bug wearing different
  words, and it was written into `pushUserObject` while fixing this one.
- **Every `return false` on a push path must set `lastError` first**, or a dead
  session reports itself as a network problem and sends the user to check their
  signal.

And **a value that needs the server should fail loudly, while a value that
doesn't shouldn't wait** —
`setEducation` and `setOccupation` own no column, so they travel as ordinary
`user` records and apply locally at once. That asymmetry is the whole diagnosis:
when the two column-backed rows failed and the two record-backed ones didn't, the
refusal had to be on `rest/v1/users`.

**Photos are built and `0015` is unapplied**, which is the whole of what is left
of "photos go nowhere". `PhotoService` uploads to a private `profile-photos`
bucket at `<user_id>/<position>.<ext>` — the position *is* the order somebody
meant, so re-picking slot 2 overwrites slot 2 rather than leaving a seventh
photograph behind — and `DiscoveryCardService` carries the paths onto the card
the same way it carries the name. Until the migration is applied every upload
fails at a bucket that does not exist.

**The six boxes take photographs only, and that is a deliberate stop rather than
a limitation.** `PhotoGrid` has one `.photosPicker` serving both onboarding and
Memories, and `matching: .images` filters inside Apple's own picker process — so
videos are *absent* from the library rather than shown and refused. It is out
because `PhotoService.encode` had no re-encoding pass and uploaded a video as
picked, which fails at the bucket's 15 MB door after the person has waited for
it. Restoring it is `.any(of: [.images, .videos])`, the encoder's commented
branch, and the MIME types in `0015` — plus the `AVAssetExportSession` that was
the actual missing piece. The view's five video branches are left in place and
marked dormant; `load` branches on what the item *is*, not on what the picker was
told to allow, so the safety does not rest on the filter. **Chat attachments are
a different feature and still take video** — `chat-media` allows it and has a
50 MB ceiling.

`kind`'s `video` option and the four crop columns stay in `0015` although nothing
writes them: video crops are stored as unit rectangles rather than baked in
because the file needs re-encoding for size anyway, and both belong in one pass.

**Some things can be set but never changed.** The name had this and no longer
does — it is the first biographics row on the dashboard, through `NameSheet`.
The shape of the bug is worth keeping in mind for the next field: a value
captured once during onboarding, on a screen nobody returns to, is a value with
a typo in it forever. The biographics rows had the same defect from the other
side, rendering only once they held a value, so nobody could put a first one in.

**Discovery reads across accounts, and the isolation was measured on
2026-07-29 rather than assumed.** `discovery_cards` (migration 0007) is the only
table one user may read about another, and it is deliberately not a view over
`distilled_records` — it carries a name, an age, a district, six photo seeds and
derived `{domain, subject}` pairs, nothing that could rebuild a distillation.
Checked from a real signed-in session: 6 cards visible, 13 own records visible
against 2528 that exist, and 0 cards to an unauthenticated caller. Re-run that
check if the policies are ever touched — a table opened for read is the one
place in this schema where a mistake is silent.

**`health_sports` is empty and it is not yet known whether that is right.**
Checked directly rather than inferred: 0 rows, against 1 in `health_signals`. So
chronotype computed and sports didn't. The early return that used to make this
ambiguous — `guard !sports.isEmpty else { return }` ahead of the insert — is gone,
so from the next distillation an empty table means the device genuinely derived
no sports. Settle it by checking whether the Health app has workouts at all.

**The append/change-only path has never run from the app.** Migrations 0004-0006
are applied and were exercised directly against the database — an unchanged
553-row replay wrote 0 rows, a change wrote 1, and the summary took the newer
value — but no distillation has gone through `append_source_records` from the
phone. Distil Apple Music twice and confirm the second run writes only what moved.

**Credential rotation, closed on 2026-07-29.** Kept as a record of what was
done and why, because the shape of the mistake matters more than the keys.

Three were exposed across working sessions — the `service_role` key, the
`jwt_secret`, and an `sbp_` personal access token — none in the repo, all in chat
transcripts, which is where secrets get read long after anyone is thinking about
them. The two from July were still live when checked eight months later, which is
the argument for doing this at the time rather than noting it.

- **The PAT** was revoked. Confirmed rather than assumed: the Management API
  answers 401 with it. Generate a fresh one only when a deploy needs it; a token
  that exists for twenty minutes cannot leak from a config file next year.
- **The `service_role` and `anon` keys** were both JWTs derived from the legacy
  secret, so retiring them was one action rather than two — but not the one
  expected. The project had already migrated to JWT signing keys, which makes the
  legacy secret verification-only and leaves no rotate button; what kills the
  exposed key is **disabling the legacy API keys** on the API keys page.
- **`AppConfig.supabaseAnonKey` is now `sb_publishable_…`**, and so is the
  extension's own copy. Both were checked in the *built* binaries rather than the
  source, because there are two and forgetting one gives a share sheet that
  silently fails while the app works.

**Never commit `sb_secret_…`.** It is the successor to `service_role` and is
subject to no row-level security whatsoever. `tools/seed_synthetic.py` and
`tools/chat_e2e.py` need one; both read `SUPABASE_SECRET_KEY` from the
environment with no default, and that is the pattern for anything like it.

**A fourth exposure, 2026-08-01 — and it went the same way as the first three.**
The secret key was pasted into a chat transcript during the two-party chat test,
after being asked for in a file precisely so it would not be. Rotated the same
day. Two things about it are worth keeping:

- **The repo was never the problem, and never has been.** Checked rather than
  assumed: not in the working tree, and `git log --all -S` found it in no commit.
  All four exposures have been transcripts. That is where secrets get read long
  after anyone is thinking about them, and the July pair were still live eight
  months later.
- **Nothing that ships was affected**, which is the standing design and the
  reason a rotation here is cheap: both targets carry only
  `AppConfig.supabaseAnonKey`, a `sb_publishable_…` value that is public by
  intent. If rotating a secret ever *does* require a rebuild, something has been
  put in the app that should not be.

Revoke, then **verify the old key is dead with a request** rather than trusting
the dashboard — a revoked key that still answers `200` is the failure this check
exists for. `SUPABASE_SERVICE_ROLE_KEY` was retired as a variable name at the
same time: `service_role` keys are disabled on this project, so the name
described a credential that no longer exists while continuing to work, which is
the shape of mistake that made the July rotation confusing.

**Every TestFlight upload needs `CURRENT_PROJECT_VERSION` bumped.** At 9 today.
It appears **six times** in `project.pbxproj` — Debug and Release for the app,
the share extension and the UI tests — and all six have to move together. The app
and its extension sharing a build number is a hard requirement of the upload,
not a tidiness rule.

**"Uploaded" is four states short of "a tester has it", and the gap is silent
at every step.** Testers reported on 2026-08-03 that they were still on build 1.
Build 8 had been uploaded six days after it and had processed cleanly; what it
had never been was **submitted for Beta App Review**, so App Store Connect held
it at **Ready to Submit** while build 1 stayed the one marked **Testing**. The
local archive records prove only the upload leg — read the TestFlight tab for the
rest. The full ladder, and a build can die on any rung with no notification:

    archived -> uploaded -> processed -> in a tester group -> review-approved -> Testing

Build 6 died on the third rung: **Failed** in the build-uploads list on
2026-07-30, never a candidate for anything downstream. Its reason is the one
below, and it was fixed in passing by `eac98a8` — which is why build 8, archived
three days later, processed cleanly and nobody ever learned what had happened to
6.

**A purpose string is demanded for the API you *could* call, not the one you
do — and the deployment target decides which key's name.** Twice now:

- Build 1, `NSHealthUpdateUsageDescription`, for an app that never writes to
  Health. The HealthKit entitlement permits writing, so the string is required;
  ours says plainly that nothing is written.
- Build 6, `NSCalendarsUsageDescription`, when
  `NSCalendarsFullAccessUsageDescription` was already there.
  `requestFullAccessToEvents` is iOS 17+, but the app deploys to **16.0**, so the
  legacy key is required as well. Having only the modern one is what failed.

Both are `ITMS-90683`, both arrive after a successful upload, and both name the
missing key outright — so the error is easy once seen and invisible until then.
Adding a source that touches protected data means adding *every* key its
framework can reach, back to the deployment target.

**Separately, an embedded extension's `IPHONEOS_DEPLOYMENT_TARGET` must not
exceed the app's.** Xcode gives a new target the *SDK* version by default, so
`ShareToWritten` was created at **26.5** against the app's 16.0 and shipped that
way in builds 6 and 8 — anyone below 26.5 gets an app with no share extension in
it. This was found while diagnosing the above and is *not* what stranded the
testers; it is a real defect that the symptom happened to lead to. Check the
bundles, not the build settings, because it only becomes visible once baked in:

    A="$(ls -dt ~/Library/Developer/Xcode/Archives/*/*.xcarchive | head -1)"
    plutil -p "$A/Products/Applications/Written.app/Info.plist" | grep MinimumOSVersion
    plutil -p "$A/Products/Applications/Written.app/PlugIns/ShareToWritten.appex/Info.plist" \
        | grep -E "MinimumOSVersion|CFBundleVersion"

Both must read the same minimum and the same build number. It costs nothing and
it catches this before a round of processing does.

**Whether a build was ever sent is answerable offline**, from the
`Distributions` array inside each `.xcarchive/Info.plist`. Three builds have gone
up from this machine — 1 on 2026-07-27, 6 on 07-30 and 8 on 08-02 — and all three
are recorded there as `Uploaded to Apple / success`, along with build 1's first
two attempts, which failed validation on a missing
`NSHealthUpdateUsageDescription` before the CLI re-archive passed. Read it rather
than trusting memory. But read it for what it is: **`success` there means the
bytes reached Apple**, nothing further. Build 6 carries exactly that stamp and
still shows **Failed** in App Store Connect's own build-uploads list.

**What fails here is the *unattended* upload, not uploading.** An earlier note
in this file said the machine could not upload at all; it was written from a CLI
export that failed seven minutes before an Organizer upload succeeded. The
distinction is credentials:

    error: exportArchive No Accounts
    error: exportArchive No signing certificate "iOS Distribution" found

`xcodebuild -exportArchive` sees no Apple ID and no App Store Connect API key, so
it cannot mint or use a *distribution* certificate; the only codesigning identity
in the keychain is `Apple Development`. Xcode's Organizer signs in interactively
and re-mints what it needs, which is why the GUI route works and the scripted one
does not. Two ways out, and the second is the one worth doing:

- Xcode → Settings → Accounts → sign in, then Product → Archive → Distribute App
  → **App Store Connect**. Needs 2FA every time and cannot be scripted.

  **Not "TestFlight Internal Only", which is a one-way door.** It sets
  `testFlightInternalTestingOnly` on the export, and Xcode's own description of
  that key is "this build cannot be distributed via external TestFlight or the
  App Store". It marks the *build*, not the app — the way out is to upload a
  higher build number — but the option sits directly above the right one in the
  same list, and picking it costs a number and a round of processing.
  `app-store-connect` puts a build where internal testers, external testers and
  App Store submission can all reach it.
- **An App Store Connect API key** — Users and Access → Integrations → App Store
  Connect API, role App Manager. Drop `AuthKey_<KEYID>.p8` in
  `~/.appstoreconnect/private_keys/` and `xcodebuild -exportArchive` can upload
  unattended with `-authenticationKeyPath/-KeyID/-KeyIssuerID`. The `.p8`
  downloads **once**, and it is a credential — treat it like `sb_secret_…`.

And note **which** testers: internal ones (team members) get a build the moment
it finishes processing, but **external testers need Beta App Review**, which
needs the privacy policy and the App Store privacy questionnaire — both still
open above. "All TestFlight users" is blocked on those, not on the build.
