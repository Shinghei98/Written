import XCTest

/// Dumps the accessibility tree of every reachable screen, so a script can do
/// the geometry.
///
/// **Why a frame dump rather than screenshots.** A screenshot proves a screen
/// looked right where somebody looked. The badge overlap that prompted all of
/// this was invisible on a 17 Pro and obvious on an SE, and was only found
/// because the badges were *measured* on both. This does the same thing for
/// every widget on every page at once: positions and sizes as numbers, which a
/// script can check for intersection, for falling off the screen, and for text
/// being clamped.
///
/// **It reuses the app's existing debug vocabulary and adds no app code.** iOS
/// parses `-key value` launch arguments into `UserDefaults`, which is exactly
/// what `DebugLaunch` reads — so `-route home -stage 4` here means what it means
/// on a `simctl launch` command line. Those flags live behind `#if DEBUG`, so
/// this must run against a Debug build.
///
/// Discovery is deliberately absent: it has no sample-data path and needs a real
/// signed-in session, so it cannot be audited this way. That gap is real and is
/// reported rather than papered over.
final class LayoutAuditTests: XCTestCase {

    /// One page, and how to get to it without an account.
    struct Screen {
        let name: String
        let arguments: [String]
        /// How long to let it settle. The plant draws itself over about two
        /// seconds and the badges arrive after it, so a dump taken too early
        /// measures a half-grown tree and reports nonsense.
        var settle: TimeInterval = 2.5
    }

    static let screens: [Screen] = [
        Screen(name: "signIn", arguments: ["-route", "signIn"], settle: 2.0),
        Screen(name: "name", arguments: ["-route", "name"], settle: 2.0),
        Screen(name: "photos", arguments: ["-route", "photos"], settle: 2.0),

        // Every illustrated stage. Shared geometry runs through all of them —
        // `leafTilt`, `LeafSpine`, the blade profile — so a change aimed at one
        // routinely lands on another.
        Screen(name: "garden-0", arguments: ["-route", "home", "-stage", "0"], settle: 4.0),
        Screen(name: "garden-1", arguments: ["-route", "home", "-stage", "1"], settle: 4.0),
        Screen(name: "garden-2", arguments: ["-route", "home", "-stage", "2"], settle: 4.0),
        Screen(name: "garden-3", arguments: ["-route", "home", "-stage", "3"], settle: 4.0),
        Screen(name: "garden-4", arguments: ["-route", "home", "-stage", "4"], settle: 4.0),

        // `-tab dashboard`, not `-screen dashboard`. The latter is dead — it
        // survives only to drive `-screen profiles`, and `HomeView` says so:
        // "the dashboard itself is now `-tab dashboard` and needs no delay".
        // Passing the old one silently audited the *garden* twice and called one
        // of them the dashboard.
        Screen(name: "dashboard", arguments: ["-route", "home", "-tab", "dashboard"], settle: 5.0),
        // Two taps in from the dashboard, so it needs the tab *and* the screen
        // flag, plus room for `dashboardDelay` and the slide.
        Screen(name: "profilePreview",
               arguments: ["-route", "home", "-tab", "dashboard", "-screen", "profiles"],
               settle: 6.0),

        Screen(name: "chat", arguments: ["-route", "home", "-tab", "chat", "-chat", "sample"], settle: 3.0),
        Screen(name: "admirers", arguments: ["-route", "home", "-tab", "chat", "-chat", "admirers"], settle: 4.0),
        Screen(name: "conversation", arguments: ["-route", "home", "-tab", "chat", "-chat", "thread"], settle: 4.0),

        Screen(name: "wish", arguments: ["-route", "home", "-tab", "wish"], settle: 2.0),
    ]

    /// The whole sweep is one test rather than one test per screen.
    ///
    /// `xcodebuild` reports a failed test by stopping, and a screen that fails to
    /// launch should not cost the audit every screen after it — so nothing here
    /// asserts. It records, and the analyzer decides what is a defect. A screen
    /// that produced no tree at all shows up as a missing entry, which is itself
    /// the finding.
    func testDumpEveryScreen() throws {
        for screen in Self.screens {
            let app = XCUIApplication()
            // `-solo 1` everywhere. It only means anything inside `AppShell`, and
            // it is what stops the four tabs you are not on being dumped on top
            // of the one you are. See `DebugLaunch.auditsOneTabAtATime`.
            app.launchArguments = screen.arguments + ["-solo", "1"]
            app.launch()

            dismissSystemAlert()
            Thread.sleep(forTimeInterval: screen.settle)
            // Twice: the permission sheet can arrive *after* the first frame,
            // which is exactly how it swallowed two screenshots by hand.
            dismissSystemAlert()

            emit(screen: screen, app: app)
            app.terminate()
        }
    }

    // MARK: - Dumping

    private func emit(screen: Screen, app: XCUIApplication) {
        // The app's own frame rather than the screen's. It is what every child
        // frame is expressed against, so "does this element fall outside the
        // screen" is a containment test in one coordinate space rather than two.
        var payload: [String: Any] = [
            "screen": screen.name,
            "screenBounds": rect(app.frame),
        ]

        // The system keyboard, when one is up.
        //
        // Two different things need it. Its own keys overlap each other freely —
        // that is Apple's layout, not ours, and comparing them produced the only
        // "defects" on the name screen. And the question that *does* matter on a
        // short phone is whether one of our own controls has ended up underneath
        // it, which needs the frame to test against.
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            payload["keyboard"] = rect(keyboard.frame)
        }

        // One round trip for the whole tree. Asking each element for its frame
        // individually is a query apiece and turns a two-second dump into a
        // two-minute one.
        if let snapshot = try? app.snapshot() {
            payload["tree"] = node(snapshot)
        } else {
            payload["error"] = "no snapshot"
        }

        // **The list the analyzer actually uses, and the tree above is context.**
        //
        // `AppShell` mounts all five tabs at once and hides the four you are not
        // on with `.accessibilityHidden(tab != which)` — which is correct, and
        // which `app.snapshot()` ignores: the raw tree walks straight through it
        // and hands back Explore's "Nobody to see yet" sitting on top of the
        // garden. Every one of those is a false overlap, and there were 177 of
        // them on the first run.
        //
        // These queries resolve through accessibility instead, so a hidden tab is
        // genuinely absent.
        //
        // **Asked per type, never as `descendants(matching: .any)`.** That was
        // the first attempt and it killed the accessibility server outright —
        // `(ipc/mig) server died` after 167 seconds. Resolving every descendant
        // of a five-tab hierarchy is far more than the harness will carry. These
        // are the types that own pixels, which is also exactly the set the
        // analyzer judges, so nothing is lost by narrowing to them.
        var elements: [[String: Any]] = []
        let queries: [(String, XCUIElementQuery)] = [
            ("staticText", app.staticTexts),
            ("button", app.buttons),
            ("image", app.images),
            ("textField", app.textFields),
            ("secureTextField", app.secureTextFields),
            ("textView", app.textViews),
            ("switch", app.switches),
        ]
        for (kind, query) in queries {
            for element in query.allElementsBoundByAccessibilityElement {
                var out: [String: Any] = [
                    "kind": kind,
                    "type": element.elementType.rawValue,
                    "frame": rect(element.frame),
                ]
                if !element.label.isEmpty { out["label"] = element.label }
                if !element.identifier.isEmpty { out["id"] = element.identifier }
                elements.append(out)
            }
        }
        payload["elements"] = elements

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else {
            print("LAYOUT_AUDIT_BEGIN\n{\"screen\":\"\(screen.name)\",\"error\":\"encode failed\"}\nLAYOUT_AUDIT_END")
            return
        }

        // Two channels on purpose, because they fail differently. Markers on
        // stdout are trivial to grep out of the build log, but whether a UI test
        // *runner's* stdout reaches `xcodebuild` is not something to bet a
        // two-hour matrix on. The attachment survives in the `.xcresult`
        // regardless and can be pulled with `xcresulttool`.
        print("LAYOUT_AUDIT_BEGIN")
        print(json)
        print("LAYOUT_AUDIT_END")

        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "layout-\(screen.name).json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func node(_ snapshot: XCUIElementSnapshot) -> [String: Any] {
        var out: [String: Any] = [
            "type": snapshot.elementType.rawValue,
            "frame": rect(snapshot.frame),
        ]
        if !snapshot.label.isEmpty { out["label"] = snapshot.label }
        if !snapshot.identifier.isEmpty { out["id"] = snapshot.identifier }
        if let value = snapshot.value as? String, !value.isEmpty { out["value"] = value }
        let children = snapshot.children.map(node)
        if !children.isEmpty { out["children"] = children }
        return out
    }

    private func rect(_ r: CGRect) -> [String: Double] {
        // Rounded to a tenth. Frames come back with floating point dust that
        // makes two identical runs diff against each other for nothing.
        [
            "x": (r.origin.x * 10).rounded() / 10,
            "y": (r.origin.y * 10).rounded() / 10,
            "w": (r.size.width * 10).rounded() / 10,
            "h": (r.size.height * 10).rounded() / 10,
        ]
    }

    // MARK: - Getting the system out of the way

    /// Answers a permission sheet if one is up.
    ///
    /// The location prompt is the one that bites: it appears on a fresh
    /// simulator, `simctl privacy grant`/`deny` did not suppress it, and it
    /// covers the whole page — which is exactly how it ruined two screenshots
    /// taken by hand. Declining is right for an audit: it is the state most
    /// users leave the app in, and it does not change the layout underneath.
    private func dismissSystemAlert() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Don't Allow", "Dont Allow", "Allow While Using App", "OK", "Cancel"] {
            let button = springboard.buttons[label]
            if button.exists && button.isHittable {
                button.tap()
                return
            }
        }
    }
}
