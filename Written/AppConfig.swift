import Foundation

/// Central configuration for Written's distillation sources.
enum AppConfig {

    // MARK: Spotify OAuth

    /// **Restored for the beta only.** Spotify was dropped when Postgres became
    /// the source of truth, and the reason has not gone away — see the note in
    /// CLAUDE.md. It is back so the data-collection beta has a second music
    /// source, and it comes out before the App Store build.
    ///
    /// Client ID from the Spotify Developer Dashboard
    /// (https://developer.spotify.com/dashboard → Create app).
    /// Add the exact redirect URI below to the app's Redirect URIs there,
    /// and enable the "iOS" platform with this app's bundle identifier.
    static let spotifyClientID = "3a0ed3c9d39c40c3bdc3c62b91f78e8b"

    static let spotifyRedirectScheme = "written"
    static let spotifyRedirectURI = "written://spotify-callback"

    /// Read-only scopes covering written_api.xlsx: top artists/tracks,
    /// recently played, followed artists, playlists.
    static let spotifyScope = "user-top-read user-read-recently-played user-follow-read playlist-read-private"

    // MARK: Supabase

    /// The project's REST and auth host.
    static let supabaseURL = URL(string: "https://fwnezkbesjoazlpaflbq.supabase.co")!

    /// The **anon** key, committed on purpose and by the same reasoning as the
    /// OAuth client IDs below: it is designed to ship inside clients, identifies
    /// the project rather than a person, and grants nothing on its own.
    ///
    /// What actually protects the data is **row-level security** — every table
    /// carries `auth.uid() = user_id`, so this key can only ever reach rows the
    /// signed-in user owns. That makes RLS load-bearing rather than defence in
    /// depth: a table with it switched off is readable in full by anyone holding
    /// this string. See `supabase/migrations/0001_initial.sql`.
    ///
    /// The `service_role` key bypasses all of that and must never appear here.
    /// The publishable key, which replaced the JWT `anon` key when the legacy
    /// keys were disabled on 2026-07-29.
    ///
    /// Committed on purpose, exactly as its predecessor was: it ships in the
    /// binary and row-level security is what protects the data. Its opposite
    /// number, `sb_secret_…`, must never appear here or anywhere else in this
    /// repo — the old `service_role` key had to be retired precisely because it
    /// was pasted into a working session.
    static let supabaseAnonKey = "sb_publishable_rKIU-q6beAiLawLkjEiMYA_vZNmC2aT"

    // MARK: Google / YouTube OAuth

    /// iOS OAuth client ID from Google Cloud Console
    /// (APIs & Services → Credentials → Create Credentials → OAuth client ID → iOS).
    /// Enable "YouTube Data API v3" for the project before creating the client.
    ///
    /// Replace the placeholder with your real client ID, e.g.
    /// "1234567890-abc123def456.apps.googleusercontent.com"
    static let googleClientID = "672788849005-kd5dkg6om726kf19gml7gn6qkikg13t4.apps.googleusercontent.com"

    /// Google iOS clients redirect to the reversed client ID as a custom URL scheme.
    /// "1234-abc.apps.googleusercontent.com" → "com.googleusercontent.apps.1234-abc"
    static var googleRedirectScheme: String {
        let parts = googleClientID.components(separatedBy: ".")
        return parts.reversed().joined(separator: ".")
    }

    static var googleRedirectURI: String {
        "\(googleRedirectScheme):/oauthredirect"
    }

    /// Read-only YouTube scope: subscriptions, liked videos, playlists.
    static let youtubeScope = "https://www.googleapis.com/auth/youtube.readonly"

    /// **Two narrow scopes rather than `calendar.readonly`, and that is the
    /// answer to a question the reviewer will ask.** Google's sensitive-scope
    /// verification requires a justification for each scope *and* an explanation
    /// of why a narrower one will not do — so asking for the two that name
    /// exactly what is read is worth more than the convenience of one broad one.
    ///
    /// The distiller needs the calendar list, to exclude generated and holiday
    /// calendars by name before reading anything, and the events themselves.
    /// Neither is restricted, so this stays a sensitive-scope review and no CASA
    /// assessment is triggered — unlike `fitness.*`, which is why Google health
    /// data was never a possibility here even before its API closed.
    static let googleCalendarScope = [
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
        "https://www.googleapis.com/auth/calendar.events.readonly",
    ].joined(separator: " ")

    // MARK: The private semantic vault (v0.3.1, Phase 1)

    /// **Which sources dual-write to the vault. Apple Music, and nothing else.**
    ///
    /// Phase 1 of the v0.3.1 integration writes each distillation twice: the
    /// legacy path through `SyncService`, which the product depends on, and the
    /// typed envelope through `SemanticIngestionService`, which nothing reads
    /// yet. A source absent from this set does nothing at all — no queue, no
    /// request, no cost.
    ///
    /// **A set rather than a switch, because turning it on everywhere at once
    /// throws away the only thing shadow running is for.** Apple Music is the
    /// right first source: it is the largest real library (~2,540 rows, six
    /// batches), it exercises batching and the retry queue properly, and its
    /// legacy row count is a number to compare the receipt against. A source
    /// whose rows disagree between the two paths is exactly what this phase
    /// exists to find, and finding it in one source is a diagnosis while
    /// finding it in nine is a shrug.
    ///
    /// Note `music_library` is deliberately *not* here even though it emits the
    /// same `library_song` rows: on a subscriber's phone both sources return
    /// the same library, and the comparison wants one of them, not the
    /// doubling that cost `MusicHighlights.deduplicatedSongs` a rewrite.
    ///
    /// The endpoint itself is proven — a real device envelope round-tripped on
    /// 2026-08-11, and a second identical one stored nothing.
    static let semanticIngestionSources: Set<String> = ["apple_music"]

    /// Whether the vault path does anything at all this build.
    static var semanticIngestionEnabled: Bool { !semanticIngestionSources.isEmpty }

    /// `aws/ingestion` — API Gateway in front of the Lambda. Not a secret: it
    /// authenticates every request against the caller's Supabase access token,
    /// so knowing the address buys nothing, exactly as the OAuth client ids
    /// below are committed deliberately.
    static let semanticIngestionURL = URL(
        string: "https://c2u0avzqti.execute-api.us-east-1.amazonaws.com/v1/ingest"
    )

    /// Envelopes per request.
    ///
    /// **Must not exceed the endpoint's own ceiling**, which is 500: it refuses
    /// a larger batch outright rather than truncating it. One real Apple Music
    /// library is about 2,540 rows, so a full distillation is several requests
    /// — which is wanted anyway, since API Gateway caps a request at 10 MB.
    static let semanticIngestionBatchSize = 500

    // MARK: Distillation limits (MVP guardrails so a distill finishes quickly)

    /// Maximum pages fetched per paginated endpoint (50 items/page for YouTube,
    /// 100 items/page for most Apple Music endpoints).
    static let maxPagesPerEndpoint = 10

    /// Maximum playlists whose individual tracks are expanded.
    static let maxPlaylistsExpanded = 15

    /// Maximum library songs checked for a like/dislike rating.
    ///
    /// The only term in a distillation that scaled with the size of someone's
    /// library: ratings are asked for a hundred ids at a time, so an unbounded
    /// library meant an unbounded number of round trips, and Apple Music took
    /// far longer to connect than YouTube or Health for no visible reason. The
    /// songs are read most-recent-first, and ratings are a weak signal next to
    /// heavy rotation and play counts, so the tail is worth little.
    static let maxSongsRated = 1_000

    /// Ceiling on songs read from the *device* library — see
    /// `MusicLibraryDistiller`, which is what covers people with no Apple Music
    /// subscription. Higher than `maxSongsRated` because this costs no round
    /// trips at all: it is a local query, not a thousand ids over the network.
    static let maxLibrarySongs = 3_000

    /// Ceiling on Spotify tracks looked up in Apple Music's catalog for a
    /// composer — see `ComposerService`.
    ///
    /// **The same hazard `maxSongsRated` describes, one service further out.**
    /// Spotify returns no composer, so a classical listener's whole library is
    /// eligible, and without a ceiling this would scale with the size of it.
    /// Two things already bound it before this does: the lookup is batched a
    /// hundred ISRCs to a request, and it only runs for people whose own artist
    /// rows say they listen to classical at all — which is nobody, for most
    /// libraries. So this is the backstop rather than the mechanism, and it is
    /// set where 500 tracks costs five requests.
    static let maxComposerLookups = 500

    // MARK: Apple Calendar

    /// How far back events are read. Five years.
    ///
    /// It was a year, matching the Health windows, on the reasoning that a year
    /// covers the seasonal shape of a life — a festival every August, a season
    /// ticket. True as far as it goes, and it was measured wrong in the other
    /// direction: the thing this source exists to catch is the trip somebody
    /// booked, and those are exactly the entries that sit outside a year.
    static let calendarLookbackDays = 1825

    /// And how far forward, now the same. It was 180 days on the argument that a
    /// booked gig sits weeks out and repeating entries scheduled years ahead say
    /// nothing about the next few months.
    ///
    /// **A flight to Los Angeles is what disproved it.** It was in the calendar,
    /// it was the strongest single row in the whole distillation — booked, paid
    /// for, a place and a date — and 180 days is precisely the window that
    /// excludes the holiday somebody planned in advance while including the
    /// dentist. A repeating entry is a solved problem: `record(for:)` marks it
    /// `recurring=1` and the fetch keeps one occurrence per identifier.
    static let calendarLookaheadDays = 1825

    /// Ceiling on events kept, so a shared work calendar with a decade of
    /// meetings can't turn one distillation into a hundred thousand rows.
    ///
    /// Doubled with the windows, which grew tenfold — but the number matters far
    /// less than **which** events survive it. See `CalendarDistiller.events`:
    /// the fetch is chunked by year and the chunks are walked outward from
    /// today, so a cap reached in a decade of meetings costs the furthest year
    /// rather than the next one.
    static let maxCalendarEvents = 6_000

    // MARK: Apple Health

    /// How far back HealthKit is read. A year covers seasonal habits — someone
    /// who only skis, someone who only swims in summer — without turning the
    /// distill into a decade-long export.
    static let healthWorkoutLookbackDays = 365

    /// How far back steps, active energy and exercise minutes are read.
    ///
    /// Far shorter than the workout window, and that gap is deliberate — it is
    /// the difference between a distill that takes seconds and one that looks
    /// hung. Workouts are sparse; quantity samples are not. An Apple Watch
    /// writes active energy every few minutes, so a year is hundreds of
    /// thousands of samples per type, and `HKStatisticsCollectionQuery` scans
    /// every one of them before it can bucket anything.
    ///
    /// Back to a year, deliberately. This was cut to thirty days while chasing a
    /// distillation that appeared to hang — wrongly, as it turned out: the hang
    /// was the authorization request never returning, and no query had run at
    /// all. The reach is worth having, so it is restored.
    ///
    /// It stays a separate constant rather than folding back into one window,
    /// because the underlying asymmetry is still true — workouts are sparse and
    /// quantity samples are dense — and this is the dial to turn first if a
    /// distillation ever *is* slow.
    static let healthActivityLookbackDays = 365

    /// Steps in an hour before it counts as "up and about". A three-step trip to
    /// the bathroom at 4am is not getting up, and without a floor it would be
    /// recorded as the day's wake time.
    static let wakeStepThreshold = 100

    /// Where one day ends and the next begins, for the purpose of "when did they
    /// get up". Not midnight: a night owl's 1am walk belongs to the evening
    /// before, and dated by the calendar it would make them the earliest riser
    /// on record.
    static let dayBoundaryHour = 3

    /// Ceiling on individual workouts kept. Beyond this the daily activity rows
    /// carry the shape of the habit anyway, and an athlete with thousands of
    /// sessions shouldn't make the distill crawl.
    static let maxWorkouts = 400

    /// Shows and episodes kept from Apple Podcasts.
    ///
    /// Generous on shows and tighter on episodes, because they answer different
    /// questions. The *show* is the taste and there are only ever so many of
    /// them; the *episodes* are instances of it, and past a point another fifty
    /// of the same podcast tell the ontology stage nothing it did not already
    /// have from the first ten. Same argument as `maxSongsRated`.
    static let maxPodcastShows = 200
    static let maxPodcastEpisodes = 500
}
