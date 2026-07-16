import Foundation

/// Central configuration for Written's distillation sources.
enum AppConfig {

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

    // MARK: Spotify OAuth

    /// Client ID from the Spotify Developer Dashboard
    /// (https://developer.spotify.com/dashboard → Create app).
    /// Add the exact redirect URI below to the app's Redirect URIs there,
    /// and enable the "iOS" platform with this app's bundle identifier.
    static let spotifyClientID = "YOUR_SPOTIFY_CLIENT_ID"

    static let spotifyRedirectScheme = "written"
    static let spotifyRedirectURI = "written://spotify-callback"

    /// Read-only scopes covering written_api.xlsx: top artists/tracks,
    /// recently played, followed artists, playlists.
    static let spotifyScope = "user-top-read user-read-recently-played user-follow-read playlist-read-private"

    // MARK: Distillation limits (MVP guardrails so a distill finishes quickly)

    /// Maximum pages fetched per paginated endpoint (50 items/page for YouTube,
    /// 100 items/page for most Apple Music endpoints).
    static let maxPagesPerEndpoint = 10

    /// Maximum playlists whose individual tracks are expanded.
    static let maxPlaylistsExpanded = 15
}
