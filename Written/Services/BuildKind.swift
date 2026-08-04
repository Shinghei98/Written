import Foundation

/// Which kind of build this is, for the one thing that turns on it: how much a
/// failure is allowed to say.
///
/// **A tester's screenshot is the only instrument this project has**, and it
/// has twice been unable to answer the question it was sent to answer. Health
/// failures render one friendly sentence in Release while the underlying stage,
/// elapsed time and error code sit behind `#if DEBUG` — so "HealthKit returned
/// an error" and "we gave up waiting" arrive looking identical, and separating
/// them cost two rounds of reading source and produced two different answers.
///
/// TestFlight is Release, which is why the detail was missing exactly where it
/// was needed. This is the distinction that was missing: a beta build may talk.
///
/// The check is Apple's own — a build installed from TestFlight carries a
/// *sandbox* receipt, while one from the App Store carries `receipt`. It costs
/// nothing at runtime and needs no build setting, no scheme and no `-D` flag to
/// be kept in step with six copies of `CURRENT_PROJECT_VERSION`.
enum BuildKind {

    /// True for a TestFlight build, false in the simulator, in Debug on a
    /// device, and in anything shipped from the App Store.
    ///
    /// Simulator builds have no receipt at all, so this is false there — which
    /// is correct and worth knowing when checking the behaviour locally: use a
    /// Debug build, where `DEBUG` covers the same branch.
    ///
    /// **`appStoreReceiptURL` is deprecated and is still the right call here.**
    /// Its replacement, StoreKit 2's `AppTransaction.shared`, is `async` and can
    /// reach the network on first use — which is exactly what must not happen
    /// on the path that draws an error message. This reads a URL and compares a
    /// filename; there is nothing to fail and nothing to wait for. Revisit only
    /// if the property is removed outright rather than merely deprecated.
    @available(iOS, deprecated: 100000.0)
    static let isBeta: Bool = {
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    }()

    /// Whether a failure may carry its technical detail on screen.
    ///
    /// Debug for development, TestFlight for the people who report bugs, and
    /// nothing in a shipped build — `[com.apple.healthkit 100]` is not a
    /// sentence to put in front of somebody who just wanted to connect Health.
    static var showsDiagnostics: Bool {
        #if DEBUG
        return true
        #else
        return isBeta
        #endif
    }
}
