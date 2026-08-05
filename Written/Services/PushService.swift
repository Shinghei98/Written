import Foundation
import UIKit
import UserNotifications

/// Registering this device to be told about a like, a match or a message.
///
/// **Asking is the whole design problem, not the plumbing.** iOS lets an app ask
/// once, ever — a refusal can only be undone in Settings, which nobody visits —
/// so *when* the question is put decides whether notifications work for that
/// person at all. It is asked on the first admirer: somebody has just been
/// liked, being told sooner next time obviously pays, and there is a name on
/// screen to make it concrete.
///
/// **And it is deliberately nowhere near the Health sheet.** This project has
/// already lost a week to two permission prompts colliding: the location fix
/// firing from `DashboardView.task` is what stopped HealthKit's sheet drawing at
/// all, because HealthKit hosts a remote view and cannot present over anything
/// else. Any permission asked on `.task`/`.onAppear` in this app must be gated
/// on that tab's `isVisible`, and this one is asked from Chat, which is not
/// where Health is connected.
actor PushService {

    static let shared = PushService()

    private(set) var lastError: String?

    /// True once this launch has asked, so a list that reloads every few seconds
    /// does not ask on every pass.
    private var hasAskedThisLaunch = false

    /// **The two APNs hosts are separate namespaces**, and a token belongs to
    /// exactly one of them. A build signed for development mints a *sandbox*
    /// token, which `api.push.apple.com` answers `BadDeviceToken`; TestFlight
    /// and the App Store mint production tokens, which fail the same way at the
    /// sandbox host.
    ///
    /// Decided by `DEBUG` rather than read from the provisioning profile: the
    /// profile is parseable but the answer is already known at compile time, and
    /// a wrong guess here is a notification that silently never arrives.
    static var environment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    /// Asks, once, and registers if allowed.
    ///
    /// Silent about a refusal on purpose. Somebody who says no has answered the
    /// question, and an app that explains why they were wrong is worse than one
    /// that accepts it — the Settings route exists and nagging does not open it.
    func askIfNeeded() async {
        guard !hasAskedThisLaunch else { return }
        hasAskedThisLaunch = true

        let centre = UNUserNotificationCenter.current()
        let settings = await centre.notificationSettings()

        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await centre.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            guard granted else { return }
        case .authorized, .provisional, .ephemeral:
            // Already said yes on some earlier launch. Registering again is the
            // point: the token may have changed since, and nothing tells the app
            // when it does.
            break
        case .denied:
            return
        @unknown default:
            return
        }

        await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
    }

    /// Stores the token APNs handed the app delegate.
    ///
    /// Written on every launch rather than only when it changes. A token is not
    /// stable — a restore from backup, an iOS update or a long silence can all
    /// mint a new one, and the app is never told — so the only reliable strategy
    /// is to say where this device is every time it starts.
    func register(token: String) async {
        guard let me = await SupabaseAuth.shared.userID else {
            lastError = "Not signed in."
            return
        }
        do {
            try await PostgREST.insert(
                "rest/v1/device_tokens",
                body: [[
                    "user_id": me,
                    "token": token,
                    "environment": Self.environment,
                    "updated_at": ISO8601DateFormatter().string(from: Date()),
                ]],
                // `merge-duplicates` is safe here, unlike on `likes`: nothing
                // revokes update on this table, so the upsert has the privileges
                // its `on conflict do update` asks for at plan time. Re-launching
                // has to refresh `updated_at`, so ignoring the duplicate would
                // leave a dead row looking current.
                prefer: "resolution=merge-duplicates,return=minimal"
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Re-registers on launch, and **asks nothing**.
    ///
    /// Split from `askIfNeeded` rather than folded into it, because the two run
    /// in different places for opposite reasons. This one runs at launch, where a
    /// prompt must never appear — it is the shape of thing that stopped
    /// HealthKit's sheet drawing. It exists because a token is not stable: a
    /// restore from backup, an iOS update or a long silence can mint a new one
    /// and the app is never told, so somebody who granted months ago is only
    /// reachable if every launch says where they are.
    func registerIfAlreadyAllowed() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional || status == .ephemeral else { return }
        await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
    }

    /// Records why APNs would not issue a token.
    ///
    /// Kept rather than logged, because the one cause worth naming is
    /// infrastructural and silent: a missing `aps-environment`, stripped at
    /// packaging exactly as HealthKit's entitlement has been on this project
    /// twice. It reads as `no valid "aps-environment" entitlement string found`
    /// and nothing else in the app would ever say so.
    func registrationFailed(_ message: String) {
        lastError = message
    }

    /// Forgets this device on sign-out.
    ///
    /// **Not optional tidiness.** The next notification for this account would
    /// otherwise arrive on a phone somebody else is now signed into — the same
    /// class of leak as the OAuth refresh token that used to survive a sign-out
    /// and hand the next person a stranger's YouTube.
    func forget(token: String) async {
        guard let me = await SupabaseAuth.shared.userID else { return }
        _ = try? await PostgREST.delete(
            "rest/v1/device_tokens",
            query: ["user_id": "eq.\(me)", "token": "eq.\(token)"]
        )
    }
}
