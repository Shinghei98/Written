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
3. Distills **Spotify** — top artists and tracks, recently played tracks,
   followed artists, playlists + contents, via one-tap Spotify OAuth (PKCE).
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

### 3. YouTube (Google OAuth)

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

### 4. Spotify

1. In the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard),
   **Create app**.
2. Add `written://spotify-callback` under **Redirect URIs**, and under
   **Which API/SDKs are you planning to use?** check *iOS* (enter the app's
   bundle identifier).
3. Copy the **Client ID** into `Written/AppConfig.swift`:

   ```swift
   static let spotifyClientID = "your32charclientid"
   ```

While the Spotify app is in *Development mode*, add your test accounts under
**User Management** (up to 25 users); extended quota needs Spotify review.

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
| `source` | `youtube`, `apple_music`, or `spotify` |
| `data_type` | YouTube: `subscription`, `liked_video`, `playlist`, `playlist_item` · Apple Music: `library_song`, `library_album`, `library_artist`, `library_music_video`, `library_playlist`, `playlist_item`, `recently_added`, `recently_played`, `heavy_rotation`, `recommendation`, `rating` · Spotify: `top_artist`, `top_track`, `recently_played`, `followed_artist`, `playlist`, `playlist_item` |
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
│   ├── OAuthPKCEService.swift    # ASWebAuthenticationSession + PKCE (Google & Spotify), Keychain refresh
│   ├── KeychainStore.swift
│   ├── YouTubeDistiller.swift    # YouTube Data API v3 fetchers
│   ├── AppleMusicDistiller.swift # MusicKit / Apple Music API fetchers
│   ├── SpotifyDistiller.swift    # Spotify Web API fetchers
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
