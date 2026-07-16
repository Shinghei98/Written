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
| Spotify | Spotify OAuth (PKCE, same service) | Same shape as Google. |
| Apple Music | MusicKit | One system permission dialog, no login at all — uses the device's Apple Music account. |

## Supported apps and what each yields

Scope comes from `written_api.xlsx` (the source of truth for what each platform
exposes; consult it before adding a source). Implemented today:

- **YouTube** (`YouTubeDistiller`) — subscriptions, liked videos, playlists and
  playlist contents. Watch history is **not** reachable: API doesn't expose it,
  and Takeout/Data Portability is EU-only. Don't plan around it for US users.
- **Apple Music** (`AppleMusicDistiller`) — library songs/albums/artists/music
  videos, playlists + contents, recently added, recently played, heavy rotation,
  personalized recommendations, like/dislike ratings.
- **Spotify** (`SpotifyDistiller`) — top artists and tracks, recently played,
  followed artists, playlists + contents.

Testability differs and this trips people up: **YouTube and Spotify work in the
simulator** (they authenticate against a web account inside a browser sheet).
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
- Data stays on-device until the user explicitly exports.
- Exports are git-ignored (`written-distillation-*.csv`) — they are personal
  data and must never enter history.

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
users on the consent screen), Spotify dashboard (redirect URI
`written://spotify-callback`, User Management for testers), Apple Developer
(MusicKit on the App ID) — is documented step-by-step in `README.md`. Both
Google and Spotify gate unverified apps to an explicit tester allowlist; a 403
after a successful login almost always means the signed-in account isn't on it.

## Conventions

- SwiftUI + async/await, MVVM: `Models/`, `Services/`, `ViewModels/`, `Views/`.
- Xcode 16+ synchronized-folder project — new files under `Written/` are picked
  up automatically, no pbxproj surgery.
- New OAuth sources: add an `OAuthProvider` case rather than writing another
  auth service; `OAuthPKCEService` is provider-parameterized.
- Pagination is capped by `AppConfig.maxPagesPerEndpoint` /
  `maxPlaylistsExpanded` so a distill finishes in seconds. A per-item fetch that
  can't be capped is a red flag.
- Per-source failures are surfaced in that source's card (`SourceStatus.failed`)
  and never abort the other sources.
