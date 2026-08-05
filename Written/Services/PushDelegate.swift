import SwiftUI
import UIKit
import UserNotifications

/// The app's first `UIApplicationDelegate`, and it exists for exactly one
/// callback.
///
/// `didRegisterForRemoteNotificationsWithDeviceToken` is how APNs hands the app
/// its token, and there is **no SwiftUI equivalent** — no `.onReceive`, no
/// environment value, no async accessor. `UIApplicationDelegateAdaptor` is the
/// only route, which is why a SwiftUI-only app grows a delegate the day it grows
/// notifications.
///
/// It stays this small on purpose. Everything a delegate *could* take over here
/// — launch, lifecycle, background time — is already owned by `AppShell` and
/// `RootView`, and a second place answering the same questions is how they come
/// to disagree.
final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// The token this launch was given, kept so sign-out can withdraw it.
    ///
    /// Nothing else can produce it: APNs tells the app once per launch and there
    /// is no way to ask again. A sign-out with no token to hand `forget` would
    /// leave the row in place and send the next notification for this account to
    /// a phone somebody else is now signed into.
    static private(set) var currentToken: String?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Set here rather than lazily, because a notification tapped from a cold
        // launch is delivered *during* start-up — a delegate assigned later has
        // already missed it.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // APNs hands over 32 raw bytes; the wire format is lowercase hex.
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Self.currentToken = token
#if DEBUG
        // Printed unconditionally rather than behind `-push ask`, because the
        // moment it is wanted is rarely the moment it was asked for — and it
        // costs one line in a console nobody ships. Paste it into Apple's Push
        // Notifications Console to prove the entitlement, the key and the
        // environment before any of our own machinery is involved.
        print("[push] device token: \(token)")
        print("[push] environment: \(PushService.environment)")
#endif
        Task { await PushService.shared.register(token: token) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // The usual cause is the one this project has already been bitten by
        // twice with HealthKit: a missing entitlement, stripped at packaging
        // rather than absent from the `.entitlements` file. It reads as
        // `no valid "aps-environment" entitlement string found`.
        Task { await PushService.shared.registrationFailed(error.localizedDescription) }
    }

    /// Shows a banner even while the app is open.
    ///
    /// Without this, iOS suppresses foreground notifications entirely — which
    /// during testing is indistinguishable from the notification never being
    /// sent, and that is the failure mode this whole feature is hardest to
    /// debug through.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }
}
