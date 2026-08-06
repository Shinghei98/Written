import AuthenticationServices
import CryptoKit
import Foundation
import os

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

    /// The auth path is the one place here where a wrong guess is expensive: it
    /// fails on a device, behind an Apple account no simulator can hold, and
    /// every failure downstream of it looks like something else. A whole session
    /// went into inferring which of four candidates was refusing a write.
    ///
    /// **Never log a token or a session body.** The refresh response carries
    /// both an access token and a fresh refresh token, and the unified log is
    /// readable by anyone with the phone plugged in. Status codes and Supabase's
    /// `error_description` only.
    ///
    /// `nonisolated` because `KeychainStore` is not on the main actor and has
    /// the most important thing here to report. Prefer `trace` over this
    /// directly — see why there.
    nonisolated static let log = Logger(subsystem: "com.written.auth", category: "session")

    /// One line to both the unified log and stdout.
    ///
    /// Both, because neither alone can be read when it is needed. The unified
    /// log survives a crash and can be pulled off the phone later, but current
    /// macOS `log stream` has no device option, so a Mac cannot watch it live.
    /// `devicectl device process launch --console` *can* watch stdout, which
    /// `Logger` never writes to. Two channels, one call, and the same lesson the
    /// layout audit learned about `print` never reaching `xcodebuild`.
    nonisolated static func trace(_ message: String) {
        log.error("\(message, privacy: .public)")
#if DEBUG
        print("[auth] \(message)")
#endif
    }

    /// Why the last attempt to obtain an access token failed.
    ///
    /// `validAccessToken()` answers `String?`, which flattens three different
    /// situations into one `nil` — and callers then have to invent a reason.
    /// They invented the wrong one: a phone that could not reach Supabase was
    /// told "no session to write a profile with", which reads as *signed out*
    /// and sent an entire debugging session into the auth layer over what was a
    /// network fault. The distinction already existed in `RestoreOutcome`; this
    /// carries it out to whoever has to word the failure.
    private(set) var lastTokenFailure: TokenFailure?

    enum TokenFailure {
        /// Nothing in the Keychain. Genuinely signed out.
        case signedOut
        /// Supabase answered and refused the refresh token.
        case expired
        /// Never got an answer — offline, DNS, a timeout, or Supabase down.
        case unreachable

        /// Lower-cased: these are appended to "Couldn't save that — ".
        var message: String {
            switch self {
            case .signedOut:   return "you're signed out. Please sign in again."
            case .expired:     return "your session expired. Please sign in again."
            case .unreachable: return "couldn't reach the server. Check your connection."
            }
        }
    }

    /// The one refresh in flight, if there is one.
    ///
    /// **Supabase rotates refresh tokens**, and treats a token presented twice
    /// as a possible theft — it can revoke the whole family, which would end the
    /// session permanently rather than just failing one call. This class is
    /// `@MainActor`, but `exchange` suspends on the network, so the twelve-odd
    /// callers of `validAccessToken()` — `ChatService`'s four-second poll among
    /// them — can interleave inside that suspension, each read the same stored
    /// token and each post it. Funnelling them into one task makes that
    /// impossible by construction.
    private var refresh: Task<RestoreOutcome, Never>?

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
        /// Supabase could not be reached at all — offline, DNS, a timeout, or the
        /// service being down.
        ///
        /// **Distinct from `.server` on purpose, and the distinction is the whole
        /// point.** A refresh that comes back 400 means the token is dead and the
        /// person must sign in again; a refresh that never arrives means nothing
        /// about the token. Collapsing the two signed people out for being on a
        /// plane.
        case unreachable

        var errorDescription: String? {
            switch self {
            case .cancelled: return "Sign in was cancelled."
            case .noIdentityToken: return "Apple didn't return an identity token."
            case .server(let message): return message
            case .unreachable: return "Couldn't reach the server."
            }
        }
    }

    /// What a session restore concluded, which is not the same as whether it
    /// succeeded.
    enum RestoreOutcome {
        /// The token was traded and the session is live.
        case restored
        /// Supabase answered and refused. The stored token is no good.
        case rejected
        /// Supabase never answered. The stored token is still presumed good.
        case unreachable
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
        case name, communication, photos, exploring, done
    }

    var onboardingStep: OnboardingStep {
        if needsName { return .name }
        if needsCommunicationStyle { return .communication }
        if needsPhotos { return .photos }
        if !hasExplored { return .exploring }
        return .done
    }

    /// Whether the flirt-level and response-time sliders still need asking.
    ///
    /// **Answered from the stored answers themselves**, rather than from a
    /// separate "has been asked" flag. The two cannot then disagree, which is
    /// the failure `hasSeenPhotoStep` has to work around — the photo page is
    /// finished whether or not anything was picked, so it genuinely needs a flag
    /// of its own. These sliders always produce an answer, so having one *is*
    /// having been asked.
    ///
    /// Local, like `hasExplored` and for the same reason: this is a `user`
    /// record rather than a column, so a reinstall asks once more before the
    /// restore lands. Mild, and cheaper than a migration.
    var needsCommunicationStyle: Bool {
        userID != nil && CommunicationStyleStore.saved == nil
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
        let cached = OnboardingStep(rawValue: raw)
        // **A step added after this account finished onboarding.**
        //
        // The cache says `done`, and it was — for the steps that existed when it
        // was written. The sliders are new and still unanswered, so the honest
        // answer is `.communication`, and giving it here rather than only in
        // `onboardingStep` is what keeps the synchronous first frame and the
        // live computation from disagreeing. They disagreeing is the failure
        // `Route` exists to prevent: the shell would build with no tab bar for
        // an established user, then correct itself a second later.
        if cached == .exploring || cached == .done, CommunicationStyleStore.saved == nil {
            return .communication
        }
        return cached
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
    /// Trades the stored refresh token for a live session, and **says which kind
    /// of failure it had** when it cannot.
    ///
    /// It used to be `try?` and return nothing, which made offline and revoked
    /// indistinguishable to the caller — so launching in airplane mode dropped
    /// straight to the sign-in screen with a perfectly good token in the
    /// Keychain. The route is only allowed to give up on a `.rejected`.
    @discardableResult
    func restoreSession() async -> RestoreOutcome {
        // Join the refresh already running rather than starting a second one;
        // see `refresh` for why a duplicate is worse than a slow one.
        if let refresh { return await refresh.value }
        let task = Task<RestoreOutcome, Never> { await self.performRestore() }
        refresh = task
        let outcome = await task.value
        refresh = nil
        return outcome
    }

    private func performRestore() async -> RestoreOutcome {
        guard let refreshToken = KeychainStore.read(Self.refreshTokenKey) else {
            Self.trace("restore: no refresh token in the keychain")
            lastTokenFailure = .signedOut
            return .rejected
        }
        do {
            try await exchange(
                grantType: "refresh_token",
                body: ["refresh_token": refreshToken]
            )
        } catch AuthError.unreachable {
            Self.trace("restore: unreachable")
            lastTokenFailure = .unreachable
            return .unreachable
        } catch {
            // Supabase answered and said no. The token is spent — anything else
            // would leave somebody stuck behind a credential that will never
            // work again.
            Self.trace("restore: rejected — \(error.localizedDescription)")
            lastTokenFailure = .expired
            return .rejected
        }
        Self.trace("restore: ok")
        lastTokenFailure = nil
        if userID != nil, firstName == nil { await loadProfile() }
        return .restored
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
        // Scoped to the account, so these clear that account's answers rather
        // than whoever signs in next — the same reasoning as the two above, and
        // for the sliders it is the difference between the next person being
        // asked their boundaries and inheriting a stranger's.
        UserDefaults.standard.removeObject(forKey: Self.hasExploredKey)
        CommunicationStyleStore.clear()
        DatingPreferencesStore.clear()
        clearSignInProvider()
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
    /// Who is signed in, **after** making sure the session has been restored.
    ///
    /// **`userID` on its own is a cache and is nil far more often than it
    /// looks.** It is filled in by the token exchange, so on a cold launch it
    /// stays nil until `restoreSession()` has been round the network — and
    /// `RootView` deliberately does not wait for that, because the first frame
    /// is decided from the Keychain. So somebody can be legitimately signed in,
    /// looking at their garden, with this property empty.
    ///
    /// CLAUDE.md records this as its own recurring bug and it kept recurring:
    /// ten reads across `ChatService` and `LikeService` guarded on the raw
    /// property, which is why a cold launch showed an empty chat list and no
    /// admirers — every fetch answered "not signed in" and returned `[]`, and
    /// an empty list is indistinguishable from an account with no threads.
    ///
    /// This is the accessor to use anywhere a user id is needed before a
    /// request. `validAccessToken()` is what does the waiting.
    func currentUserID() async -> String? {
        guard await validAccessToken() != nil else { return nil }
        return userID
    }

    func validAccessToken() async -> String? {
        if let accessToken, let expiry = accessTokenExpiry, expiry.timeIntervalSinceNow > 60 {
            lastTokenFailure = nil
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

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // Never reached the server. Reported as such rather than as a
            // failure of the credential, which is a different fact entirely.
            Self.trace("token(\(grantType)): transport failed — \(error.localizedDescription)")
            throw AuthError.unreachable
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        Self.trace("token(\(grantType)): HTTP \(status)")
        // 5xx is the server having a bad day, not a verdict on this token.
        guard status < 500 else { throw AuthError.unreachable }

        guard status == 200 else {
            // Supabase puts the useful part in `error_description`, and a bare
            // status code here would be as unhelpful as the HealthKit hang was.
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0?["error_description"] as? String ?? $0?["msg"] as? String }
            // Safe to log: this is the *error* body, so it carries no session.
            Self.trace("token(\(grantType)): \(detail ?? "no error_description")")
            throw AuthError.server(detail ?? "Sign in failed (\(status)).")
        }

        adopt(try JSONDecoder().decode(Session.self, from: data))
    }

    /// Takes a freshly issued session as this device's own.
    ///
    /// Lifted out of `exchange` because phone sign-in arrives from a *different*
    /// endpoint — `auth/v1/verify` rather than `auth/v1/token` — and needs every
    /// one of these steps identically. Two copies of this would be two places to
    /// forget the `UserDefaults` write, and forgetting it means the
    /// account-scoped stores open the previous account's files.
    private func adopt(_ session: Session) {
        accessToken = session.access_token
        accessTokenExpiry = Date().addingTimeInterval(session.expires_in)
        KeychainStore.save(session.refresh_token, for: Self.refreshTokenKey)
        userID = session.user.id
        // Written before anything reads `AccountScope`, so the per-account
        // stores open the right files on the very next access.
        UserDefaults.standard.set(session.user.id, forKey: Self.userIDKey)
    }

    // MARK: - Which method opened this account

    /// How somebody signs in. Recorded so the settings page can say which of
    /// the three this account belongs to.
    ///
    /// **Not read from the session**, though it could be: Supabase carries
    /// identities on the user object, and reading them would need a second
    /// request on a screen that should draw immediately. This is one string
    /// written once at sign-in, and the settings row is the only reader.
    enum SignInProvider: String {
        case apple, google, phone
    }

    /// Global rather than account-scoped, deliberately: it is written during
    /// sign-in, and `AccountScope` still resolves to `local` at that moment
    /// because the account id has not been stored yet. That ordering is the
    /// same trap `googleSignIn` documents for refresh tokens.
    private static let signInProviderKey = "written.signin.provider"

    @Published private(set) var signInProvider: SignInProvider? =
        UserDefaults.standard.string(forKey: SupabaseAuth.signInProviderKey)
            .flatMap(SignInProvider.init(rawValue:))

    func recordSignIn(_ provider: SignInProvider) {
        signInProvider = provider
        UserDefaults.standard.set(provider.rawValue, forKey: Self.signInProviderKey)
    }

    private func clearSignInProvider() {
        signInProvider = nil
        UserDefaults.standard.removeObject(forKey: Self.signInProviderKey)
    }

    // MARK: - Google

    /// Signs in with Google, by the same trade Apple's path makes.
    ///
    /// **No SDK and no client secret.** The app already speaks Google OAuth with
    /// PKCE — that is how YouTube is connected — so this reuses it with an
    /// `openid` scope and hands the resulting `id_token` to Supabase, which
    /// swaps it for a session exactly as it swaps Apple's identity token. The
    /// dashboard side is the Google provider enabled with this app's client ID
    /// in **Authorized Client IDs**; there is no secret to keep because a native
    /// client has none.
    ///
    /// `exchange` rather than a new endpoint: `grant_type=id_token` returns the
    /// same `Session`, and reusing it means the five steps of adopting a session
    /// are written once. It also inherits the URL-building that keeps
    /// `grant_type` a query item — appending it to the path percent-encodes the
    /// `?` and Supabase answers 404 with nothing to suggest why.
    @MainActor
    func signInWithGoogle() async throws {
        let identity = try await OAuthPKCEService(provider: .googleSignIn)
            .interactiveIdentityToken()
        try await exchange(
            grantType: "id_token",
            body: ["provider": "google", "id_token": identity]
        )
        recordSignIn(.google)
        // Apple's path loads the profile through its delegate; this one has no
        // delegate, so without this `onboardingStep` is asked where the user is
        // before anything knows their name.
        await loadProfile()
    }

    // MARK: - Phone

    /// Sends a one-time code by SMS, through Supabase's Twilio Verify provider.
    ///
    /// **Every call to this costs money** — about $0.058 in the US and $0.12 in
    /// Hong Kong — so it is deliberately the only thing that sends one, and
    /// nothing calls it on a returning user: the Keychain refresh token carries
    /// them, and a second SMS for somebody already signed in is money burnt for
    /// nothing.
    ///
    /// `phone` must be E.164 (`+85298765432`), and must be *byte for byte* the
    /// same string passed to `verifyOTP` — Supabase matches the verification
    /// against the number it sent to, so a space or a dash in one and not the
    /// other fails against a number it never messaged.
    func sendOTP(phone: String) async throws {
        _ = try await postAuth(path: "auth/v1/otp", body: ["phone": phone])
    }

    /// Exchanges the code for a real session.
    ///
    /// The account is created here on first use — there is no separate sign-up —
    /// so the caller must route from `onboardingStep` afterwards rather than
    /// assuming a step. Hardcoding `.photos` here is what skipped the name and
    /// communication style pages for every phone user.
    func verifyOTP(phone: String, code: String) async throws {
        let data = try await postAuth(
            path: "auth/v1/verify",
            body: ["phone": phone, "token": code, "type": "sms"]
        )
        adopt(try JSONDecoder().decode(Session.self, from: data))
        // Apple's path loads the profile through its delegate; this one has no
        recordSignIn(.phone)
        // delegate, so the name has to be fetched before anything asks whether
        // onboarding is done.
        await loadProfile()
    }

    /// One POST to an auth endpoint, with the same error handling `exchange`
    /// uses — which matters more here than anywhere else: "that code is wrong"
    /// and "we couldn't reach the server" are different sentences to put in
    /// front of somebody holding a phone waiting for an SMS, and telling them
    /// the wrong one sends them to check their signal or retype a good code.
    @discardableResult
    private func postAuth(path: String, body: [String: String]) async throws -> Data {
        guard let url = URL(string: AppConfig.supabaseURL.appendingPathComponent(path).absoluteString) else {
            throw AuthError.server("Bad auth URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            Self.trace("\(path): transport failed — \(error.localizedDescription)")
            throw AuthError.unreachable
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        Self.trace("\(path): HTTP \(status)")
        guard status < 500 else { throw AuthError.unreachable }
        guard (200..<300).contains(status) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0?["error_description"] as? String ?? $0?["msg"] as? String }
            Self.trace("\(path): \(detail ?? "no error_description")")
            throw AuthError.server(detail ?? "That didn't work (\(status)).")
        }
        return data
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
                recordSignIn(.apple)
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
        let ns = error as NSError
        Self.trace("apple: \(ns.domain) \(ns.code) — \(ns.localizedDescription); underlying: \(String(describing: ns.userInfo[NSUnderlyingErrorKey]))")
        continuation?.resume(throwing: Self.readable(error))
        continuation = nil
    }

    /// Apple's errors, in words that name a next action.
    ///
    /// `ASAuthorizationError` bridges to `NSError`, so passing it through gives
    /// "The operation couldn't be completed. (…AuthorizationError error 1000.)"
    /// — which is what a user was shown, and it says nothing about what to do or
    /// even which side failed. 1000 is `.unknown`, and it is raised by Apple's
    /// own sheet **before Supabase is contacted at all**, so it is never a
    /// backend or provisioning fault when the entitlement is present. In
    /// practice it means no working connection, no iCloud account on the device,
    /// or Screen Time blocking account changes.
    ///
    /// The numeric code is kept in every message: it is what makes a report
    /// searchable, and it is the only part Apple documents.
    static func readable(_ error: Error) -> Error {
        guard let apple = error as? ASAuthorizationError else { return error }

        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        let detail = underlying.map { " (\($0.domain) \($0.code))" } ?? ""

        switch apple.code {
        case .canceled:
            return AuthError.cancelled
        case .unknown:
            return AuthError.server(
                "Apple couldn't complete the sign-in (1000)\(detail). Check that "
                + "you're connected to the internet, signed in to iCloud in "
                + "Settings, and that Screen Time isn't blocking account changes."
            )
        case .failed:
            return AuthError.server("Apple wouldn't authorise the sign-in (1001)\(detail). Try again.")
        case .invalidResponse:
            return AuthError.server("Apple returned an unusable response (1002)\(detail).")
        case .notHandled:
            return AuthError.server("Apple couldn't handle the sign-in request (1003)\(detail).")
        case .notInteractive:
            return AuthError.server("The sign-in needs the screen unlocked (1005)\(detail).")
        @unknown default:
            return AuthError.server("Apple couldn't sign you in (\(apple.code.rawValue))\(detail).")
        }
    }

    /// The profile row every other table's foreign key points at.
    ///
    /// Throws rather than swallowing: this failing means the account exists in
    /// `auth.users` with nothing behind it, and the first attempt to sync
    /// records would fail on the foreign key with an error nowhere near the
    /// cause. Better to say so while the user is still looking at a sign-in
    /// screen.
    private func upsertProfile(name: PersonNameComponents?) async throws {
        // **`validAccessToken()`, never the stored `accessToken`.**
        //
        // The raw property is what is in memory right now, and it is nil far
        // more often than it looks: a Supabase access token lasts an hour, and a
        // cold launch has none at all until `restoreSession()` has been round the
        // network. `RootView` deliberately decides the first screen from the
        // Keychain rather than from a refresh, so someone can be legitimately
        // signed in, looking at their garden, with this still empty.
        //
        // Guarding on it therefore threw "No session to write a profile with"
        // at a user who had one — and `NameSheet`'s `try?` swallowed the words.
        // The row stayed on "Add your name" and the button looked broken.
        // Every other write in the app already goes through the refreshing
        // accessor; this was the odd one out. Order matters: `userID` is read
        // *after* the await, because that is what sets it on a cold launch.
        guard let accessToken = await validAccessToken(), let userID else {
            // The reason, not a diagnosis. This used to say "no session to write
            // a profile with" unconditionally, which asserts *signed out* — and
            // said it to a phone that simply could not reach Supabase. Three
            // rounds of this investigation went into the auth layer on the
            // strength of that one sentence.
            throw AuthError.server(lastTokenFailure?.message ?? "no session to write a profile with.")
        }

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
        // The raw token here, deliberately, unlike the two writes above.
        // `restoreSession` calls this the moment it has exchanged one, so the
        // token is fresh by construction — and routing it through
        // `validAccessToken()` would let a failed exchange call `restoreSession`
        // from inside itself.
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
        // Refreshing accessor, for the reason spelled out on `upsertProfile`.
        // This one is worse if it fails, not better: it returns silently, so a
        // stale token meant `photos_added_at` never landed and the photo page
        // came back on the next device — the local cache saying "seen" while the
        // column that outlives the install said nothing.
        guard let accessToken = await validAccessToken(), let userID else { return }

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
