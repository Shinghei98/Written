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

## Supported apps and what each yields

Scope comes from `written_api.xlsx` (the source of truth for what each platform
exposes; consult it before adding a source). Implemented today:

- **YouTube** (`YouTubeDistiller`) — subscriptions, liked videos, playlists and
  playlist contents. Watch history is **not** reachable: API doesn't expose it,
  and Takeout/Data Portability is EU-only. Don't plan around it for US users.
- **Apple Music** (`AppleMusicDistiller`) — library songs/albums/artists/music
  videos, playlists + contents, recently added, recently played, heavy rotation,
  personalized recommendations, like/dislike ratings.
- **Spotify was dropped** and should not be added back without a reason that
  answers both of these. Its Developer Terms forbid storing Spotify Content in a
  third-party database, so once Postgres became the source of truth it was the
  one source that could never be restored to a new device. And it could never
  have left development mode anyway: five test users, the developer must hold
  Premium, and extended quota needs 250,000 monthly active users — closed to
  individuals since May 2025. **Apple Music is the music source the product
  depends on.**
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
device build fails to read Health with no obvious cause.

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

## The two halves of the app

**Onboarding is a line; regular use is a tab bar.** They are different products
wearing one binary, and most of the layout rules below only make sense once that
is clear.

Onboarding runs sign in → name → photos → grow the plant → "People you will
see", and ends the moment **Explore** is tapped there. Through all of it the tab
bar is absent: a bar would offer four exits from a sequence whose whole point is
that it has one. The garden therefore keeps an arrow at its foot and a pull-up
gesture, because with no bar it has to carry the way onward itself.

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

**Sync failures are invisible by design, and that has already cost time.**
`SyncService.lastError` is recorded and never displayed. Deliberate — a failed
upload must not interrupt the garden — but the next silent failure will look
exactly like the last one: a table emptier than expected with nothing to say why.

That silence is now the *only* consequence of a failed write, which is the
deliberate trade: **Postgres is the record, so nothing is shown that the server
did not accept.** The biographics rows used to apply locally and push in a
detached task, so a rejected write left the device displaying an age or a gender
the server had never heard of — true until the next restore quietly replaced it.
`pushUserObject` returns whether the row landed, and `setBirthday`, `setGender`
and `setPlace` write the local record only if it did. A failure therefore looks
like the edit not happening, with no message; that is the cost of never showing
something untrue, and it is the side chosen on purpose.

**Photos go nowhere.** `PhotoEntryView` picks, frames and displays correctly,
then `onContinue` drops the media. Needs migration `0007`: a Storage bucket with
RLS on `auth.uid()`, and a `photos` table for order, kind and the video crop
rects. Video crops are stored as unit rectangles rather than baked in, because
the file needs re-encoding for size before upload anyway — do both in one pass.

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
subject to no row-level security whatsoever. `tools/seed_synthetic.py` needs one;
it reads from the environment and has no default, and that is the pattern for
anything like it.

**Every TestFlight upload needs `CURRENT_PROJECT_VERSION` bumped.** At 5 today.
