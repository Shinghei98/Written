import Foundation

/// Where a tapped notification wants to go.
///
/// **One published value rather than a call into the view tree**, because the
/// tap arrives somewhere with no view tree to call. `PushDelegate` runs in
/// `UIApplicationDelegate`, and on a cold launch the notification is delivered
/// *during* start-up — before `AppShell` exists, sometimes before `RootView` has
/// decided which screen it is. So the tap records an intention and the screens
/// consume it when they are ready, which is the same shape `restoredStep` uses
/// to survive a force-quit.
///
/// It is deliberately not part of `Route`. `Route` answers "which of five
/// screens is the app on" and must stay decidable synchronously at launch; this
/// answers "and then go here", which can wait for a network load.
@MainActor
final class NotificationRouter: ObservableObject {

    static let shared = NotificationRouter()

    enum Destination: Equatable {
        /// A match. The conversation exists but its id is not in the payload —
        /// the like row has no conversation on it — so this lands on the list,
        /// where it will be at the top.
        case chatList
        /// A new like. Admirers rather than a thread, because there is no
        /// conversation until it is accepted.
        case admirers
        /// A message, by conversation id.
        case conversation(String)
    }

    /// Cleared by whoever acts on it. Nil the rest of the time.
    @Published var pending: Destination?

    private init() {}

    /// Reads a tapped notification's payload.
    ///
    /// Falls back to the chat list rather than doing nothing: a tap is an
    /// explicit request to see *something*, and an app that opens where it was
    /// left reads as the tap having missed.
    func receive(userInfo: [AnyHashable: Any]) {
        switch userInfo["category"] as? String {
        case "message":
            if let thread = userInfo["thread"] as? String, !thread.isEmpty {
                pending = .conversation(thread)
            } else {
                pending = .chatList
            }
        case "like":
            pending = .admirers
        default:
            pending = .chatList
        }
    }
}
