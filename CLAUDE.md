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

## Known gaps

Real, deliberate, and unfinished as of 2026-07-28. Ordered by what would hurt
soonest. Delete an entry when it stops being true rather than letting the list
rot — a stale gap list is worse than none.

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

**Photos go nowhere.** `PhotoEntryView` picks, frames and displays correctly,
then `onContinue` drops the media. Needs migration `0007`: a Storage bucket with
RLS on `auth.uid()`, and a `photos` table for order, kind and the video crop
rects. Video crops are stored as unit rectangles rather than baked in, because
the file needs re-encoding for size before upload anyway — do both in one pass.

**Some things can be set but never changed.** The name is captured during
onboarding and has no edit path afterwards. This is the same shape of bug the
biographics rows had, where a row only rendered once it had a value, so nobody
could ever add one.

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

**Three credentials have been exposed in working sessions and should be
rotated.** None is in the repo; all three are in chat transcripts, which is a
place secrets get read long after anyone is thinking about them. The two from
2026-07-28 were **still live on 2026-07-29** — the personal access token was
checked and returned 200 — so this list has already outlived one round of good
intentions.

- **The `service_role` key** — pasted on 2026-07-29 to seed the six synthetic
  accounts, which genuinely needed it: `public.users.id` is a foreign key onto
  `auth.users(id)`, so a synthetic person has to be a real auth user first, and
  only `service_role` may create one. **This is the most dangerous of the three
  to leave alone.** It bypasses row-level security completely rather than
  defeating it indirectly — no token forging required, it simply is not subject
  to policy — so it reads and writes every row of every account. Rotate in
  Dashboard → Settings → API. Seeding needs it exactly once; there is no reason
  for it to survive the run.
- **The Supabase `jwt_secret`** — returned by `GET /v1/projects/<ref>/postgrest`
  alongside the field actually being read. This is the one that matters: it signs
  the project's JWTs, so anyone holding it can mint a token claiming any `sub` and
  **row-level security will honour it**. RLS is the entire authorisation layer, so
  the secret defeats it completely. Rotate in Dashboard → Settings → API → JWT
  Settings. It invalidates every session and regenerates the `anon` key, so
  `AppConfig.supabaseAnonKey` needs updating and the app rebuilding.
- **A personal access token** (`sbp_…`), pasted to configure the Supabase MCP
  server. Full Management API authority over the account — it can read the
  `service_role` key. Rotate at supabase.com/dashboard/account/tokens and re-add
  the MCP server with the new value.

**Every TestFlight upload needs `CURRENT_PROJECT_VERSION` bumped.** At 5 today.
