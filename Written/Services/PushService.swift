import Foundation
import UIKit
import UserNotifications

/// Registering this device to be told about a like, a match or a message.
///
/// **Asking is the whole design problem, not the plumbing.** iOS lets an app ask
/// once, ever, and a refusal can only be undone in Settings, which nobody
/// visits — so the system dialog is never shown cold. `NotificationPrimer` puts
/// the question in the app's own voice first and only somebody who says yes
/// there is passed to iOS. A "not now" spends nothing and is asked again in
/// three days.
///
/// **It has been in two wrong places already.** First the first admirer, which
/// put the question one event *after* the like that would have used it — so
/// nobody's first notification could ever arrive, and a tester reported being
/// asked only when their first message came in. Then bare on arriving at
/// Explore, which spent the single attempt cold and landed a system alert on
/// the discovery feed at the moment somebody had tapped to see it.
///
/// **And it stays nowhere near the Health sheet.** This project lost a week to
/// two permission prompts colliding: the location fix firing from
/// `DashboardView.task` is what stopped HealthKit's sheet drawing at all,
/// because HealthKit hosts a remote view and cannot present over anything else.
/// Any permission asked on `.task`/`.onAppear` here must be gated on that tab's
/// `isVisible`; this one hangs off a tab change, and neither Explore nor Chat is
/// where a source gets connected.
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

    /// Whether the primer should be shown at all.
    ///
    /// Only for somebody iOS has never asked. Anybody who has answered — either
    /// way — is left alone: a yes needs nothing, and a no is a decision this app
    /// does not re-open with a sheet it controls.
    ///
    /// **The "not now" is deliberately cheap.** Declining the *primer* spends
    /// nothing, because the system dialog was never shown, so the question can
    /// be put again later. That is the whole reason the primer exists.
    func shouldPrime() async -> Bool {
        guard !hasAskedThisLaunch else { return false }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .notDetermined
    }

    /// Whether iOS has been asked and said no.
    ///
    /// **The one state nothing else in the app would ever mention.** A refusal
    /// leaves `device_tokens` empty, so every notification for that person is
    /// reported server-side as `{"sent":0,"note":"no devices"}` — a success,
    /// and indistinguishable from somebody who never installed the app. They
    /// hear about no like and no match, and are told nothing. That is the same
    /// silent-failure shape this codebase has now met seven times, and Chat says
    /// so because of it.
    ///
    /// Distinguished from `.notDetermined`, which the primer handles, and from
    /// `.provisional`, which delivers quietly rather than not at all.
    func isDenied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    /// Records that the primer was declined, so it is not shown again today.
    ///
    /// Not permanent. Somebody who says "not now" is saying not now, and iOS has
    /// not been asked — so the next launch may ask again. `UserDefaults` rather
    /// than memory so the answer survives the app, and account-scoped because it
    /// is a fact about a person rather than about a phone.
    func declinePrimer() {
        UserDefaults.standard.set(Date(), forKey: Self.primerDeclinedKey)
    }

    /// Whether the primer was turned down recently enough to leave alone.
    ///
    /// Three days. Long enough not to nag, short enough that somebody who is
    /// actually using the app is offered it again while it still matters —
    /// and no notification is lost in the meantime that would not have been
    /// lost anyway.
    func wasPrimerDeclinedRecently() -> Bool {
        guard let last = UserDefaults.standard.object(forKey: Self.primerDeclinedKey) as? Date
        else { return false }
        return Date().timeIntervalSince(last) < 3 * 24 * 3600
    }

    private static var primerDeclinedKey: String {
        "notificationPrimerDeclined.\(AccountScope.current)"
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
        // **The token is awaited before the id is read, and that order is the
        // whole point.** `userID` is filled in by the refresh, so reading it
        // first reports "not signed in" for a session that is merely not
        // restored yet — CLAUDE.md records this as its own recurring bug, and
        // this function was written with it in.
        guard await SupabaseAuth.shared.validAccessToken() != nil,
              let me = await SupabaseAuth.shared.userID else {
            lastError = "Not signed in."
#if DEBUG
            print("[push] register: no session")
#endif
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
#if DEBUG
            print("[push] register: stored")
#endif
        } catch {
            lastError = error.localizedDescription
#if DEBUG
            // **Nothing else in the app would ever say this.** A failed upload
            // leaves no row, and a missing row is indistinguishable from a
            // person who declined — the fifth instance of that shape here.
            print("[push] register FAILED: \(error)")
            print("[push] sent user_id: \(me)")
#endif
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

    /// Puts the unread count on the app icon.
    ///
    /// **Set from the server on every push and corrected by the app.** APNs
    /// carries a `badge` with each message notification, which is what keeps the
    /// number right while the app is closed — the only time anybody looks at it.
    /// The app then recomputes on opening Chat, on reading a thread, and on
    /// coming back to the foreground, because the server cannot know when
    /// somebody has read something until they have.
    ///
    /// **A failed count must never reach here.** `ChatService.unreadCount`
    /// answers `nil` rather than 0 for a request it could not make, and 0 clears
    /// the badge — so a dropped request would quietly hide waiting messages.
    func setBadge(_ count: Int) async {
        await MainActor.run {
            UNUserNotificationCenter.current().setBadgeCount(max(0, count))
        }
    }

    /// Asks the server how many are waiting and draws it.
    ///
    /// Silent on failure, leaving whatever the last push set — a stale number
    /// beats a wrong one, and the next notification or the next visit corrects
    /// it either way.
    func refreshBadge() async {
        guard let count = await ChatService.shared.unreadCount() else { return }
        await setBadge(count)
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
