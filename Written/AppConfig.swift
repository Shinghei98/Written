import Foundation

/// Central configuration for Written's distillation sources.
enum AppConfig {

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
    static let supabaseAnonKey = """
        eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9\
        .eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZ3bmV6a2Jlc2pvYXpscGFmbGJxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODUyMDQwNDUsImV4cCI6MjEwMDc4MDA0NX0\
        .ZDITVhCgRMJvBqlkVeViHS6d12yltY63i9h3JcXwoGo
        """

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
}
