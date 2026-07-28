# Written — MVP

Written is a dating platform that builds profiles by **distillation**: extracting a
user's digital footprint from the apps on their phone, mapping it to ontologies and
an embedding space, and using it downstream for **dynamic prompting** (bios that
adapt to whoever is reading them).

This MVP is a single-page iPhone app that:

1. Distills **YouTube** — subscriptions, liked videos, playlists + playlist contents
   (per `written_api.xlsx`), via one-tap Google OAuth.
2. Distills **Apple Music** — library songs/albums/artists/music videos, playlists +
   contents, recently added, recently played, heavy rotation, personalized
   recommendations, and like/dislike ratings, via MusicKit (one-tap system
   permission, no login).
3. Distills **Apple Health** — workouts and daily activity, reduced on the
   device to a chronotype, sport levels, an hourly profile and a step average.
   The raw samples are discarded and never uploaded.
4. Exports everything as a single normalized **CSV** through the in-app
   "Download CSV" button (system Files save sheet).

## Requirements

- Xcode 16+ (the project uses the synchronized-folder project format)
- iOS 16.0+ deployment target, iPhone
- An Apple Developer Program membership (needed for MusicKit)
- A physical iPhone signed into Apple Music is strongly recommended —
  the simulator has no Apple Music account, and Google OAuth flows are
  smoothest on a device where Safari is already signed in.

## One-time setup

### 1. Signing & bundle ID

Open `Written.xcodeproj`, select the **Written** target → *Signing & Capabilities*:

- Pick your **Team**.
- Change `PRODUCT_BUNDLE_IDENTIFIER` (`com.written.datingapp`) if you want your own.

### 2. Apple Music (MusicKit)

MusicKit's automatic developer token requires the App ID to have the MusicKit
service enabled:

1. Go to [Apple Developer → Identifiers](https://developer.apple.com/account/resources/identifiers/list).
2. Select (or register) the app's App ID (the bundle identifier from step 1).
3. Under **App Services**, enable **MusicKit**. Save.

No key file or token code is needed — MusicKit mints developer/user tokens
automatically at runtime. The `NSAppleMusicUsageDescription` permission string is
already configured in the target's build settings.

### 3. Apple Health (HealthKit)

Reads workouts and daily activity. Like MusicKit, the capability is granted by
the App ID, not by code:

1. Go to [Apple Developer → Identifiers](https://developer.apple.com/account/resources/identifiers/list).
2. Select the app's App ID.
3. Under **Capabilities**, enable **HealthKit**. Save.

`Written.entitlements` already declares `com.apple.developer.healthkit`, and
`NSHealthShareUsageDescription` is set in the target's build settings.

**The entitlement is silently dropped when no Team is set.** Xcode filters
capability-gated entitlements it can't back with a provisioning profile, so the
built `.xcent` comes out empty and a *device* build cannot read Health. The
simulator is more forgiving — the permission sheet appears and the API works
without a team — so simulator testing is possible before the portal side is
done. Check with:

```
codesign -d --entitlements - /path/to/Written.app   # should list healthkit
```

The simulator starts with an empty Health database. Add samples in the
simulator's **Health** app (Browse → a category → Add Data) or a workout will
never appear, and Written will report the distillation as empty.

### 4. YouTube (Google OAuth)

1. In [Google Cloud Console](https://console.cloud.google.com/), create a project
   and enable **YouTube Data API v3** (*APIs & Services → Library*).
2. Configure the OAuth consent screen (External is fine; add your test Google
   accounts as **Test users** while the app is unverified).
3. *APIs & Services → Credentials → Create Credentials → OAuth client ID* →
   **iOS** → enter the app's bundle identifier. Copy the client ID.
4. Paste it into `Written/AppConfig.swift`:

   ```swift
   static let googleClientID = "1234567890-abc...xyz.apps.googleusercontent.com"
   ```

That's all — the redirect scheme is derived automatically from the client ID, and
the app uses `ASWebAuthenticationSession`, which needs no URL-scheme entry in
Info.plist and no Google SDK dependency.

### 5. Spotify — removed, and why it should stay removed

Spotify was a source and no longer is. Two independent reasons, either of which
is sufficient:

**Their terms.** Spotify's Developer Terms forbid storing Spotify Content in a
third-party database. Once Postgres became the source of truth, Spotify was the
only source that could never be restored to a new device — a user who reinstalled
would silently lose it, which is worse than not offering it.

**Their quota.** Development mode allows **five** test users and requires the
developer to hold Premium (both since 9 March 2026, down from 25 and from no
subscription requirement). Extended quota has required, since March 2025, a
registered business, **250,000 monthly active users**, availability in key
markets and an already-launched service — and since 15 May 2025 Spotify accepts
no applications from individuals at all. It is a wall rather than a queue: you
need a quarter of a million users before you may use Spotify, and Spotify cannot
help you reach them.

**Apple Music is the music source the product depends on** — MusicKit has no cap,
no allowlist and no application.

### 6. TestFlight (internal testing)

Steps 1–5 get the app onto *your* phone. This gets it onto other people's.

1. **Check the membership is active.** A new enrolment can sit in "processing"
   for 24–48h, and no identifier can be created until it clears. If
   [developer.apple.com/account](https://developer.apple.com/account) shows no
   *Identifiers* section, wait — everything below blocks on it.
2. **Register the App ID** with **HealthKit** and **MusicKit** enabled (§2–§3),
   then set the **Team** on the target so the entitlement survives packaging.
3. **App Store Connect → Apps → +** — new iOS app on that bundle ID, with a name,
   primary language and any unique SKU.
4. **Allowlist every tester before inviting them** — Google Cloud → OAuth consent
   screen → *Test users*. Google
   apps are unverified, so an account that isn't listed gets a **403 after a
   successful login**, which reads as a bug in Written rather than a missing
   invitation.
5. **Add testers** under *Users and Access*, then *TestFlight → Internal Testing*.
   Up to 100, and internal builds skip Beta App Review entirely.
6. **Archive**: destination *Any iOS Device* → *Product → Archive*, with the
   scheme's Archive action on **Release** so the `#if DEBUG` launch flags, the
   stage stepper and the debug sign-out button are compiled out.
7. **Validate App** in the Organizer before distributing — it catches icon and
   privacy-manifest problems locally rather than by email an hour later.
8. **Distribute App → TestFlight Internal Only**. Processing takes ~5–15 minutes.

Before uploading, run the entitlement check from §3 on the archived app — it must
list `com.apple.developer.healthkit`. An empty dictionary means the team or the
App ID capability is missing, and Health will fail on device with no error shown.

**Put this in the build's "What to Test" notes**, because neither is discoverable:

> The verification code isn't checked yet — no text is sent, so type any six
> digits. Send me your Google account email first, or that
> connections will fail with a permissions error.

Internal testing needs no privacy policy URL. **External testing does**, and a
HealthKit app cannot pass Beta App Review without one.

## How the one-button experience works

- **Apple Music**: tap *Distill* → the iOS media permission dialog appears once →
  MusicKit fetches everything using the device's Apple Music account. Zero typing,
  and later distills are zero-tap.
- **YouTube**: tap *Distill* → the system Google sheet appears; because it shares
  Safari's cookies, an already-signed-in user just taps their account and *Allow*.
  The refresh token is stored in the Keychain, so later distills are zero-tap.

## CSV schema

`source,data_type,item_id,name,creator,detail,extra,collected_at`

| column | meaning |
|---|---|
| `source` | `youtube`, `apple_music`, `health`, `location`, or `user` |
| `data_type` | YouTube: `subscription`, `liked_video`, `playlist`, `playlist_item` · Apple Music: `library_song`, `library_album`, `library_artist`, `library_music_video`, `library_playlist`, `playlist_item`, `recently_added`, `recently_played`, `heavy_rotation`, `recommendation`, `rating` · Health: `age`, `biological_sex` only — the raw `workout`, `activity_day` and `activity_hour` rows are derived from and then discarded |
| `item_id` | platform-native id of the item |
| `name` | title of the video/song/album/channel/... |
| `creator` | channel / artist / curator |
| `detail` | context: album, parent playlist, recommendation shelf, description snippet, liked/disliked |
| `extra` | `key=value;key=value` extras: genres, dates, play counts, item counts |
| `collected_at` | ISO-8601 timestamp of distillation |

## Code map

```
Written/
├── WrittenApp.swift              # app entry point
├── AppConfig.swift               # Google client ID + distillation limits
├── Models/DistilledRecord.swift  # unified record schema + source status
├── Services/
│   ├── OAuthPKCEService.swift    # ASWebAuthenticationSession + PKCE (Google), Keychain refresh
│   ├── KeychainStore.swift
│   ├── YouTubeDistiller.swift    # YouTube Data API v3 fetchers
│   ├── AppleMusicDistiller.swift # MusicKit / Apple Music API fetchers
│   └── CSVExporter.swift         # RFC 4180 CSV + FileDocument wrapper
├── ViewModels/DistillViewModel.swift
└── Views/ContentView.swift       # the single MVP page
```

## MVP guardrails & known limits

- Pagination is capped (`AppConfig.maxPagesPerEndpoint`, default 10 pages per
  endpoint; 15 playlists expanded) so a distill finishes in seconds. Raise the caps
  for power users.
- Apple Music ratings can only be fetched by id, so the app checks ratings for
  library songs in batches; only songs the user actually rated come back.
- YouTube API quota: a full distill costs roughly 1 quota unit per page; the
  default free quota (10,000 units/day) is plenty for MVP testing.
- While your Google OAuth consent screen is in *Testing* mode, only listed test
  users can sign in; Google verification is needed before public launch since
  `youtube.readonly` is a sensitive scope.
- Everything stays on-device until the user explicitly exports the CSV.
