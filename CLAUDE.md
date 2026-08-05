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
| YouTube | Google OAuth (PKCE, `ASWebAuthenticationSession`) | Sheet shares Safari cookies → tap account, tap Allow. Refresh token in Keychain ⇒ later distills zero-tap — **but only in production**; see below. |
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

**Google's consent screen is in Testing, and that is not just a user cap.** It
allowlists 100 users, which is the part everybody knows — and it **expires every
refresh token after exactly 7 days**, which is the part that has been quietly
false in the table above since it was written. Zero-tap re-distillation is a
property of a *published* app. Every tester on this build is re-authorising
YouTube weekly and nobody has reported it, because a re-grant looks like the
normal flow.

Publishing needs Google's OAuth app verification, and two gates get conflated:

- **The submission** — consent screen, a domain we own and have verified in
  Search Console, a scope justification, and a YouTube-hosted demo video showing
  the real grant, the app name and the client id. Mechanical, but weeks.
- **The YouTube API Services Developer Policies**, which is not a form. III.E.4
  permits storing beyond **30 calendar days** only Analytics data, Reporting data
  and *statistics* — view counts, subscriber counts. Titles, channel names and
  playlist contents are capped at 30 days and must then be deleted or refreshed.
  This schema says "nothing in Postgres is ever deleted". **It is the same
  objection that removed Spotify, arriving for the source the product cannot
  drop.**

  The resolution is **derive, then delete the raw**, and it is built —
  `0016_youtube_retention.sql`, a daily `pg_cron` job at 03:17. Rows live up to
  30 days as the ontology/embedding input, and after that only derived,
  non-identifying output remains. Three stores hold YouTube strings and missing
  one makes the sweep cosmetic — `distilled_records`,
  `discovery_cards.interests` (whose `subject` is a channel name), and
  `shared_posts`, which is deliberately *not* swept: that video id came from a
  public URL somebody pasted into the share sheet rather than from an authorised
  API call, which is genuinely grey and wants a written judgement rather than a
  delete written on a guess.

  **The sweep also satisfies the 30-day revocation deadline for free, and this
  is provable rather than hopeful.** Revoke at Google and everything read from
  YouTube must be gone within 30 days of the revocation; the sweep deletes 30
  days after *collection*, and a revocation is never earlier than the collection
  it revokes, so `collection + 30 ≤ revocation + 30` always. No machinery is
  needed for that route at all. It is the 7-day case — a deletion *request* —
  that the sweep cannot cover, because that deadline can start on day zero.

  **Revocation is a hard deadline, not a courtesy.** Revoked in the app, that
  user's YouTube data must be gone within **7 days**; revoked at Google, 30.
  `OAuthPKCEService.disconnect()` exists and no UI calls it.

**`youtube.readonly` is *sensitive*, not *restricted*, and that is worth weeks.**
Restricted scopes — Gmail, Drive, Fit, Chat, Health, Data Portability — require a
CASA third-party security assessment. No YouTube Data API scope is on that list.

**Quota is a launch-day ceiling, not a theoretical one.** 10,000 units/day, 1 unit
per `list` call; with `maxPagesPerEndpoint = 10` and `maxPlaylistsExpanded = 15` a
worst-case distill is ~185 units — about **54 distills a day across all users**.
The *YouTube API Services Audit and Quota Extension* form is a second review with
its own queue, so it starts when verification is submitted, not when it bites.

**`written.app` is not ours, and `written-stl.com` now is.** `SignInView` linked
its Terms, Privacy and Cookies at `written.app` for months — a live, unrelated
decentralised e-book store with its own App Store listing and Discord — so all
three were dead links promising documents nobody had written. `written-stl.com`
was registered at Cloudflare on 2026-08-04 and the three pages exist, in `web/`.

`written.com` was wanted and is not buyable: registered in 1996, behind WHOIS
privacy, and 301-ing to NameArena LLC, a brokerage with an inquiry form and no
published price.

**The site is live**, confirmed 2026-08-05: `written-stl.com` answers from
Cloudflare (`104.21.7.174` / `172.67.137.17`) and every page served is
**byte-identical to `web/`** at `7bf6b65` — the five pages, `styles.css`,
`app.js` and the assets. `web/README.md` carries the deployment steps; the
Worker config is `wrangler.jsonc` at the repo root, serving `./web` as static
assets with no Worker script. `/` 301s to `/en-us/`, a missing path 404s, and
the two URLs Google's consent screen must name — `/en-us/` and `/en-us/privacy/`
— both answer 200 with no redirect, which is what that check requires.

**`www.written-stl.com` does not exist**, and it is the one way somebody can
find this site down. There is no A record at all — NXDOMAIN, not a Cloudflare
error — so a browser says the server could not be found rather than anything
about Written. The apex is the only hostname that works. One proxied CNAME at
Cloudflare fixes it.

A free host subdomain cannot stand in, and that is a rule rather than a
preference: Google requires the homepage be *"Hosted on a verified domain you
own"* and verification needs a Search Console **Domain property (DNS-level)**,
*"rather than a 'URL prefix' or 'Site' property"*, done by an account that is a
**Project Owner** of the Cloud project. Nothing can add a DNS record to
`pages.dev`.

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
  **Birthdays and public holidays are excluded, and for a while they only
  looked it.** `CalendarDistiller.name(for:)` writes `subscription` and
  `birthday`; the dashboard's filter compared against `Subscription` and
  `Birthday`, so it matched nothing and every one of them reached the card. A
  filter that reads correct and excludes nothing is worse than no filter — this
  one was cited in this file as done. **A test against a string another file
  produces has to be checked against that file.**

  **A row with no `cal_type` is not drawn**, which reverses what this file used
  to say — that such rows predate the filtering and dropping them would hide real
  events too. Counted rather than argued, on a real device: **95 calendar rows,
  every one of them untyped**, of which 51 were `US Holidays`, 37 `香港节假日`,
  one `Birthdays`, and six were real. The trade was the wrong way round by
  fifteen to one.

  It costs nothing permanent, and that is the part worth keeping: the distiller
  stamps `cal_type` now, a re-stamped row differs from its stored version, and
  `append_source_records` treats a difference as a change — so **one re-distill
  returns every event the person still has, typed**. What does not come back was
  on a calendar filtered at collection.

  The calendar's *name* is the last test rather than the only one, through one
  shared `CalendarDistiller.isGenerated`, because holidays arriving through a
  Google or Exchange account are `caldav`: an ordinary type, from a server,
  indistinguishable by type from a real diary. It matches English plus 节假日 /
  節假日, the one other form there is direct evidence of. **That list will always
  be incomplete** — which is exactly why it runs last, after the type has settled
  everything it can.

  **The card lists the events themselves**, one row per distinct title, **ranked
  by what made the entry rather than by when it happens**. Date order is why a
  flight to Los Angeles could not be found on a card listing it: newest-first put
  five years of dentist appointments, term dates and public holidays above four
  real flights, which sat 59th to 68th of 77 against a cap of 40. The ranking
  leans on the two fields kept for exactly this — `url` and `organizer`, which
  tell a booked event from a typed one. Something else wrote these in; "1st
  email" is a note to self.

  **Titles carrying `birthday` or `meeting` are not drawn**, in either script.
  The calendar test could never have reached them: `CalendarDistiller.isGenerated`
  reads the calendar's *name* and catches Apple's generated `Birthdays`, while
  "Augh birthday" typed into somebody's own diary is an ordinary event in an
  ordinary calendar. **A reading, not a filter on what is kept** — every one of
  those 24 rows is still collected, still synced and still goes to the ontology
  stage, because a fortnightly Zoom is a real fact about a week. It is simply not
  what a person recognises their own year by.

  **Public holidays copied into a personal calendar need a name list, and that
  was established by measurement rather than assumed.** `PublicHolidays` is it.
  The calendar-level test cannot reach them — it drops a calendar *named* for
  holidays, which catches Apple's `US Holidays` and `香港节假日`, while Google
  copies the same days into somebody's primary calendar as ordinary events. Nor
  can any structural test: of 77 surviving events on a real device, **49 were
  public holidays, and all 49 were all-day, unrecurring, unorganised and
  unbooked** — character for character what "Outpatient", "Marco's arrival" and
  "1st email" look like in the same calendar. There is nothing in the shape of
  the row to separate them.

  Matched **by token, not by whole name**: Google writes one day a dozen ways
  ("New Year's Day observed", "First Weekday After Christmas Day", "Second Day of
  Lunar New Year"), and one token catches the family where an exact-name list
  would need every variant and still miss the next. It is **incomplete by
  construction** — two regions and the observances that travel — because the
  alternative is a rule broad enough to swallow a real event, and losing
  somebody's trip costs more than showing them Karneval.

  Its known softness is the ranking's middle tier: a meeting the user themselves
  organised is an invitation too, and outranks a flight. Recognising that needs
  their own name, which these records do not carry.
 It
  printed readings for a while — arranged, booked ahead, evenings, weekends,
  busiest day — and nobody recognises their own year in a count; they recognise
  "Chichen Itza Premier Tour" and "Flight to Los Angeles". Distinct titles
  because a calendar is mostly repetition, and fifty copies of "Gym" bury the
  three things worth reading. `ListeningHighlights.shape` is kept and drawn by
  nothing: booked-against-typed, evenings, weekends and the busiest day are real
  derived readings the ontology stage will want, and they should not have to be
  worked out twice.
  **Events are stored whole and synced**, unlike HealthKit, because the titles
  *are* the signal. That is a deliberate trade and it puts other people's names
  and locations in the database; `PrivacyInfo.xcprivacy` says so. Windows are
  `AppConfig.calendarLookbackDays` / `calendarLookaheadDays` — both directions,
  because a ticket bought today for November only exists ahead of now — capped by
  `maxCalendarEvents`. **Five years either side**, up from 365 back and 180
  ahead. A flight to Los Angeles disproved the old numbers: booked, paid for, a
  place and a date, and 180 days is exactly the window that excludes the holiday
  somebody planned in advance while including the dentist. The trip is what this
  source exists to catch, and trips are what sit outside a year. A repeating
  entry was the argument for keeping it short and is a solved problem — the fetch
  keeps one occurrence per identifier and marks it `recurring=1`.

  **Widening it moved the cap from a backstop to a chooser.** The chunks used to
  be walked oldest-first and the fetch returned on `maxCalendarEvents`, which was
  harmless over eighteen months and is not over ten years: a decade of standing
  meetings fills the ceiling somewhere in 2021 and the walk stops before reaching
  anything ahead of now — losing the booked trip the widening was for. They are
  walked outward from today now, so a cap costs the furthest year in either
  direction, which is the year worth losing.

  Two traps: `predicateForEvents` silently returns nothing
  across more than four years, so the fetch is chunked by year — **which at five
  years either side is the only reason anything comes back at all**, since one
  ten-year predicate returns an empty list and no error, indistinguishable from a
  person with no plans; and on iOS 17+
  the old `requestAccess(to:)` grants *write-only*, which reads nothing and looks
  exactly like an empty calendar, so `requestFullAccessToEvents` is required.
- **Google Calendar** (`GoogleCalendarDistiller`) — **offered only where the
  phone has no Google account**, and that condition is the whole design. A
  Google account added in iOS Settings delivers its events through EventKit as
  `caldav`, so `CalendarDistiller` already has them; collecting them again here
  would put every dinner in the database twice, under a different `item_id` and
  a different `source`, which `append_source_records` dedupes *within* a source
  and would not catch. `CalendarDistiller.hasGoogleAccountOnDevice()` tests the
  `EKSource`, not calendar names, which are whatever somebody called them.
  `SourceAvailability` hides the row and `DistillViewModel` guards it too — a
  hidden row is a drawing and not a rule, and somebody who adds the account
  afterwards would otherwise start collecting everything twice.

  **Two narrow scopes rather than `calendar.readonly`** —
  `calendar.calendarlist.readonly` and `calendar.events.readonly` — because
  verification asks for a justification per scope *and* why a narrower one will
  not do. Neither is restricted, so this stays a sensitive-scope review with no
  CASA assessment. The condition above is also the honest answer to "why do you
  need this": *only for users whose calendar we cannot otherwise see*.

  Nothing downstream knows it exists: the records carry the same `extra` keys,
  so the events card, the booked-against-typed ranking and the ontology stage
  are unchanged. Birthdays go by Google's own `eventType`, which beats the Apple
  path's title matching — that one misses "Augh birthday" and always will.

- **Google Health is not possible on iOS, and this is settled rather than
  deferred.** The Fit REST API stopped accepting new developer signups on
  2024-05-01 and is supported only to the end of 2026; Health Connect is an
  Android-only on-device layer with no cloud API; and Google's own migration
  guidance sends iOS developers to Apple HealthKit, which `HealthKitDistiller`
  already uses. There is no API to apply for. Worth knowing `fitness.*` was a
  **restricted** scope, so even when it existed it would have dragged this
  project into a CASA third-party security assessment — losing it is cheaper
  than having it.

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
- **The authorization request is not a query and must not share the query
  ceiling.** `stage`'s twenty seconds is right for a database call that may
  never come back and wrong for `requestAuthorization`, whose callback does not
  fire until the user *answers the sheet* — so twenty seconds was a limit on how
  long somebody was allowed to think, and the app itself asks them to think,
  since every category opens off and Allow stays disabled until one is switched
  on. It then compounded: `stageTimedOut` is the one error the retry refuses, so
  a slow read was terminal and the grant being given at that moment was thrown
  away. `authorizeTimeout` is 180s, `stageTimeout` stays 20. Measured while
  checking it: on an erased simulator the sheet sat unanswered for **35
  seconds**, which under the old ceiling was already a failure with the sheet
  still on screen.
- **Ask nothing of HealthKit while a sheet of ours is dismissing.**
  `SourcePickerSheet.row` started the distillation and *then* closed itself, so
  HealthKit was asked to present its remote view over a modal in mid-dismissal —
  a context that is disappearing. `waitUntilActive` cannot see that: it tests
  `applicationState`, which stays `.active` throughout a sheet dismissal. The
  row records the choice now and `.sheet(item:onDismiss:)` starts it, which is
  the transition's own completion callback and needs no guessed delay. Right for
  every source, not only Health — YouTube's `ASWebAuthenticationSession` and the
  MusicKit and EventKit alerts are all presentations racing the same dismissal.
- **A Release build may now say what failed.** `BuildKind.isBeta` — a TestFlight
  build carries a *sandbox* receipt where an App Store build carries `receipt` —
  so Debug and TestFlight print the diagnostic and a shipped build does not.
  This exists because two rounds of diagnosis produced two different answers
  from the same tester screenshot: `stageFailed` and `stageTimedOut` rendered
  *identically*, with the separating detail behind `#if DEBUG`, and TestFlight
  is Release. The detail is now the whole run rather than its last line —
  `health · sheet-expected · +0.04s since tap · auth#1 err 10.2s [...] · auth#2
  ...` — and long-pressing copies it, because a wrapped line of stage names is
  exactly what gets cropped out of a screenshot.

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

**A row's note is for a dead end; the sheet's notice is for everybody.** Those
are two different things and keeping them apart is what stops
`note(forSource:)` growing back into a per-source description — Podcasts had one
explaining what it read and it was deliberately removed on exactly that
principle. So `SourcePickerSheet.privacyNotice` sits *under* the rows rather
than inside one: *"Read once, never in the background"*, with the privacy
policy linked. It is there because Google's OAuth verification requires
in-product privacy notices to be **prominently displayed**, and the only one
this app had was on the sign-in screen — passed through weeks before anybody
grants YouTube. The sentence is the snapshot rather than a list of fields,
because the next screen lists the fields in Google's or Apple's own words and
what it cannot say is whether agreeing once means agreeing forever. It does not.
`detentHeight` counts this too, and it is the *last* thing on the sheet, so an
underestimate crops the line naming the policy.
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
- **And a connection is not the same fact as a row.** Connectedness was inferred
  from record *volume* — `TreeMetrics.metrics` answers `nil` for a modality with
  no rows — so a YouTube account with no likes and no subscriptions was
  indistinguishable from an untouched one. Everything reads `branches`:
  `nextModality` kept offering the same modality, no `ConnectedBar` appeared, the
  badge ring stayed empty and the plant stayed at stage zero, with **no error
  anywhere, because the distillation had succeeded.** Reported as the flow never
  moving on.

  `ConnectionStore` is the local half of `source_connections`, which the server
  has always recorded correctly — `append_source_records` upserts the row even
  from an empty array. `replaceRecords` is the hook, being the one point every
  source's rows pass through, and usefully the one Calendar returns *before*
  reaching on an empty result: Calendar and Health keep failing loudly on
  nothing, which is right, because for those two an empty answer and a refused
  permission are the same answer. For YouTube they are not.

  It matters most for **Podcasts**, where zero is the *normal* result — that
  source only ever sees downloaded episodes.
- Exports are git-ignored (`written-distillation-*.csv`) — they are personal
  data and must never enter history.

## Signing in: three routes, and all three of them are real now

Apple, Google and phone. That sentence was false until 2026-08-04 and the way it
was false is the most expensive bug this project has had.

**Three of the four buttons authenticated nobody.** "Create account" — the
largest button on the launch screen — and "Sign in with Phone Number" both
pushed `PhoneNumberView`, whose completion set `route = .photos` with no call to
anything; "Sign in with Google" set `route = .home` outright. The phone screens
were finished and had never been wired up, because Twilio was rejected on cost,
and nobody ever stopped them being reachable.

What that did to a tester who took the obvious button: **no session**, so the
photo page correctly answered "You're not signed in"; **no `route(for:)`**, so
the name and communication style steps were skipped; **no `auth.users` row**, so
nothing they did could be saved and nobody could find them in Explore. The
account was gone by the next launch, because `initialRoute()` reads the Keychain
and nothing had been written to it.

**It cost a day of looking in the wrong place** — the discovery publisher, the
feed, the photo pipeline — all of which produced four genuine fixes that were
none of them the reason. The lesson is cheaper than the search was: **a button
that does nothing is worse than an absent one**, and "the account doesn't exist"
is a hypothesis worth eliminating before any of the machinery downstream of it.

- **Apple** — native `ASAuthorization`, identity token traded for a session.
  Free, instant, and the only one that ever worked.
- **Google** — the *same* PKCE machinery that connects YouTube, asked a
  different question. `OAuthProvider.googleSignIn` requests `openid email
  profile` and the `id_token` goes to Supabase's `grant_type=id_token`, exactly
  as Apple's does. No SDK, no client secret — a native client has none — and the
  dashboard side is this app's client ID in **Authorized Client IDs**, because
  Supabase validates the token's `aud` against that list.

  Two refusals in it are deliberate. It does **not** persist Google's refresh
  token: the one that matters is Supabase's, and saving Google's would file it
  under `AccountScope.current`, still `local` because the account being signed
  into does not exist yet. And `interactiveIdentityToken` never reuses a cached
  or refreshed token, unlike `validAccessToken` — reuse is right for reading a
  library and wrong for proving identity, where a token refreshed from the
  previous user's grant signs the wrong person in.
- **Phone** — Supabase's **Twilio Verify** provider. `sendOTP` / `verifyOTP`,
  sharing session adoption with the other two through `adopt(_:)`, which was
  lifted out of `exchange` precisely because phone arrives from `auth/v1/verify`
  rather than `auth/v1/token` and needs the identical five steps. Two copies
  would be two places to forget the `UserDefaults` write that `AccountScope`
  reads.

**Route from the step, never from a constant.** `onSignedIn` calls
`route(for: onboardingStep)`. Hardcoding `.photos` is what skipped the
communication style page for every phone user.

**E.164 is built once** (`PhoneNumberView.e164`) and used for both calls.
Supabase verifies a code against the number it *sent* to, so a space in one
string and not the other fails a correct code against a number never messaged.

### What phone costs, and why it is not charged for

~$0.058 a verification in the US, **~$0.12 in Hong Kong** — a flat $0.05 Verify
fee plus the SMS channel fee, which is roughly eight times higher in HK because
it is a small market terminating internationally. It cannot be passed to users
on iOS anyway: in-app charges for digital services must go through IAP, whose
price points start around $0.29. Every competing dating app absorbs this.

**The exposure is fraud, not traffic.** SMS pumping — driving OTPs to premium
numbers for a share of the termination fee — can burn hundreds overnight. Four
controls, in order of how much they buy:

- **Twilio Verify geo permissions, Hong Kong / Taiwan / US only.** Console →
  Verify → Settings → Geo permissions. **This is separate from Messaging geo
  permissions**, which look identical and do nothing for Verify traffic —
  setting those and assuming you are covered is the trap.
- SMS Fraud Guard on.
- Supabase SMS rate limit at **10/hour**, project-wide: a ~$29/day worst case.
  Note it is *not* per-user, so five testers in an hour is half the budget spent
  legitimately.
- **CAPTCHA deliberately not enabled.** On native iOS it means a WebView-hosted
  challenge and a token threaded into `sendOTP` — real work and real friction
  against an exposure the three above already bound. **Revisit the day that rate
  limit is raised for real volume**, when the ceiling stops protecting anything.

Twilio also gates sending behind **Trust Hub KYC**: an unapproved primary
compliance profile answers "Primary compliance profile is not approved" and no
SMS leaves. An Individual profile is enough for Verify and reviews in up to 48
hours; only toll-free needs a Business one.

**Two sign-in methods mean one person can hold two accounts.** Identity linking
is unbuilt and was consciously deferred for the beta — for a dating app that is
a duplicate in the pool, so it wants deciding before launch.

## Launch routing: the first frame must already be the right screen

`RootView` picks one of five screens — `signIn`, `name`, `communication`,
`photos`, `home` — from a single `Route`, never a set of booleans that can
disagree. Two rules, each paid for once:

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
  auth service; `OAuthPKCEService` is provider-parameterized. Google *sign-in*
  is a second case on the same client rather than a second service — see
  `googleSignIn`, and note `persistsRefreshToken: false` on it.
- **`web/` is the website, and it is not part of the app target.** A static
  page, no build step, deployed as a Cloudflare Worker serving `./web` as
  assets — `wrangler.jsonc` at the repo root, and `web/README.md` for the
  deployment, the review flags and the two headless-Chrome traps that cost a
  measurement each.
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
- **`Array.sort` is not stable in Swift.** Sorting messages on `sentAt` alone
  left rows with equal timestamps in a different order on every four-second
  poll, and the unread band — anchored to one message id — appeared to wander
  between them. Ties break on `id` now. Equal timestamps are rarer in life than
  in testing, since `now()` is the *transaction* time in Postgres and a batch
  inserted in one statement shares it exactly, but two messages arriving in the
  same microsecond is not a coin worth flipping on every poll.
- **Version a cache file when its model gains a field whose absence means
  something.** `ChatStore` writes `Message` as JSON; `read_at` was added and
  every row written before decoded with `readAt = nil`, which is
  indistinguishable from genuinely unread — so an ancient message put a phantom
  unread band at the top of a thread and kept it there through every relaunch.
  The prefix is `written-chat-v2-` for that reason. **An optional that decodes to
  nil is a value, not a gap**, and every reader downstream will treat it as one.
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

`ShareToWritten` is the second of three targets — the first this project had.
(`NotificationService` is the third; see the notifications section, and note it
deliberately carries *neither* the App Group nor the keychain group, because its
image URL arrives pre-signed and it needs no session at all.) It needs
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

**There is a second precondition, and it is not a privilege — it is a policy.**
`on conflict do update` has to be able to *see* the row it might update, so a
table with RLS enabled and **no select policy cannot be upserted into at all**,
including when it is empty and no conflict is possible. `device_tokens` was
given insert, update and delete policies and deliberately no select policy —
one fewer place a token can leak — and every registration answered `403 … new
row violates row-level security policy … 42501`, which reads as a wrong
`user_id` and was nothing of the sort. The id was right and the insert policy
was right; the missing policy was for an operation the app never performs.
`0021` adds it. So the rule is: **`merge-duplicates` needs update privilege *and*
a select policy**, and every other table here happened to have both.

**A name in a chat was a copy of a copy.** `likes.liker_name` is denormalised
when a like is sent, `ChatService.open` copies *that* onto the conversation, and
nothing ever corrected either — so a profile read "Chan Tai Man" in Explore and
"Marco" in the chat header, and anything wrong at that instant was wrong forever.
Names now come from `discovery_cards.display_name` through
`ChatService.cards(for:)`, alongside the photograph, for the reason that table
was already being read for faces: it is the one place a signed-in user may read
about another, and a copy elsewhere is a second thing to keep in step. The stored
columns remain as the fallback, because `0009`'s insert policy needs them at
creation when no card may exist yet. `0031` refreshed the rows already written.

**The same gap existed on the two single-conversation fetches**, which resolved
no card at all — so a thread opened from a notification tap drew the generated
portrait and the frozen name while the identical thread opened from the list drew
the real ones.

**One invitation per person, and it is either a heart or a note.** The card used
to fill the heart whichever route was taken and leave the envelope live, so the
two controls disagreed about whether anything had happened and a second
invitation could be sent to somebody who had already had one. Whichever was used
is now red and filled and the other fades; both go inert. This reverses a note
that stood here — that a message was deliberately *not* blocked by having already
liked — which was true and not worth a card that contradicts itself.

**`23503` means the person deleted their account.** Every foreign key in this
schema leads back to `public.users`, and deleting an account cascades from
`auth.users` through it. A discovery card outlives the account because
`DiscoveryFeed` is built once and scrolled rather than re-fetched, so liking
somebody who has just left failed with `violates foreign key constraint
"likes_liked_id_fkey"` on screen — accurate, unreadable and frightening.
`PostgREST.Failure` carries the error code now rather than folding it into the
message, and the feed removes them and says "That profile is no longer
available."

**Two accounts are needed to test any of this**, because RLS makes each half of
a conversation invisible to the other. `tools/chat_e2e.py` plays the second
person over REST — `users`, `like`, `reply`, `state` — and the six synthetic
accounts are real `auth.users` rows, so one of them can be it. A simulator
cannot be the first person; Sign in with Apple needs a device. **Read the
database after every step rather than trusting the screen**: the first accept in
that run appeared to open a conversation while writing nothing at all.

## Notifications: a like, a match, a message

Three events, sent from the database rather than from a phone — in all three the
person to be told is by definition not the person making the request, and their
session is the only thing that could reach their own devices under RLS. The path
is `likes`/`messages` trigger → `pg_net` → `functions/push` → APNs. **Proven end
to end on a device on 2026-08-05**: a row inserted into `public.likes` produced
the banner, through a real ES256 signature and a real sandbox token.

**`pg_net` is fire-and-forget and that is the point.** `net.http_post` queues and
returns, so a slow or dead APNs cannot make a like fail. The cost is that a
failure is invisible from the app. Right trade here: not being notified is a
disappointment, not being able to like somebody is a broken app.

**But it is not invisible from SQL, and believing it was cost an hour.**
`pg_net` records every response in **`net._http_response`**, readable from the
SQL editor:

    select (content::jsonb ->> 'face') as face, status_code, created
      from net._http_response order by created desc limit 3;

The function's own log lines went unfindable for a known `execution_id` — the
viewer would not show them at any severity — and the fix was to stop logging the
diagnosis and *return* it, where `pg_net` writes it down. **Anything the function
needs to say should travel in the response body**, not only to `console`: the
body needs no log viewer, no curl, and no copy of `PUSH_SECRET`. That
`net._http_response` exists was written into `0020`'s own header comment and
still took an hour to reach for.

**The URL and the shared secret live in `private.push_config`**, a table in a
schema nothing is granted on, filled in by hand. Not a GUC (invisible to the
migration) and not a literal (a secret in git). The function is deployed with
**JWT verification off**, which is mandatory rather than lax: the triggers carry
no Authorization header at all, and the toggle demands a JWT signed by the
*legacy* secret, which this project disabled in the July rotation — so with it on
nothing could satisfy it, including the app. `PUSH_SECRET` and the
`x-push-secret` header are the auth instead.

**Five things about Apple's side, each of which cost a round:**

- **A successful install proves nothing about push.** Xcode's automatic signing
  issues an `iOS Team Provisioning Profile`, and those carry
  `aps-environment: development` **whether or not the App ID has the capability
  enabled** — so the app signs, installs, and APNs even hands over a token,
  because iOS issues one whenever the entitlement is present. What actually
  checks is Apple's **Push Notifications Console**, and a *distribution* profile,
  which is derived strictly from the App ID. A TestFlight build would have had
  no push in it and looked like a code fault.
- **It is a `.p8` key, not a certificate, and the two are not interchangeable
  here.** `functions/push` signs an ES256 JWT from a PKCS#8 key; a `.p12` has
  nowhere to go in that code, and Deno's `fetch` cannot do client-certificate
  TLS anyway. Keys never expire and need no CSR. `Certificates (0)` beside the
  capability is correct.
- **An APNs key must be created as "Sandbox & Production", and the page lets you
  create one that is not.** A single-environment key answers **`403
  BadEnvironmentKeyInToken`** against the other host — so a key made
  Sandbox-only delivers every Xcode build's notification and refuses every
  TestFlight one. That shipped: testers received nothing while development
  worked perfectly, and it read as *lateness* rather than failure, because the
  sandbox notification still arrived on its own unhurried schedule. Two things
  found it, and neither was the phone: `results` in the function's response
  carrying APNs' own reason, and a send to somebody with **two** devices, where
  `["ok", "403 …"]` in one array made the asymmetry impossible to miss.
  **`sent: 2` with `["ok","ok"]` is the only proof that both environments
  work** — a production *token* existing proves the entitlement survived
  distribution signing and nothing more.
- **The token's environment is not bookkeeping.** APNs has two hosts with two
  separate namespaces: a development build's token answers `BadDeviceToken` at
  `api.push.apple.com`, and a TestFlight token fails the same way at the sandbox
  host. Both kinds exist here at once, so `device_tokens.environment` records
  which. `#if DEBUG` decides it.
- **Where permission is asked has been wrong twice, and both are worth keeping.**
  iOS allows the question **once, ever** — a refusal is undoable only in
  Settings, which nobody visits — so the moment decides whether notifications
  work for that person at all.

  It was first asked **on the first admirer**, which put the question one event
  *after* the like that would have used it: nobody's first notification could
  ever arrive, and a tester reported being asked only when their first message
  came in. It was then asked bare **on arriving at Explore**, which spent the
  single attempt cold and landed a system alert on the discovery feed at the
  moment somebody had tapped to see it.

  It now shows **`NotificationPrimer`** — the app's own sheet, naming what
  arrives rather than asking to be allowed — and only somebody who taps *Turn
  on* is passed to iOS. A "not now" spends nothing, because iOS was never asked,
  and is offered again in three days. Fired from `AppShell.onChange(of: tab)` on
  reaching Explore or Chat, 900ms after the transition so it does not cover the
  page it interrupts, and deliberately nowhere near Health — this project lost a
  week to two prompts colliding, because HealthKit hosts a remote view and cannot
  present over anything else.

  **And a refusal is now said out loud.** `ChatView` draws one line for anybody
  in `.denied`, with a route to Settings. Left unsaid it was the same silent
  failure as everything else here: `device_tokens` stays empty, every
  notification reports `{"sent":0,"note":"no devices"}` — a *success* — and the
  person hears about no like and no match and is never told why.

  `-push ask` exists because setting any of this up otherwise requires arranging
  to be liked.
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

**The recurring defect appeared three more times here**, in code written after
the lesson was already in this file — twice in the same file on the same night,
the second time three functions below the first fix. `devices()` returned `[]`
for a request it could not make, which the caller reports as
`{"sent":0,"note":"no devices"}` — a *success*. An unset `PUSH_SECRET` and a
wrong one were one condition and one 401, wanting opposite fixes. And
`senderPhotoURL` returned null from a refused query, an empty result, a refused
signature and a thrown exception identically, so `face=no` could not distinguish
"this person has no photograph" from "storage would not sign". That makes
**seven** instances of *a call that can fail, a result nobody reads, and the
symptom surfacing somewhere else.* (Nine by the end of the same week — see the
offline chat list below, where it finally destroyed data rather than hiding it.)

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
it does not know.** The app declares everything else through `INFOPLIST_KEY_*`
build settings and has no plist of its own, so `INFOPLIST_KEY_NSUserActivityTypes`
was the obvious move — and Xcode wrote nothing at all. No error, no warning, a
built plist without the key. `Written-Info.plist` exists for that one key, at the
repo root beside `Written.entitlements` rather than under `Written/`, because
that folder is a synchronized group and a plist swept into Copy Bundle Resources
ships twice. **Read the built `Info.plist`, never the setting.**

**`updating(from:)` renames the title to the sender's display name**, which is
why `0027` passes `sender_name` and `subtitle` separately. The title is a
headline — "Marco likes you" — and using it as a display name announces somebody
called "Marco likes you". The headline moves to `subtitle`, which
`updating(from:)` leaves alone.

**The photograph is signed server-side.** `functions/push` looks up
`public.photos`, signs a one-hour URL against the private `profile-photos`
bucket, and puts it in the payload; the extension only downloads. An extension
that authenticated for itself would need the session out of the shared keychain
and a refresh, inside a process with a thirty-second life, for a picture. An
hour because a notification can wait on a locked phone, and bounded by the fact
that the link reveals one photograph any signed-in user could already see.

**Everything in the extension falls back to the plain banner** — a missing
photograph, an expired URL, a rejected intent. A notification that arrives
looking ordinary is enormously better than one that does not arrive.

Two smaller ones: `INPersonHandle` is `.unknown` rather than an email or phone,
because claiming either invites iOS to match against Contacts and put somebody's
saved contact photo on a stranger's profile; and `INInteraction.direction` must
be set to `.incoming`, since the default is outgoing and would teach Siri that
*you* messaged everyone who has ever messaged you.

**The small app icon badged on the avatar is iOS's, not ours.** Every
communication notification carries it and there is no API to remove it.

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
because the like was accepted, so a message older than its own conversation
cannot be one somebody sent. Anything typed in gets `now()` and is later by
construction.

### An attachment with no caption

`0010` relaxed the body constraint so a photo could travel without words, and the
app satisfies `not null` with an empty string. The notification passed it through
unread, so an uncaptioned attachment produced the sender's name and **a blank
line** — with voice notes the worst case, since nothing in the app ever pairs
text with one, so every voice message would have notified as nothing. It says
`📷 Photo` / `📹 Video` / `🎤 Voice message` now, and a caption still wins where
there is one.

**Emoji rather than SF Symbols, and that is the medium.** An APNs alert body is
plain text rendered by SpringBoard — no attributed string, no reach into the
symbol set the app draws with. The chat list uses `camera.fill` / `video.fill` /
`mic.fill` for the same three, which is right there and impossible in a banner.
While checking it, `ChatView.lastLine` turned out to test only for `audio` and
let everything else fall through to a camera, so **an uncaptioned video called
itself "Photo"** — visible only to somebody who had sent one.

### Unread, which nothing had ever counted

`read_at`, its policy and its column grant have existed since `0009` and nothing
used them until `0030`. The app had no idea what unread meant.

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
boundary exists only in the first fetch. It is captured once and held for the
life of the page; recomputing would find nothing and the band would vanish while
somebody was reading towards it.

**And it is read off the fetch, never off `messages`.** That array is seeded from
`ChatStore` and merged with the fetch, so it also carries rows older than the
page — and a cached row whose `readAt` is absent decodes as nil, which reads as
*unread*. That put a phantom band at the top of a thread and kept it there
through every relaunch, since `markRead` had nothing left to mark, while the chat
list disagreed because it asks the server. See the cache-versioning note in
Conventions.

**Opening position is bottom when the unread fits and centred when it does not**,
decided by scrolling to the end and asking whether the band survived it — no
height arithmetic, and no guessing from a count that one photograph would
falsify. A band `LazyVStack` never built reports nothing, which *is* the answer.

**Taps route.** `NotificationRouter` records the destination rather than acting
on it, because a tap that launches the app is delivered during start-up, before
`AppShell` exists. `AppShell` moves the tab, `ChatView` opens the page, and a
conversation not yet loaded is fetched by id rather than waited for.

**Not built, and each is a decision rather than an oversight:** a photograph
inside the banner needs a Notification Service Extension — which now exists, so
this is only a matter of attaching one; and an unread count that never clears
would be its own bug, which is why the badge is recomputed rather than
decremented.

### Offline: the cache existed, and the failure erased it

**The chat list was empty offline, and it was not a missing cache.** `ChatStore`
has held the threads all along and `ChatModel.conversations` is seeded from it,
so they draw before any request is made. What emptied the screen was the fetch
that followed — and it did not merely blank the list, it **wrote its empty answer
back to `ChatStore`**, so the threads were gone until the next successful load.
Being offline cost more than the network.

`ChatService.conversations()` opened `guard let me = await currentUserID() else
{ return [] }`. Offline that guard is what fires: `currentUserID()` awaits
`validAccessToken()`, the refresh cannot complete, and it answers nil. **A guard
against exactly this existed and could not see it** — it tested `lastError`, and
that return path set none:

    let chatFailed = await ChatService.shared.lastError != nil   // false
    if !fetched.isEmpty || !chatFailed { conversations = fetched; ChatStore.save(fetched) }

**Ninth instance of the same defect, and the first to destroy anything.** The
eight before it hid data or reported a failure as a success; this one overwrote
the copy that would have survived. `LikeService.admirers()` had the identical
opening and emptied the admirers banner the same way.

**The fix is the type, not another boolean.** Both return an optional now — nil
for *could not ask* — so the caller is `if let fetched { … }` and there is
nothing left to remember. A boolean in one file guarding an early return in
another is not a guard; it is a convention, and this is what it costs when it
lapses. Same treatment as `PhotoService.paths()` and `unreadByConversation()`,
which were already right.

Three things fell out of it, all about not asserting what was never asked:

- **`hasLoaded` moves only on a real answer.** It meant *a load finished*, which
  is why it was already wrong for notification routing.
- **The empty state has two sentences.** "No conversations yet" is a claim about
  an account; offline with no cache — a fresh install, a new phone — the app
  cannot make it. `couldNotReach` picks the other one.
- **No second banner while offline.** `AppShell`'s offline banner covers every
  tab, and the service's own message on that path is "You're not signed in" —
  true of the token it could not refresh, and nonsense to somebody on a train.

**Nothing about synchronisation changed.** The server is still the source of
truth, the cache is still a cache and is still replaced wholesale by every
successful fetch, and nothing is written offline. Only an *unsuccessful* fetch
stopped being mistaken for a successful empty one. Threads themselves were never
affected — `ConversationView.merge` unions the fetch onto what it holds, so an
empty answer there changes nothing.

## Known gaps

Real, deliberate, and unfinished as of 2026-08-05. Ordered by what would hurt
soonest. Delete an entry when it stops being true rather than letting the list
rot — a stale gap list is worse than none.

**Google OAuth verification is the next thing with a deadline.** The site now
carries what the submission needs — every scope named, a `#google-user-data`
section per scope with why nothing narrower will do, the Limited Use disclosure,
the retention rule and a support page — and the drafted justifications and video
shot list are in `web/README.md`. Outstanding: Search Console as a **Domain**
property signed in as an Owner of Cloud project `672788849005` — verifying as
the wrong account is the standard rejection and Google does not say so; the
consent screen at `console.cloud.google.com/auth/branding`; and an Unlisted
YouTube demo video. **The video is the hard part**: it must show the client ID,
and `ASWebAuthenticationSession` has no address bar, so it has to be shown
another way in the same recording. Until this is done every tester re-authorises
YouTube weekly.

**The consent screen's URLs must be the final ones**, `https://written-stl.com/en-us/`
and `.../en-us/privacy/`, matching `SignInView.swift` character for character —
not `/privacy`, which 301s. Google checks that the homepage link and the consent
screen link agree, and a redirect is not agreement.

**Google Calendar has never been run.** It is built and unexercised: nobody has
connected it, because the developer's own phone has a Google account. It needs a
device without one. Note the site now describes it to reviewers, so this is a
source documented ahead of ever having worked.

**Notifications are proven on sandbox and untested on production.** All three
events, the avatar and the attachment previews were confirmed on a real device
on 2026-08-05 — but every device token so far reads `sandbox`. A TestFlight
build mints a **production** token against a different host, and nothing has
exercised it. Build 19 is the first archive containing `NotificationService`
(18 predates the target and is the plain-banner version). Confirm a second
`device_tokens` row reading `production`, then send one message and check the
face still arrives. Same shape of mistake as testing HealthKit on a phone that
has already been asked.

**A notification tap opens the app wherever it left off.** The payload carries
`category` and `thread` and nothing reads them, so tapping a message notification
does not open that conversation. The most obviously missing half of the feature
once the banners themselves work.

**The site is live and one network cannot see it**, which is a measurement
problem rather than a gap — and it is the **network**, not the machine, so it
follows the wifi rather than the laptop. On `wusm-wifi.wucon.wustl.edu`
(nameservers `10.39.49.3` / `.34`) the domain resolves to `198.135.184.22`,
which is `sinkhole.paloaltonetworks.com`; on an ordinary connection it loads
normally. **The control that makes that a decision rather than a fault is that
`example.com` resolves correctly from the same resolver** — the DNS is working
and choosing this domain.

It worked for a day and then stopped, which is the signature of
**newly-registered-domain filtering**: Palo Alto categorises domains registered
in roughly the last 30 days, and its feed takes about a day to ingest a new one.
`written-stl.com` was registered 2026-08-04 and was still inside the registrar's
`addPeriod` when this was measured. Nothing about the domain, the deploy or the
DNS records is wrong, and it clears itself as the domain ages.

**So do not conclude anything about this domain from a sinkholed resolver**, and
do not go looking for a deployment fault when the symptom is "it was up
yesterday". Two ways round it: resolve over DoH
(`https://dns.google/resolve?name=written-stl.com&type=A`), then fetch with the
answer pinned —

    curl --resolve written-stl.com:443:104.21.7.174 https://written-stl.com/en-us/

That is how the deployment was confirmed on 2026-08-05. Another network is the
other way. The sinkhole intercepts DNS only; the TLS connection to Cloudflare is
untouched once the address is supplied.

**Cloudflare Web Analytics is switched on and the site's own CSP refuses it.**
Every HTML response to a browser User-Agent — and only to a browser, which is
why a plain `curl` does not show it — has a `static.cloudflareinsights.com`
beacon appended by the edge. `_headers` sets `script-src 'self'` and
`connect-src 'none'`, so the browser blocks it and the analytics record nothing.

The CSP is doing exactly its job, and that is the point: `_headers` says
`connect-src` "is the line that would have to change first if analytics were
ever added, which is exactly the friction wanted", and a dashboard toggle added
them without crossing it. So `web/en-us/cookies/` — a page a reviewer reads —
tells them nothing is fetched from anywhere else while the edge attempts it on
every load. **Turning Web Analytics off is the cheap resolution**; keeping it
means widening two CSP directives *and* rewriting the cookies and privacy pages
in the same commit, per the rule below. Check with:

    curl -s -A 'Mozilla/5.0 … Chrome/126' https://written-stl.com/en-us/ \
        | grep -c cloudflareinsights          # 0 once it is off

**The site is written from the app and goes stale silently.** It described a
one-sign-in-method app with no Google Calendar and no notifications for a day
after all three had shipped, and it promised, six times across three pages, an
in-app control for taking a single source back out — which has never existed.
Nothing catches this: a page cannot fail to compile. **Adding a source, a
sign-in method, or anything else that leaves the device means editing
`web/en-us/privacy/` in the same commit**, and `web/README.md` says so at the
top for the same reason.

  Rewritten 2026-08-05 to say what is true, and the two words it now uses
  exactly are worth keeping straight:

  - **Struck off** — the `BanList` editing pass. `markedRemoved` annotates
    `extra` with `removed_by_user=<stamp>` and **keeps the row**, deliberately,
    because the ontology stage needs "collected then struck off" to be a
    different fact from "never collected". So the site says never used, never
    shown, never counted — and does not say deleted, which would be false.
  - **Deleted** — only account deletion and the YouTube sweep, which are real
    deletes.

  The mandatory 7-day clause (*"must provide a way for a user to request that
  you delete stored data… within 7 calendar days"*) therefore attaches to
  **account deletion and written request**, which both exist, rather than to a
  per-source control that does not. Deletion is actually immediate — the cascade
  plus `delete-account` — so 7 days is a ceiling kept for the backups, which the
  policy now describes rather than waving at.

**Nothing here has reached a tester.** Build 15 is archived and predates all of
it. Every fix from 2026-08-04 — the empty source, the crop screen, the sign-in
overhaul, phone and Google auth — plus notifications from 08-05, is on `main`
and on nobody's phone.

**CAPTCHA is off for phone sign-in, deliberately**, and the SMS rate limit of
10/hour is what stands in for it. **Revisit both together**: raising the limit
for real signup volume removes the only thing bounding the cost.

**Identity linking is unbuilt.** Three sign-in methods mean one person can hold
three accounts, which for a dating app is a duplicate in the pool. Deferred
consciously for the beta; it wants deciding before launch.

**`hasExplored` is local only.** The two onboarding steps before it mirror
columns on `public.users`; this one lives in `UserDefaults`, so a reinstall walks
someone through the garden a second time. A column and a migration fixes it.

**The plant's position is unverified.** `(858, 1626)` at stage 2 is the check
that has caught every layout regression here, and CoreSimulator has been
unusable since it crashed on 2026-07-29 — several changes have shipped on
arithmetic alone since. Restart the simulator and re-run it.

**App Store privacy labels are not filled in.** The manifest declares eleven
data types and App Store Connect's own questionnaire is a separate answer that
still says nothing. **Fill it in from the manifest**, which is now the complete
list — it gained `PhoneNumber`, `PhotosorVideos` and `EmailsOrTextMessages` on
2026-08-05, and the way it had lost them is the thing to guard against: each
arrived with a feature written months after anybody last opened a plist. A
dating app not declaring photographs is the omission a reviewer finds first, and
it had been true since `0015`.

**The privacy policy is written and published** — `web/en-us/privacy/` — so this
no longer blocks external TestFlight or Google. The three answers that must
agree are the manifest, that page, and the questionnaire; a disagreement between
them is a routine rejection and none of the three checks the others.

**Account deletion has never been run end to end, and it is now the
load-bearing claim of the published privacy policy.** The site's answer to
Google's mandatory *"a way for a user to request that you delete stored data"*
is this button plus a written request — there is no per-source control — so a
deletion that silently half-works is a policy that is false. Test it before
submitting anything. Both halves exist and are deployed — the app deletes its own `public.users` row through RLS, which cascades
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
through `DistillViewModel.saveError`, drawn by the one `statusBanner` in
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

  **It was then written eleven more times, and it broke the whole Chat tab.**
  Every fetch in `ChatService` and `LikeService` guarded on the raw property, so
  on a cold launch each answered "not signed in" and returned `[]` — and an
  empty list is indistinguishable from an account with no threads, so the tab
  simply drew "No conversations yet" and no admirers, on every launch, until
  something else happened to reload it. It surfaced only because a tapped
  notification could not find its conversation, and two attempts at fixing
  *that* — a retry loop, then a fetch by id — each contained the same bug again.

  **`SupabaseAuth.currentUserID()` is the fix and the rule.** It awaits
  `validAccessToken()` and then reads the property, and it is what any code
  needing a user id before a request should call. The raw property is a cache;
  reaching for it is the mistake, not forgetting to await something near it.
- **Every `return false` on a push path must set `lastError` first**, or a dead
  session reports itself as a network problem and sends the user to check their
  signal.

And **a value that needs the server should fail loudly, while a value that
doesn't shouldn't wait** —
`setEducation` and `setOccupation` own no column, so they travel as ordinary
`user` records and apply locally at once. That asymmetry is the whole diagnosis:
when the two column-backed rows failed and the two record-backed ones didn't, the
refusal had to be on `rest/v1/users`.

**Photos are built and `0015` is applied** — this said "unapplied" while a
paragraph below said it "applied cleanly", which is the shape of rot this file's
own gap-list rule exists to prevent. Confirmed by a photograph reaching Supabase
on 2026-08-04. `PhotoService` uploads to a private `profile-photos` bucket at
`<user_id>/<position>.<ext>` — the position *is* the order somebody meant, so
re-picking slot 2 overwrites slot 2 rather than leaving a seventh photograph
behind — and `DiscoveryCardService` carries the paths onto the card the same way
it carries the name.

**The dashboard's grid saved nothing, and it took a database query to see
that.** `0015` applied cleanly, a photograph was added in Memories, and
`public.photos` came back empty. `RootView` uploaded on the photo page's Continue
button and **that was the only call site in the app** — the dashboard bound the
same `PhotoGrid` to the same array and no one ever sent it. So a picture added
there lived until the app was killed and had never left the phone.

Three things generalise, and the middle one is the reason this was invisible:

- **A page with no Continue button has to save on the way out.** `PhotoGrid`
  takes an optional `onEdit`, and which surface passes it *is* the difference
  between the two: onboarding waits for its button, because somebody arranging
  pictures may yet skip. The dashboard has no button, so the departure is the
  button — `DistillViewModel.stagePhoto` records and `flushPhotos` sends, fired
  from `AppShell` on leaving the tab, on the app going away, and before signing
  out. Saving on every edit was the first fix and it overshot: swapping one
  picture three times paid for three uploads. The staging map is keyed by
  position so the **last write to a slot wins**, and the intermediate pictures
  are never sent at all.

  **`.inactive` is what catches a force-quit**, not `.background`: raising the
  app switcher makes the app inactive *before* the swipe kills it. A background
  task assertion buys the flush ~30s rather than ~5. A crash or an instant kill
  can still lose a staged edit, and that is the accepted cost of batching.

  **The queue survives the app**, through `PendingPhotoStore`. It was
  memory-only, so a photograph added offline stayed in the grid looking saved,
  the retry fired only if the user left the tab again in the same launch, and a
  force-quit took it with nothing left to try from. Application Support rather
  than Caches, one directory per account through `AccountScope` — a queue
  flushed into the wrong account would upload somebody else's face.

  **The intent is the file name, not a manifest.** `3.jpg` is a pending upload
  for slot 3, `3.removed` a pending removal. A manifest beside the files is a
  second thing that can disagree with them, and a crash between writing the two
  leaves a queue naming a file that isn't there. A directory listing cannot
  disagree with itself.

  **Encoded at staging, not at send.** What lands on disk is exactly what will
  be uploaded, so a retry after a crash sends the same bytes rather than
  re-deriving them from a `UIImage` that died with the process. It also means
  staging takes a moment, which is why `flushPhotos` awaits the outstanding
  staging tasks *before* deciding it has nothing to do — a picture chosen and
  immediately walked away from would otherwise be missed by the very flush its
  own departure fired.

  Restored into the grid **before** the server's copy, since it is the newer
  intent. The launch retry is silent on an ordinary launch — a refusal about a
  photograph chosen in some earlier session explains nothing the user can act
  on — but **not on the launch after onboarding**, where the pictures were
  chosen seconds ago and a failure is worth saying. Cleared on sign-out with
  everything else: unsent work is not a cache, but sign-out flushes first, so
  this discards only what a failure left behind.

  **Onboarding goes through the same queue**, which is the whole of what used to
  be missing there: the photo page uploaded directly and persisted nothing, so
  onboarding on a bad connection lost somebody's photographs silently, in the
  one place a first-time user is most likely to meet it. It stages and `AppShell`
  sends. The staging is **awaited before the route changes** — it is a JPEG
  encode and a file write, not a round trip, and the alternative is a race the
  route wins about half the time, leaving the queue unread until the next launch.

  That also retired the read-once `PhotoService.lastError` reporter in
  `AppShell`. It existed because the photo page's fire-and-forget upload had no
  way to complain; nothing fires and forgets any more, and the flush reports its
  own failures.

  **The flush is driven by staged edits and never by the array's contents.** That
  is not a style preference — see the hydration note below. A grid that has not
  loaded yet is six empty slots, and anything reconciling the array against the
  server would read it as *delete everything*.

- **Onboarding numbered the slots wrong, and only a working grid could show
  it.** `PhotoEntryView` handed over `chosen` — `media.compactMap { $0 }` — and
  `PhotoService.upload` numbers what it is given by `enumerated()`, so boxes 0, 3
  and 5 were saved as 0, 1 and 2. The arrangement was destroyed at the first
  save. It survived because nothing ever drew the server's copy back; the moment
  hydration landed, the photographs returned packed at the top. **A compacted
  array is never the right thing to hand to something that assigns positions.**

- **The grid outlived the account.** `photos` is `@State` on `RootView` and
  nothing cleared it, so signing in as somebody else in the same launch showed
  them the previous account's photographs — and hydration could never correct it,
  because it only fills slots that are empty. Cleared in `onSignOut` *before*
  `SupabaseAuth.signOut()`, matching the rule the account-scoped stores follow.
  `pendingPhotos` needs no such clearing: it lives on `AppShell`'s `@StateObject`,
  which is torn down with the route.

- **A background assertion has to wrap the work, not the call.** It was taken in
  `AppShell` around `flushPhotos()`, and a flush already running from the tab
  change turned that call away at the re-entrancy guard — so the assertion
  covered a function that returned immediately while the real upload ran
  unprotected. It lives inside the flush now. Its expiration handler is not
  optional either: a background task that runs out with no handler takes the app
  down with it.

- **The grid never loaded, either.** `photos` is `@State` on `RootView`, six
  nils, and nothing read the account's own back — so the pictures were in the
  bucket, on the discovery card, and absent from the one screen their owner goes
  to look at them. `AppShell` now fills it from `PhotoService.slots()`, which
  keeps the position `paths()` throws away: somebody can have photographs in
  slots 0, 2 and 5, and packing them into 0, 1, 2 would silently rearrange a
  profile its owner laid out. Empty slots only, and never one with an edit
  waiting, or a photograph removed while its download was in flight comes back.
- **Every write is silent until somebody draws it.** `PhotoService.lastError` was
  recorded and never read — the same defect as `SyncService.lastError`, in a file
  written after that lesson was already in here. `upload(_:at:)` and `remove` now
  return the reason rather than only storing it, and the banner is the same one
  the biographics rows use (`saveError`, renamed from `biographicsError` because
  it now carries both).
- **Removal has two halves and only had one.** Setting a slot to nil cleared the
  array and left the object and its row in place, so a photograph taken down was
  still in the bucket and still on the discovery card. `remove` deletes the
  object *first* — a row pointing at a missing file draws a broken picture, while
  a file with no row is merely unreferenced — and reads the key back rather than
  rebuilding `<position>.jpg` from a convention.

The card is republished after either, since it carries the paths; a card still
naming a withdrawn photograph would leave the feed drawing a face its owner took
down.

**Saving a photograph is two writes, and they came apart silently.** `send`
uploaded the object, called `record` to write the `public.photos` row, and
**discarded its result** — then `upload` set `lastError = nil` on the very next
line, erasing the error `record` had just recorded, and returned success. So an
object that reached the bucket while its row failed was reported as saved,
twice over.

What followed was invisible and permanent. The grid draws from local state, so
it looked saved; `public.photos` stayed empty; and because
`DiscoveryCardService` asks `PhotoService.paths()` before publishing, and that
reads *the table*, it answered "no photographs" and `publish` declined by
design. That person had **no discovery card at all**, for good, with no error
anywhere. `record` returns `Bool` now and `send` fails on it — which is what
puts the photograph back in `PendingPhotoStore` to retry, the row write being an
upsert.

**`paths()` could not tell "there are none" from "I could not ask."** It
returned `[]` on a dropped request or an expired token, and the one place that
reads it treats an empty list as a *decision*. Any failure at that moment
silently un-listed somebody who had photographs. It returns `[String]?` now —
`nil` is "could not ask" — and checks the status code, which it never did.

That makes **four** instances of one defect in this codebase:
`SyncService.lastError`, `PhotoService.lastError`,
`DiscoveryCardService.lastError` and `record`'s discarded return. Always the
same shape — a call that can fail, a result nobody reads, and the symptom
surfacing somewhere else entirely.

**And the crop screen slid off the side of the phone for wide photographs.**
`CropView.imageLayer` sizes itself to *cover* the crop frame, so a landscape
picture is wider than the phone — covering a 400x500 frame with a 4:3 photo
takes 666x500. A `ZStack` takes the union of its children, and **`GeometryReader`
lays its content out at top-leading rather than centred**, so all of that extra
width hung off the right and everything centred inside centred on 333 instead of
220. Measured on a tester's screenshot: the frame's left edge at **133pt** where
a centred 400pt frame belongs at 20pt, its top at 228pt which is exactly right —
and 333 minus 200 is 133. The buttons went with it, leaving "Use photo" half off
the screen, so two testers could not upload at all.

It only ever happened to wide pictures, which is why it survived: a portrait
photo never exceeds the screen width. Fixed by pinning the stack to the
container it was handed — and not with `.clipped()`, because the backdrop and
the dimming layer deliberately `ignoresSafeArea` and clipping would cut them
back to bare edges.

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

**Every TestFlight upload needs `CURRENT_PROJECT_VERSION` bumped.** At 15, which
is archived but predates the discovery, crop and authentication work — uploading
it would give testers a build that fixes nothing they reported.
It appears **eight times** in `project.pbxproj` — Debug and Release for the app,
the share extension, the notification service extension and the UI tests — and
all eight have to move together. The app and **every** embedded extension sharing
a build number is a hard requirement of the upload, not a tidiness rule.

**That number grows with every target**, and it said six until
`NotificationService` was added. Count it rather than trusting this line:
`grep -c CURRENT_PROJECT_VERSION project.pbxproj`.

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
