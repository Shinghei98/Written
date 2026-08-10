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
actually ships** — three of the sources below are held back for the App Store
build, one is impossible, and one is unresolved.

- **YouTube** (`YouTubeDistiller`) — **ARCHIVED.** Subscriptions, liked videos,
  playlists and playlist contents. Watch history is **not** reachable: the API
  does not expose it, and Takeout/Data Portability is EU-only. Why it is held
  back is in the YouTube section below.

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

- **Spotify** — **ARCHIVED, and removal was a condition of shipping.** The
  reasons are not the ones this entry gave for a year, which is what reading the
  clauses in full rather than a summary of them corrected:

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
  archived YouTube. `purgeArchivedSources` exists because rows already existed,
  and **lifting the source needs it suspended too** — otherwise it deletes the
  rows locally and on the server the moment they are distilled.

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

- **Google Calendar** (`GoogleCalendarDistiller`) — **ARCHIVED**, for the reason
  YouTube is: the consent screen is in Testing, so a reviewer's account gets a
  403 *after* a successful login. Nobody has ever connected it.

When it returns, its condition is the whole design: **offered only where the
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
(`developers.google.com/youtube/terms/derived-metrics-policy`), which licenses
*"descriptive sub-genres or tags"* that are *"additive and distinct from
YouTube's video categories"* — applied for on the same form, prospectively, so do
not apply while running the unlicensed version of the thing being applied for.
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
    **HealthKit rows travel now, except one.** They used to be derived and
    discarded — which produced an export with nothing in it and figures nobody
    could check — and the reason given was volume, which was never there: the
    distiller sums samples into day and hour buckets *before* making a record
    (`activity_hour` is 24 rows for the whole window, not 8,760), so a year is
    about 400–700 rows against 2,540 from one real Apple Music library.

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

**`0042` and `0043` ship no product behaviour.** Phase 0 installs the schema and
proves it upgrades cleanly. `004`–`006` become `0045`–`0047`, and the bridge,
projection and cutover migrations `0048`–`0050` are app-specific. Nothing is
read by Swift until Phase 3 at the earliest, and §12's KMS design is a
prerequisite of Phase 1 rather than a detail of it.

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

### Memories is the ontology's surface

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
  edit rather than a rewrite. Side effect: `recordSources` derives from
  `sources`, so `Modality.owning(source:)` answers nil for an archived source
  and its rows belong to no branch — harmless with no rows, which is why
  Spotify needed `purgeArchivedSources` and Google Calendar did not.
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
- **The plant's position is unverified.** `(858, 1626)` at stage 2 is the check
  that has caught every layout regression here, and CoreSimulator has been
  unusable since 2026-07-29 — several changes have shipped on arithmetic alone.
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
- **`health_sports` is empty and it is not known whether that is right.** 0 rows
  against 1 in `health_signals`. The early return that made this ambiguous is
  gone, so from the next distillation an empty table means the device genuinely
  derived no sports. Settle it by checking whether Health has workouts at all.
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
