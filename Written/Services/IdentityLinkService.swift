import AuthenticationServices
import Foundation

/// Attaches an Apple or Google identity to the account somebody already has.
///
/// **This is the other half of the one-account rule.** A phone number creates
/// the account and nothing else can; Apple and Google are ways back into one,
/// and they only work once the identity has been attached here. Without this
/// screen the sign-in buttons would be permanently useless, because no identity
/// would ever be linked to anything.
///
/// Supabase calls it *manual identity linking*, and it is **off by default**:
/// the project needs `GOTRUE_SECURITY_MANUAL_LINKING_ENABLED` turned on
/// (Authentication settings in the dashboard). With it off the authorize call
/// answers 422 and this reports that rather than failing silently, because a
/// toggle that does nothing and says nothing is the defect this codebase keeps
/// paying for.
@MainActor
final class IdentityLinkService: NSObject, ObservableObject {

    static let shared = IdentityLinkService()

    /// Providers currently attached, as Supabase reports them.
    ///
    /// **Read from the server rather than remembered locally.** A link made on
    /// another device, or an identity Supabase attached by matching a verified
    /// email, is invisible to anything this phone wrote down — and a settings
    /// toggle that disagrees with the account is worse than no toggle.
    @Published private(set) var linked: Set<String> = []
    @Published private(set) var isWorking = false
    @Published var lastError: String?

    private var webAuthSession: ASWebAuthenticationSession?

    // MARK: - Reading

    func refresh() async {
        guard let token = await SupabaseAuth.shared.validAccessToken() else { return }

        var request = URLRequest(url: AppConfig.supabaseURL.appendingPathComponent("auth/v1/user"))
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let identities = body["identities"] as? [[String: Any]]
        else { return }

        linked = Set(identities.compactMap { $0["provider"] as? String })
    }

    /// The identity id for a provider, which unlinking needs and linking does
    /// not. Fetched fresh rather than cached: it is only wanted at the moment
    /// somebody taps, and a stale id would unlink nothing while reporting
    /// success.
    private func identityID(for provider: String) async -> String? {
        guard let token = await SupabaseAuth.shared.validAccessToken() else { return nil }

        var request = URLRequest(url: AppConfig.supabaseURL.appendingPathComponent("auth/v1/user"))
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let identities = body["identities"] as? [[String: Any]]
        else { return nil }

        return identities
            .first { $0["provider"] as? String == provider }?["identity_id"] as? String
    }

    // MARK: - Linking

    /// Attaches `provider` to the signed-in account.
    ///
    /// Supabase hands back a URL to visit rather than doing the exchange over
    /// REST, so this is a browser round trip — the same shape as connecting
    /// YouTube, and it reuses `ASWebAuthenticationSession` for the same reason:
    /// the sheet shares Safari's cookies, so somebody already signed into
    /// Google taps once rather than typing a password.
    func link(provider: String) async {
        isWorking = true
        defer { isWorking = false }

        guard let token = await SupabaseAuth.shared.validAccessToken() else {
            lastError = "You're signed out. Sign in again to connect an account."
            return
        }

        var components = URLComponents(
            url: AppConfig.supabaseURL.appendingPathComponent("auth/v1/user/identities/authorize"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "provider", value: provider),
            URLQueryItem(name: "redirect_to", value: AppConfig.googleRedirectURI),
            // Without this Supabase performs the redirect itself and the app
            // never sees the URL it is supposed to open.
            URLQueryItem(name: "skip_http_redirect", value: "true"),
        ]
        guard let url = components?.url else {
            lastError = "Couldn't build the request."
            return
        }

        var request = URLRequest(url: url)
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            lastError = "Couldn't reach the server."
            return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        guard status == 200, let authorizeURL = (body?["url"] as? String).flatMap(URL.init) else {
            // **422 is the one worth naming.** It is what Supabase answers when
            // manual linking is disabled for the project, and it is a setting
            // rather than a bug — so saying "couldn't connect" would send
            // somebody looking in the wrong place forever.
            if status == 422 {
                lastError = "Connecting accounts isn't enabled for this app yet."
            } else {
                lastError = (body?["msg"] as? String)
                    ?? (body?["error_description"] as? String)
                    ?? "Couldn't start connecting (\(status))."
            }
            return
        }

        do {
            let callback = try await visit(authorizeURL)
            // **The callback is the answer, and throwing it away made every
            // refusal silent.** Supabase attaches the identity server-side
            // *during* this redirect and reports a failure by putting `error`
            // and `error_description` on the URL it sends back — there is no
            // second request to check. This discarded it and then set
            // `lastError = nil` unconditionally, so a refused link and a
            // successful one were the same screen: a toggle that did not move
            // and nothing to say why.
            if let message = Self.failure(in: callback) {
                lastError = message
                await refresh()
                return
            }

            await refresh()

            // Belt and braces: a callback carrying no error at all, after which
            // the provider is still not attached, is a claim of success the
            // server does not support. Say the likeliest reason rather than
            // nothing — an identity may only belong to one account, and holding
            // two accounts is easy here, since three sign-in methods each make
            // their own.
            if linked.contains(provider) {
                lastError = nil
            } else {
                lastError = "That account is already connected to another Written account."
            }
        } catch is CancellationError {
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// What went wrong, read off the URL Supabase redirected back to.
    ///
    /// **Both the query and the fragment**, because which one carries it
    /// depends on the flow: an error raised before the token exchange arrives as
    /// a query, and one raised during it comes back in the fragment, where a
    /// token would have been. Reading only one of the two is how this looks
    /// fixed and still swallows half of the failures.
    private static func failure(in callback: URL) -> String? {
        var items: [URLQueryItem] = []
        let components = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        items += components?.queryItems ?? []
        if let fragment = components?.fragment {
            items += URLComponents(string: "?" + fragment)?.queryItems ?? []
        }

        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value?
                .replacingOccurrences(of: "+", with: " ")
        }

        guard value("error") != nil || value("error_code") != nil else { return nil }

        // Supabase's own wording where it has some, since it is the only thing
        // that knows which of several refusals this was.
        if let described = value("error_description"), !described.isEmpty {
            return described
        }
        return "Couldn't connect that account."
    }

    /// Detaches `provider`.
    ///
    /// Supabase refuses to remove somebody's only identity, which is correct
    /// and is surfaced rather than pre-empted: for a phone account the phone is
    /// itself an identity, so unlinking Google always leaves a way in, and
    /// guessing at the rule here would only be a second place to get it wrong.
    func unlink(provider: String) async {
        isWorking = true
        defer { isWorking = false }

        guard let token = await SupabaseAuth.shared.validAccessToken() else {
            lastError = "You're signed out."
            return
        }
        guard let identityID = await identityID(for: provider) else {
            lastError = "That account isn't connected."
            return
        }

        var request = URLRequest(
            url: AppConfig.supabaseURL
                .appendingPathComponent("auth/v1/user/identities/\(identityID)")
        )
        request.httpMethod = "DELETE"
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            lastError = "Couldn't reach the server."
            return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            lastError = (body?["msg"] as? String) ?? "Couldn't disconnect (\(status))."
            return
        }

        await refresh()
        lastError = nil
    }

    // MARK: - The browser leg

    private func visit(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: AppConfig.googleRedirectScheme
            ) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError,
                          error.code == .canceledLogin {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(
                        throwing: error ?? NSError(
                            domain: "IdentityLink", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "No callback."]
                        )
                    )
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.webAuthSession = session
            session.start()
        }
    }
}

extension IdentityLinkService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }
}
