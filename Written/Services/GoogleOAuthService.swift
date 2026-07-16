import AuthenticationServices
import CryptoKit
import Foundation

/// One-tap Google sign-in using ASWebAuthenticationSession + PKCE.
///
/// Friction profile: the user taps "Distill", the system Google sheet appears
/// (already signed in via Safari cookies in most cases), they tap their account
/// and "Allow" — no password typing. The refresh token is kept in the Keychain,
/// so every later distill is zero-tap.
final class GoogleOAuthService: NSObject {

    enum OAuthError: LocalizedError {
        case notConfigured
        case cancelled
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Google client ID is not configured. Set AppConfig.googleClientID."
            case .cancelled:
                return "Sign-in was cancelled."
            case .badResponse(let detail):
                return "Google sign-in failed: \(detail)"
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

    private static let refreshTokenKey = "google_refresh_token"

    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast
    private var webAuthSession: ASWebAuthenticationSession?

    /// Returns a valid access token, reusing/refreshing silently when possible
    /// and falling back to the interactive consent sheet only when required.
    @MainActor
    func validAccessToken() async throws -> String {
        guard !AppConfig.googleClientID.hasPrefix("YOUR_CLIENT_ID") else {
            throw OAuthError.notConfigured
        }

        if let token = accessToken, accessTokenExpiry > Date().addingTimeInterval(60) {
            return token
        }
        if let refreshToken = KeychainStore.read(Self.refreshTokenKey),
           let token = try? await refreshAccessToken(refreshToken: refreshToken) {
            return token
        }
        return try await interactiveSignIn()
    }

    func signOut() {
        accessToken = nil
        accessTokenExpiry = .distantPast
        KeychainStore.delete(Self.refreshTokenKey)
    }

    // MARK: - Interactive flow

    @MainActor
    private func interactiveSignIn() async throws -> String {
        let verifier = Self.randomURLSafeString(bytes: 48)
        let challenge = Self.codeChallenge(for: verifier)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: AppConfig.googleClientID),
            URLQueryItem(name: "redirect_uri", value: AppConfig.googleRedirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: AppConfig.youtubeScope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: components.url!,
                callbackURLScheme: AppConfig.googleRedirectScheme
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
            // Reuse Safari's Google session so most users never type a password.
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
            "client_id": AppConfig.googleClientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": AppConfig.googleRedirectURI,
        ])
    }

    private func refreshAccessToken(refreshToken: String) async throws -> String {
        try await requestToken(parameters: [
            "client_id": AppConfig.googleClientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
    }

    private func requestToken(parameters: [String: String]) async throws -> String {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
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
            KeychainStore.save(refresh, for: Self.refreshTokenKey)
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

extension GoogleOAuthService: ASWebAuthenticationPresentationContextProviding {
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
