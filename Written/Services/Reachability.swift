import Foundation
import Network

/// Whether this device has a network at all.
///
/// **Observed, not inferred from failed requests.** A request can fail for a
/// dozen reasons — a revoked token, a policy refusal, a server having a bad day
/// — and a banner that said "you're offline" for any of them would be lying most
/// of the time it appeared. `NWPathMonitor` reports the actual state of the
/// interfaces, so the banner claims only what is true.
///
/// `Network` is a system framework, so this costs no dependency. That matters
/// here: the project has none and the one place it nearly took one — Realtime —
/// was turned down for exactly that reason.
///
/// **What the monitor cannot tell you** is whether the internet is reachable,
/// only whether an interface is up. A café wifi that requires a login reports
/// satisfied while every request fails — and so does a phone whose connection
/// has quietly stopped routing. That gap is not hypothetical: it hid an entirely
/// dead connection behind three rounds of debugging, because the banner that
/// exists to say "you're offline" stayed silent while every server write failed
/// and the app blamed the session instead.
///
/// So `verify()` closes it by asking Supabase directly. It is deliberately *not*
/// a poll — that would be a request every few seconds forever to answer a
/// question that almost always has the same answer. It runs when something has
/// actually failed, which is the only moment the answer matters.
@MainActor
final class Reachability: ObservableObject {

    static let shared = Reachability()

    /// Starts true rather than false.
    ///
    /// The monitor's first callback takes a moment, and defaulting to offline
    /// would flash the banner on every launch — the same flash-of-wrong-state
    /// that `RootView` documents for the sign-in screen, in miniature.
    @Published private(set) var isOnline = true

    /// The two halves of the answer, kept apart.
    ///
    /// `isOnline` is their conjunction rather than either one, because the two
    /// go stale differently. The path is authoritative and self-correcting; the
    /// probe is a single measurement that was true once. Folding a failed probe
    /// straight into `isOnline` would leave the banner up forever, since the
    /// monitor only fires when the path *changes* and a still-satisfied path
    /// never would — so a moment's outage would read as permanently offline.
    private var pathIsUp = true
    private var probeSucceeded = true

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                self.pathIsUp = up
                // A new path deserves a clean slate: whatever the last probe
                // found was about the old one.
                self.probeSucceeded = true
                self.recompute()
            }
        }
        monitor.start(queue: DispatchQueue(label: "written.reachability"))
    }

    /// Asks Supabase whether it is actually reachable, and updates the banner.
    ///
    /// Call after something has failed. `auth/v1/health` is the cheapest
    /// endpoint that proves the whole path — DNS, TLS and the project being
    /// awake — and it needs no session, so it works precisely when nothing else
    /// does.
    func verify() async {
        var request = URLRequest(url: AppConfig.supabaseURL.appendingPathComponent("auth/v1/health"))
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        // Short: this runs while somebody is looking at a failed edit, and the
        // default 60 seconds would answer long after they had given up.
        request.timeoutInterval = 6
        // The point is to test the network, so a cached 200 would defeat it.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            // Any answer at all proves reachability. Even a 401 means the
            // request arrived, which is the only question being asked.
            probeSucceeded = (response as? HTTPURLResponse) != nil
        } catch {
            probeSucceeded = false
        }
        recompute()
    }

    private func recompute() {
        let online = pathIsUp && probeSucceeded
        guard isOnline != online else { return }
        isOnline = online
    }
}
