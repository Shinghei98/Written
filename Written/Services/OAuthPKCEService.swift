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
            configHint: "AppConfig.googleClientID"
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
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured(let provider, let hint):
                return "\(provider) client ID is not configured. Set \(hint)."
            case .cancelled:
                return "Sign-in was cancelled."
            case .badResponse(let detail):
                return "Sign-in failed: \(detail)"
            }
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Double
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
        }
    }

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

        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
        else {
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
        try await requestToken(parameters: [
            "client_id": provider.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
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
        if let refresh = token.refreshToken {
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
