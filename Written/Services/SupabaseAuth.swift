import AuthenticationServices
import CryptoKit
import Foundation

/// Sign in with Apple, exchanged for a Supabase session.
///
/// Hand-rolled against Supabase's REST endpoints rather than adding
/// `supabase-swift`. The project has no package dependencies at all — it
/// implements OAuth PKCE itself rather than pulling in Google's SDK — and the
/// surface needed here is two endpoints and a Keychain read. `KeychainStore`
/// already persists refresh tokens between launches for exactly this purpose.
///
/// The native flow, not the web one: the app receives an identity token from
/// `ASAuthorization` and posts it straight to Supabase, which verifies it
/// against Apple's public keys. That is why the Supabase provider needs only
/// `com.written.datingapp` in its Client IDs, and no `.p8`, Services ID or
/// client-secret JWT — all of which the redirect-based flow would require.
@MainActor
final class SupabaseAuth: NSObject, ObservableObject {

    static let shared = SupabaseAuth()

    /// The signed-in user's id, which every row in the database hangs off.
    @Published private(set) var userID: String?

    /// What we know them as, `nil` until a name has been stored.
    ///
    /// Apple hands over a name on the *first* sign-in only, and the user can
    /// decline to share it at all — so this is frequently empty even for a
    /// brand-new account, and the app asks for it directly rather than going
    /// without.
    @Published private(set) var firstName: String?

    /// Whether to put the name screen in front of them before the garden.
    var needsName: Bool { userID != nil && (firstName?.isEmpty ?? true) }

    /// Whether the photo step has ever been shown.
    ///
    /// Tracked separately from the name, because the two are unrelated: Apple
    /// volunteers a name on the very first sign-in, so an account can arrive
    /// already named and — when onboarding was chained off `needsName` — never
    /// be offered the photo page at all.
    @Published private(set) var hasSeenPhotoStep = false

    var needsPhotos: Bool { userID != nil && !hasSeenPhotoStep }

    private var accessToken: String?
    private var accessTokenExpiry: Date?

    private static let refreshTokenKey = "supabase_refresh_token"

    /// Carried between the Apple request and the Supabase exchange. Apple is
    /// given its SHA-256; Supabase is given the original, and checks that
    /// hashing it reproduces the `nonce` claim inside the identity token. Sending
    /// the hashed value to both — the easy mistake — fails with an error that
    /// says nothing about nonces.
    private var currentNonce: String?
    private var continuation: CheckedContinuation<Void, Error>?

    enum AuthError: LocalizedError {
        case cancelled
        case noIdentityToken
        case server(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return "Sign in was cancelled."
            case .noIdentityToken: return "Apple didn't return an identity token."
            case .server(let message): return message
            }
        }
    }

    var isSignedIn: Bool { userID != nil }

    /// Whether this device holds a session, answered *synchronously*.
    ///
    /// `restoreSession()` has to reach Supabase to trade the refresh token for
    /// an access token, and that round trip took two to four seconds — during
    /// which the app showed the sign-in screen to someone who was already
    /// signed in, then swapped it for the garden. Reading the Keychain costs
    /// nothing and answers the only question the first frame needs: *was* this
    /// person signed in. Whether the token is still good is settled a moment
    /// later, and if it isn't they land on sign-in then.
    nonisolated static var hasStoredSession: Bool {
        KeychainStore.read(refreshTokenKey) != nil
    }

    // MARK: - Where onboarding got to

    /// The three-way branch every route into the app funnels through.
    enum OnboardingStep: String {
        case name, photos, exploring, done
    }

    var onboardingStep: OnboardingStep {
        if needsName { return .name }
        if needsPhotos { return .photos }
        if !hasExplored { return .exploring }
        return .done
    }

    /// Whether "Explore" has been tapped on the profile preview, which is where
    /// onboarding ends.
    ///
    /// **Local only**, unlike the two steps before it, which are mirrored from
    /// columns on `public.users`. A reinstall will therefore walk someone
    /// through the garden a second time. That is a real gap and the fix is a
    /// column plus a migration; it is recorded rather than hidden because the
    /// consequence is mild and the alternative was blocking this on a schema
    /// change.
    private static var hasExploredKey: String { AccountScope.key("written.onboarding.explored") }

    private(set) var hasExplored: Bool {
        get { UserDefaults.standard.bool(forKey: Self.hasExploredKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.hasExploredKey) }
    }

    /// The end of onboarding. From here the tab bar appears and the garden gives
    /// up its arrow.
    func markExplored() {
        hasExplored = true
        cacheOnboardingStep()
    }

    private static let onboardingStepKey = "supabase_onboarding_step"
    private static let userIDKey = "supabase_user_id"

    /// The signed-in user's id, answered *synchronously*.
    ///
    /// `AccountScope` needs it on the first frame to know which files and
    /// Keychain items belong to this account, and `userID` isn't set until the
    /// token refresh returns. Not a secret — it is the `sub` of a JWT this
    /// device already holds, and it authorises nothing on its own.
    nonisolated static var storedUserID: String? {
        guard hasStoredSession else { return nil }
        return UserDefaults.standard.string(forKey: userIDKey)
    }

    /// The step this device last saw, answered *synchronously*.
    ///
    /// `nil` when nobody is signed in. Both facts it derives from — the name and
    /// whether the photo page has been shown — live on the server, so without a
    /// local mirror the answer arrives a network round trip after the first
    /// frame, which is far too late to decide what to draw. Someone who
    /// force-quit on the name page would be shown the garden and never asked
    /// again; someone who quit on the photo page, the same.
    ///
    /// The server stays the authority. This is only what lets the right page be
    /// drawn immediately, and `restoreSession` corrects it a moment later if the
    /// two disagree.
    nonisolated static var restoredStep: OnboardingStep? {
        guard hasStoredSession else { return nil }
        // A session with nothing recorded predates this cache. Treat it as
        // finished — those accounts already got through onboarding.
        guard let raw = UserDefaults.standard.string(forKey: onboardingStepKey) else { return .done }
        return OnboardingStep(rawValue: raw)
    }

    /// Mirrors the step locally. Called after anything that could move it.
    private func cacheOnboardingStep() {
        guard userID != nil else { return }
        UserDefaults.standard.set(onboardingStep.rawValue, forKey: Self.onboardingStepKey)
    }

    // MARK: - Signing in

    /// Presents Apple's sheet and exchanges the result for a Supabase session.
    func signInWithApple() async throws {
        let nonce = Self.randomNonce()
        currentNonce = nonce

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    /// Restores a session from the Keychain, so a returning user never signs in
    /// twice — the same promise the OAuth sources make.
    func restoreSession() async {
        guard let refreshToken = KeychainStore.read(Self.refreshTokenKey) else { return }
        try? await exchange(
            grantType: "refresh_token",
            body: ["refresh_token": refreshToken]
        )
        if userID != nil, firstName == nil { await loadProfile() }
    }

    func signOut() {
        KeychainStore.delete(Self.refreshTokenKey)
        UserDefaults.standard.removeObject(forKey: Self.onboardingStepKey)
        accessToken = nil
        accessTokenExpiry = nil
        userID = nil
        // Otherwise the next account inherits this one's answers and is never
        // asked for a name — the same defect `signOutLocalState` exists to stop.
        firstName = nil
        hasSeenPhotoStep = false
        // Scoped to the account, so this clears that account's flag rather than
        // whoever signs in next — the same reasoning as the two above.
        UserDefaults.standard.removeObject(forKey: Self.hasExploredKey)
    }

    /// Deletes the account and everything hanging off it.
    ///
    /// Two steps, in this order on purpose:
    ///
    /// 1. **The data**, by deleting the `public.users` row. RLS lets someone
    ///    delete their own row and every other table cascades from it, so this
    ///    needs nothing the app doesn't already have — and it is what guarantees
    ///    the personal data is gone even if step two can't run.
    /// 2. **The login record** in `auth.users`, which only `service_role` can
    ///    remove and so has to happen in an Edge Function. If that function
    ///    isn't deployed this throws, *after* the data is already gone — the
    ///    account is then empty rather than absent, and signing in with Apple
    ///    again would make a fresh, blank one.
    ///
    /// Whichever way it ends, the session is dropped before returning.
    func deleteAccount() async throws {
        guard let userID, let token = await validAccessToken() else {
            throw AuthError.server("You're not signed in.")
        }

        var deleteRow = URLRequest(url: {
            var components = URLComponents(
                url: AppConfig.supabaseURL.appendingPathComponent("rest/v1/users"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(userID)")]
            return components?.url ?? AppConfig.supabaseURL
        }())
        deleteRow.httpMethod = "DELETE"
        deleteRow.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        deleteRow.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (rowData, rowResponse) = try await URLSession.shared.data(for: deleteRow)
        let rowStatus = (rowResponse as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(rowStatus) else {
            let detail = (try? JSONSerialization.jsonObject(with: rowData) as? [String: Any])
                .flatMap { $0?["message"] as? String }
            throw AuthError.server(detail ?? "Couldn't delete your data (\(rowStatus)).")
        }

        // The data is gone from here on, so the session goes regardless of what
        // the function says — leaving someone signed in to an emptied account is
        // worse than signing them out of one whose login record survives.
        defer { signOut() }

        var callFunction = URLRequest(
            url: AppConfig.supabaseURL.appendingPathComponent("functions/v1/delete-account")
        )
        callFunction.httpMethod = "POST"
        callFunction.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        callFunction.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (functionData, functionResponse) = try await URLSession.shared.data(for: callFunction)
        let functionStatus = (functionResponse as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(functionStatus) else {
            let detail = (try? JSONSerialization.jsonObject(with: functionData) as? [String: Any])
                .flatMap { $0?["error"] as? String }
            throw AuthError.server(
                detail ?? "Your data was deleted, but the sign-in record couldn't be removed "
                    + "(\(functionStatus)). Deploy the delete-account function."
            )
        }
    }

    /// A valid access token for PostgREST, refreshed when it is close to expiry.
    ///
    /// Sixty seconds of slack: a token that expires mid-flight produces a 401
    /// the caller has no good way to distinguish from a permissions problem.
    func validAccessToken() async -> String? {
        if let accessToken, let expiry = accessTokenExpiry, expiry.timeIntervalSinceNow > 60 {
            return accessToken
        }
        await restoreSession()
        return accessToken
    }

    // MARK: - Talking to Supabase

    private struct Session: Decodable {
        let access_token: String
        let refresh_token: String
        let expires_in: Double
        let user: User

        struct User: Decodable { let id: String }
    }

    /// `grantType` is a *query* item, not part of the path.
    ///
    /// `appendingPathComponent("token?grant_type=…")` percent-encodes the `?`
    /// into `%3F`, so the request goes to a path that doesn't exist and Supabase
    /// answers 404 — with nothing to suggest the URL was the problem.
    private func exchange(grantType: String, body: [String: String]) async throws {
        var components = URLComponents(
            url: AppConfig.supabaseURL.appendingPathComponent("auth/v1/token"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "grant_type", value: grantType)]
        guard let url = components?.url else { throw AuthError.server("Bad auth URL.") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            // Supabase puts the useful part in `error_description`, and a bare
            // status code here would be as unhelpful as the HealthKit hang was.
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0?["error_description"] as? String ?? $0?["msg"] as? String }
            throw AuthError.server(detail ?? "Sign in failed (\((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }

        let session = try JSONDecoder().decode(Session.self, from: data)
        accessToken = session.access_token
        accessTokenExpiry = Date().addingTimeInterval(session.expires_in)
        KeychainStore.save(session.refresh_token, for: Self.refreshTokenKey)
        userID = session.user.id
        // Written before anything reads `AccountScope`, so the per-account
        // stores open the right files on the very next access.
        UserDefaults.standard.set(session.user.id, forKey: Self.userIDKey)
    }

    // MARK: - Nonce

    private static func randomNonce(length: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        // Unreserved URL characters only; the nonce travels inside a JWT claim.
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Apple's callbacks

extension SupabaseAuth: ASAuthorizationControllerDelegate {
    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8),
              let nonce = currentNonce
        else {
            continuation?.resume(throwing: AuthError.noIdentityToken)
            continuation = nil
            return
        }

        Task {
            do {
                try await exchange(
                    grantType: "id_token",
                    body: ["provider": "apple", "id_token": idToken, "nonce": nonce]
                )
                // Always, not only when a name came with it. Apple offers the
                // name on the *first* sign-in and never again, but this row is
                // what every foreign key in the schema points at — skip it on a
                // later sign-in and the account exists in `auth.users` with no
                // profile, so the first record sync fails its FK constraint.
                try await upsertProfile(name: credential.fullName)
                // Apple only volunteers the name once ever, so a returning user
                // arrives here with nothing — read back what was stored the
                // first time rather than asking them again.
                if firstName == nil { await loadProfile() }
                continuation?.resume()
            } catch {
                continuation?.resume(throwing: error)
            }
            continuation = nil
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let isCancel = (error as? ASAuthorizationError)?.code == .canceled
        continuation?.resume(throwing: isCancel ? AuthError.cancelled : error)
        continuation = nil
    }

    /// The profile row every other table's foreign key points at.
    ///
    /// Throws rather than swallowing: this failing means the account exists in
    /// `auth.users` with nothing behind it, and the first attempt to sync
    /// records would fail on the foreign key with an error nowhere near the
    /// cause. Better to say so while the user is still looking at a sign-in
    /// screen.
    private func upsertProfile(name: PersonNameComponents?) async throws {
        guard let userID, let accessToken else { throw AuthError.server("No session to write a profile with.") }

        var request = URLRequest(url: AppConfig.supabaseURL.appendingPathComponent("rest/v1/users"))
        request.httpMethod = "POST"
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Upsert, because signing in again must not collide on the primary key.
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")

        // The name only when Apple actually offered one. Sending empty strings
        // on a later sign-in would overwrite the name captured on the first,
        // which is the only time it is ever available.
        var row: [String: Any] = ["id": userID]
        if let given = name?.givenName, !given.isEmpty { row["first_name"] = given }
        if let family = name?.familyName, !family.isEmpty { row["last_name"] = family }
        request.httpBody = try JSONSerialization.data(withJSONObject: [row])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0?["message"] as? String }
            throw AuthError.server(detail ?? "Couldn't save your profile (\(status)).")
        }

        if let given = row["first_name"] as? String { firstName = given }
        cacheOnboardingStep()
    }

    /// The name the user typed on `NameEntryView`, when Apple didn't supply one.
    func saveName(first: String, last: String?) async throws {
        var components = PersonNameComponents()
        components.givenName = first
        components.familyName = last
        try await upsertProfile(name: components)
    }

    /// Reads the stored profile back, so a returning user isn't asked their name
    /// again on a device Apple has already stopped volunteering it to.
    private func loadProfile() async {
        guard let userID, let accessToken else { return }
        var components = URLComponents(
            url: AppConfig.supabaseURL.appendingPathComponent("rest/v1/users"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(userID)"),
            URLQueryItem(name: "select", value: "first_name,photos_added_at")
        ]
        guard let url = components?.url else { return }

        var request = URLRequest(url: url)
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let row = rows.first
        else { return }

        if let name = row["first_name"] as? String, !name.isEmpty { firstName = name }
        hasSeenPhotoStep = row["photos_added_at"] is String
        cacheOnboardingStep()
    }

    /// Marks the photo step done, whether they added any or skipped.
    ///
    /// Both count as having been asked. Re-prompting someone who declined on
    /// every launch would be nagging; the way back in belongs on the profile,
    /// next to the other things they can edit.
    func markPhotoStepSeen() async {
        hasSeenPhotoStep = true
        cacheOnboardingStep()
        guard let userID, let accessToken else { return }

        var request = URLRequest(url: AppConfig.supabaseURL.appendingPathComponent("rest/v1/users"))
        request.httpMethod = "POST"
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [[
            "id": userID,
            "photos_added_at": ISO8601DateFormatter().string(from: Date())
        ]])
        _ = try? await URLSession.shared.data(for: request)
    }
}

extension SupabaseAuth: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }
}
