import AuthenticationServices
import CryptoKit
import Foundation

/// Describes an OAuth 2.0 provider that supports the authorization-code + PKCE
/// flow for native apps (no client secret).
///
/// Parameterised rather than hard-coded to Google, because a second provider is
/// expected — this carried Spotify until that source was dropped. Add a `static
/// var` here rather than another auth service.
struct OAuthProvider {
    let name: String
    let authorizationURL: String
    let tokenURL: String
    let clientID: String
    let redirectScheme: String
    let redirectURI: String
    let scope: String
    /// Provider-specific additions to the authorization request
    /// (e.g. Google's access_type=offline to get a refresh token).
    let extraAuthParameters: [String: String]
    /// Where the developer pastes the client ID, for the error message.
    let configHint: String
    /// Whether a refresh token from this provider is worth keeping.
    ///
    /// True for the data sources, whose whole point is distilling again later
    /// without asking. **False for signing in**, where the refresh token that
    /// matters is Supabase's, not Google's — and where saving one would file it
    /// under `AccountScope.current`, which is still `local` because the account
    /// being signed into does not exist yet. That entry would then belong to
    /// nobody and outlive the sign-in.
    var persistsRefreshToken: Bool = true

    /// Whether `scope` must be repeated on the refresh request.
    ///
    /// **Microsoft requires it and Google does not, which is why this only
    /// surfaced on the fourth OAuth source.** RFC 6749 §6 permits `scope` on a
    /// refresh and Google simply infers the original grant when it is absent —
    /// so three providers worked for a year with it omitted. Microsoft's
    /// personal-account endpoint instead mints a token that is not valid for
    /// the resource, and Graph answers **401 after a completely successful
    /// sign-in**: the consent screen is approved, the token exchange returns
    /// 200, and the first API call is refused. Nothing in that sequence points
    /// at the refresh.
    ///
    /// Kept as a per-provider flag rather than sent to everyone, because the
    /// three that work today work without it and a token path is not somewhere
    /// to find out whether a change was harmless.
    var sendsScopeOnRefresh: Bool = false

    /// Where to tell the provider the grant is over, if it offers such a place.
    ///
    /// **Forgetting a token is not revoking it**, and the difference is the
    /// whole of `revoke()`. Deleting the Keychain entry stops *this app* using
    /// the grant; the grant itself carries on existing in the user's Google
    /// account until somebody says otherwise. YouTube's Developer Policies
    /// III.D.2.c.1 gives 7 calendar days to delete Authorized Data when a user
    /// revokes **through the client**, which presupposes that revoking through
    /// the client revokes something.
    var revocationURL: String? = nil

    var isConfigured: Bool { !clientID.hasPrefix("YOUR_") }

    static var google: OAuthProvider {
        OAuthProvider(
            name: "Google",
            authorizationURL: "https://accounts.google.com/o/oauth2/v2/auth",
            tokenURL: "https://oauth2.googleapis.com/token",
            clientID: AppConfig.googleClientID,
            redirectScheme: AppConfig.googleRedirectScheme,
            redirectURI: AppConfig.googleRedirectURI,
            scope: AppConfig.youtubeScope,
            extraAuthParameters: ["access_type": "offline", "prompt": "consent"],
            configHint: "AppConfig.googleClientID",
            revocationURL: "https://oauth2.googleapis.com/revoke"
        )
    }

    /// The same Google client again, asking for somebody's diary.
    ///
    /// **A distinct `name`, and that is load-bearing.** `refreshTokenKey` is
    /// derived from it — `AccountScope.key("\(name.lowercased())_refresh_token")`
    /// — so a provider called "Google" here would share YouTube's Keychain entry
    /// and the second source connected would overwrite the first's refresh
    /// token with one carrying the wrong scopes. YouTube would then start
    /// asking for consent again with nothing to say why.
    ///
    /// `googleSignIn` gets away with the collision only because it never saves
    /// one; see `persistsRefreshToken` there.
    static var googleCalendar: OAuthProvider {
        OAuthProvider(
            name: "Google Calendar",
            authorizationURL: "https://accounts.google.com/o/oauth2/v2/auth",
            tokenURL: "https://oauth2.googleapis.com/token",
            clientID: AppConfig.googleClientID,
            redirectScheme: AppConfig.googleRedirectScheme,
            redirectURI: AppConfig.googleRedirectURI,
            scope: AppConfig.googleCalendarScope,
            // As YouTube's: a distillation that has to ask again next month is
            // not the one-button experience this app is built around.
            extraAuthParameters: ["access_type": "offline", "prompt": "consent"],
            configHint: "AppConfig.googleClientID",
            // A separate consent flow means a separate grant and a separate
            // refresh token, so revoking one leaves the other alone. Somebody
            // disconnecting YouTube does not silently lose their calendar.
            revocationURL: "https://oauth2.googleapis.com/revoke"
        )
    }

    /// Outlook / Microsoft 365 calendars, through Microsoft Graph.
    ///
    /// **No MSAL, and that is a deliberate departure from Microsoft's own
    /// advice.** Their guidance is to use MSAL rather than hand-roll OAuth, and
    /// the reason they give — a mobile app is a public client that cannot hold
    /// a secret — is exactly why `OAuthPKCEService` exists and already serves
    /// four providers. Adding MSAL would mean this project's first SDK
    /// dependency, a keychain access group, two extra query schemes and a second
    /// authentication system alongside the one that works. Microsoft's endpoints
    /// speak ordinary authorization-code-with-PKCE, which is what this struct
    /// does. The convention here is to add a provider, not another auth service.
    ///
    /// **`common` as the authority**, so a personal `outlook.com` account and a
    /// university or employer's Microsoft 365 account both work. `organizations`
    /// would exclude the first and `consumers` the second, and this app has no
    /// business caring which somebody has.
    ///
    /// **A tenant may still refuse.** `Calendars.ReadBasic` does not normally
    /// need administrator consent, but an organisation can set a policy that
    /// blocks user consent to unverified publishers. That is a distinct failure
    /// from a wrong password and reads as one to the person: see
    /// `OutlookCalendarDistiller`, which names it rather than saying the
    /// connection failed.
    static var outlookCalendar: OAuthProvider {
        OAuthProvider(
            name: "Outlook Calendar",
            authorizationURL:
                "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
            tokenURL: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
            clientID: AppConfig.microsoftClientID,
            redirectScheme: AppConfig.microsoftRedirectScheme,
            redirectURI: AppConfig.microsoftRedirectURI,
            scope: AppConfig.outlookCalendarScope,
            // Microsoft returns a refresh token when `offline_access` is in the
            // scope rather than from a parameter, so there is nothing to add
            // here — unlike Google, which needs `access_type=offline`.
            extraAuthParameters: [:],
            configHint: "AppConfig.microsoftClientID",
            // Microsoft has no token-revocation endpoint of the kind Google
            // offers; a grant is withdrawn from the account's own app
            // permissions page. `disconnect()` still deletes our copy, which is
            // forgetting rather than revoking — the distinction `revoke()`
            // exists to draw, and here only half of it is available.
            // See `sendsScopeOnRefresh`: without it, Microsoft's refresh mints
            // a token Graph refuses, and the refusal appears after a sign-in
            // that looked perfect.
            sendsScopeOnRefresh: true,
            revocationURL: nil
        )
    }

    /// **The same Google client, asking a completely different question.**
    ///
    /// `google` above asks to read a YouTube library and wants a refresh token
    /// to do it again next month. This asks only who the person is, and the
    /// answer it wants is the `id_token` — which Supabase trades for a session
    /// exactly as it trades Apple's identity token. Nothing is stored on this
    /// side.
    ///
    /// `openid email profile` rather than a data scope, and no `access_type` or
    /// `prompt` overrides: offline access is meaningless for a one-shot
    /// identity check, and forcing the consent screen on somebody who has
    /// already granted it is friction for nothing.
    ///
    /// One client ID serves both, which is deliberate — it is the same app and
    /// the same consent screen. Somebody who signs in with Google and later
    /// connects YouTube sees a second prompt, because it is a genuinely
    /// different permission.
    static var googleSignIn: OAuthProvider {
        OAuthProvider(
            name: "Google Sign-In",
            authorizationURL: "https://accounts.google.com/o/oauth2/v2/auth",
            tokenURL: "https://oauth2.googleapis.com/token",
            clientID: AppConfig.googleClientID,
            redirectScheme: AppConfig.googleRedirectScheme,
            redirectURI: AppConfig.googleRedirectURI,
            scope: "openid email profile",
            extraAuthParameters: [:],
            configHint: "AppConfig.googleClientID",
            persistsRefreshToken: false
        )
    }

    /// Restored for the data-collection beta; see `AppConfig.spotifyClientID`.
    static var spotify: OAuthProvider {
        OAuthProvider(
            name: "Spotify",
            authorizationURL: "https://accounts.spotify.com/authorize",
            tokenURL: "https://accounts.spotify.com/api/token",
            clientID: AppConfig.spotifyClientID,
            redirectScheme: AppConfig.spotifyRedirectScheme,
            redirectURI: AppConfig.spotifyRedirectURI,
            scope: AppConfig.spotifyScope,
            extraAuthParameters: [:],
            configHint: "AppConfig.spotifyClientID"
        )
    }

}

/// One-tap sign-in using ASWebAuthenticationSession + PKCE.
///
/// Friction profile: the user taps "Distill", the system browser sheet appears
/// (sharing Safari's cookies, so usually already signed in), they tap "Allow" —
/// no password typing in the common case. The refresh token is kept in the
/// Keychain, so every later distill is zero-tap.
final class OAuthPKCEService: NSObject {

    enum OAuthError: LocalizedError {
        case notConfigured(provider: String, hint: String)
        case cancelled
        /// The account signed in successfully and its organisation will not
        /// let it approve this app.
        ///
        /// **A separate case because the remedy is a separate person.** Every
        /// other failure here is something the user can retry; this one can
        /// only be resolved by their IT administrator, and telling somebody to
        /// try again is telling them to do a thing that cannot work.
        case needsAdminConsent(provider: String)
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured(let provider, let hint):
                return "\(provider) client ID is not configured. Set \(hint)."
            case .cancelled:
                return "Sign-in was cancelled."
            case .needsAdminConsent(let provider):
                return "Your organisation has to approve Written before "
                    + "\(provider) can be connected. A personal account will "
                    + "work without approval."
            case .badResponse(let detail):
                return "Sign-in failed: \(detail)"
            }
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Double
        let refreshToken: String?
        /// Present only when `openid` is among the scopes — so `nil` for the
        /// data sources and populated for `googleSignIn`. It is the whole point
        /// of that provider: Supabase trades it for a session.
        let idToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
        }
    }

    /// The identity token from the most recent exchange, for the sign-in
    /// provider. Never written to disk: it is handed to Supabase within the
    /// same call and Supabase's own session is what persists.
    private(set) var lastIdentityToken: String?

    private let provider: OAuthProvider
    /// Scoped to the account, not just the provider.
    ///
    /// `google_refresh_token` on its own is a per-*device* key, so a token left
    /// behind at sign-out was picked up by whoever signed in next — they'd find
    /// YouTube already connected to someone else's channel. Sign-out used to
    /// paper over that by disconnecting every provider, which threw away a
    /// connection the owner would want back. Computed rather than stored: this
    /// service outlives a sign-in, and a captured scope would read the previous
    /// account's token.
    private var refreshTokenKey: String {
        AccountScope.key("\(provider.name.lowercased())_refresh_token")
    }

    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast
    private var webAuthSession: ASWebAuthenticationSession?

    init(provider: OAuthProvider) {
        self.provider = provider
    }

    /// Forgets this provider's stored consent.
    ///
    /// Lives here rather than as a Keychain key deleted from somewhere else, and
    /// that matters: the refresh token is keyed by *provider*, not by user, so
    /// signing out without clearing it hands the next account the previous one's
    /// connection — their next distillation would read a stranger's YouTube.
    /// Only this type knows the key, so only this type can be relied on to
    /// remove it, and a provider added later can't be silently missed.
    func disconnect() {
        KeychainStore.delete(refreshTokenKey)
        accessToken = nil
        accessTokenExpiry = .distantPast
    }

    /// Tells the provider the grant is over, then forgets it locally.
    ///
    /// **`disconnect()` alone is not revocation.** It deletes our copy of the
    /// token; the grant carries on existing in the user's Google account, so
    /// somebody who "disconnected" would still find Written listed at
    /// myaccount.google.com with permission it no longer intends to use. That
    /// gap is what this closes, and it is the difference between the two
    /// deadlines in YouTube's Developer Policies: III.D.2.c.1 gives 7 calendar
    /// days when the user revokes *through the client*, III.D.2.c.2 gives 30
    /// when they revoke at Google. We cannot be on the 7-day clock for an
    /// action that never reached Google.
    ///
    /// **The local half runs whether or not the network half does.** A revoke
    /// that fails leaves a grant alive at Google — recoverable, because the
    /// user can still revoke it there, and because the token we would have
    /// needed to try again is exactly what we are throwing away. Keeping the
    /// token in order to retry would mean keeping the connection the user just
    /// ended, which is the worse failure of the two.
    ///
    /// Returns whether Google confirmed. The caller deletes the data either
    /// way — deletion is owed on the *request*, not on the acknowledgement.
    @discardableResult
    func revoke() async -> Bool {
        // Prefer the refresh token: Google revokes the whole grant it belongs
        // to, where an access token revokes only itself and leaves the refresh
        // token able to mint another.
        let token = KeychainStore.read(refreshTokenKey) ?? accessToken
        defer { disconnect() }

        guard let urlString = provider.revocationURL,
              let url = URL(string: urlString),
              let token else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "token=\(token)".data(using: .utf8)

        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        // 200 is success. 400 means Google has never heard of the token, or has
        // already forgotten it — which is the state we were asking for, so it
        // counts.
        return http.statusCode == 200 || http.statusCode == 400
    }

    /// Returns a valid access token, reusing/refreshing silently when possible
    /// and falling back to the interactive consent sheet only when required.
    @MainActor
    func validAccessToken() async throws -> String {
        guard provider.isConfigured else {
            throw OAuthError.notConfigured(provider: provider.name, hint: provider.configHint)
        }

        if let token = accessToken, accessTokenExpiry > Date().addingTimeInterval(60) {
            return token
        }
        if let refreshToken = KeychainStore.read(refreshTokenKey),
           let token = try? await refreshAccessToken(refreshToken: refreshToken) {
            return token
        }
        return try await interactiveSignIn()
    }

    func signOut() {
        accessToken = nil
        accessTokenExpiry = .distantPast
        KeychainStore.delete(refreshTokenKey)
    }

    /// Runs the consent flow purely to find out who somebody is.
    ///
    /// Deliberately not `validAccessToken`: that reuses a cached token and a
    /// stored refresh token, which is right for reading a library and wrong
    /// here. Signing in must always be a fresh act — a stale identity token, or
    /// one silently refreshed from a previous user's grant, is the shape of bug
    /// that signs the wrong person in.
    @MainActor
    func interactiveIdentityToken() async throws -> String {
        guard provider.isConfigured else {
            throw OAuthError.notConfigured(provider: provider.name, hint: provider.configHint)
        }
        _ = try await interactiveSignIn()
        guard let identity = lastIdentityToken else {
            // `openid` was in the scope, so its absence is the provider not
            // answering the question rather than anything the user did.
            throw OAuthError.badResponse("no id_token in the token response")
        }
        return identity
    }

    // MARK: - Interactive flow

    @MainActor
    private func interactiveSignIn() async throws -> String {
        let verifier = Self.randomURLSafeString(bytes: 48)
        let challenge = Self.codeChallenge(for: verifier)

        var components = URLComponents(string: provider.authorizationURL)!
        var queryItems = [
            URLQueryItem(name: "client_id", value: provider.clientID),
            URLQueryItem(name: "redirect_uri", value: provider.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: provider.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        queryItems += provider.extraAuthParameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = queryItems

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: components.url!,
                callbackURLScheme: provider.redirectScheme
            ) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else if let error = error as? ASWebAuthenticationSessionError,
                          error.code == .canceledLogin {
                    continuation.resume(throwing: OAuthError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? OAuthError.badResponse("no callback"))
                }
            }
            session.presentationContextProvider = self
            // Reuse Safari's session cookies so most users never type a password.
            session.prefersEphemeralWebBrowserSession = false
            self.webAuthSession = session
            session.start()
        }

        let callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        func item(_ name: String) -> String? {
            callback?.queryItems?.first(where: { $0.name == name })?.value
        }

        // **The provider says why, and we were throwing it away.** A refusal
        // arrives as `error=` on the callback with no `code`, and reading only
        // `code` turned every one of them into "authorization code missing
        // from callback" — which is true, useless, and reads as our bug. Seen
        // on 2026-08-13: a university tenant requires admin consent, so the
        // sign-in succeeded and the consent screen refused, and the app said
        // nothing about an administrator.
        if let failure = item("error") {
            switch failure {
            // Backing out of a consent screen is a decision, not a fault, and
            // belongs at `.idle` like dismissing the sheet — which is what
            // `DistillViewModel.status(after:)` does with `.cancelled`.
            case "access_denied" where item("error_subcode") == "cancel":
                throw OAuthError.cancelled
            case "admin_consent_required", "consent_required", "access_denied":
                throw OAuthError.needsAdminConsent(provider: provider.name)
            default:
                // Everything else keeps the provider's own words, which are
                // more use than any sentence written here in advance.
                throw OAuthError.badResponse(
                    item("error_description") ?? failure
                )
            }
        }

        guard let code = item("code") else {
            throw OAuthError.badResponse("authorization code missing from callback")
        }

        return try await exchangeCode(code, verifier: verifier)
    }

    // MARK: - Token endpoint

    private func exchangeCode(_ code: String, verifier: String) async throws -> String {
        try await requestToken(parameters: [
            "client_id": provider.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": provider.redirectURI,
        ])
    }

    private func refreshAccessToken(refreshToken: String) async throws -> String {
        var parameters = [
            "client_id": provider.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        if provider.sendsScopeOnRefresh {
            parameters["scope"] = provider.scope
        }
        return try await requestToken(parameters: parameters)
    }

    private func requestToken(parameters: [String: String]) async throws -> String {
        var request = URLRequest(url: URL(string: provider.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = parameters
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.badResponse("token endpoint returned \(body.prefix(200))")
        }

        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken = token.accessToken
        accessTokenExpiry = Date().addingTimeInterval(token.expiresIn)
        lastIdentityToken = token.idToken
        if let refresh = token.refreshToken, provider.persistsRefreshToken {
            KeychainStore.save(refresh, for: refreshTokenKey)
        }
        return token.accessToken
    }

    // MARK: - PKCE helpers

    private static func randomURLSafeString(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

extension OAuthPKCEService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        ASPresentationAnchor()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
