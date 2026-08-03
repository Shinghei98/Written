import XCTest

/// Does tapping Apple Health in the picker ever *finish*?
///
/// **This exists because the bug is invisible on any device that has already
/// answered.** HealthKit shows its permission sheet once per app, ever, so the
/// developer's phone — and every simulator that has run this once — returns from
/// `requestAuthorization` instantly with nothing to present. Only a device that
/// has never been asked takes the path that hangs, which is why a first-time
/// tester found it and weeks of testing did not.
///
/// So this test is only meaningful on an **erased** simulator:
///
///     xcrun simctl shutdown <device> ; xcrun simctl erase <device> ; xcrun simctl boot <device>
///
/// Run twice without erasing and the second run passes for the wrong reason.
///
/// It drives the picker with a real tap rather than `-connect health`. That
/// launch argument starts the distillation without ever presenting the picker,
/// and the failure lives in the gap between the picker dismissing and HealthKit
/// presenting — so the argument that exists to avoid tapping is the one thing
/// that cannot reproduce this.
final class HealthPermissionTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// Tap Apple Health, and require the app to reach *some* resolved state.
    ///
    /// Deliberately indifferent to which one. A permission sheet is the right
    /// answer and a visible error is an acceptable one; what is being asserted is
    /// that the spinner ends at all, because "it just keeps loading and never
    /// ended" was the report.
    func testConnectingHealthResolvesRatherThanSpinning() {
        let app = XCUIApplication()
        // `-solo 1` for the reason the layout audit documents: every tab is
        // mounted, and XCUITest honours none of the three ways the other four are
        // hidden.
        app.launchArguments = ["-route", "home", "-pick", "lifestyle", "-solo", "1"]
        app.launch()

        let row = app.buttons["Apple Health"].firstMatch
        XCTAssertTrue(
            row.waitForExistence(timeout: 15),
            "the lifestyle source picker never appeared — check -pick lifestyle still opens it"
        )
        row.tap()

        // Longer than `HealthKitDistiller.stageTimeout` (20s) on purpose: if the
        // timeout works, the failure message arrives inside it, and if it does not
        // this waits long enough to say so rather than racing it.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if resolved(app) { return }
            Thread.sleep(forTimeInterval: 0.5)
        }

        XCTFail(
            "30s after tapping Apple Health there is no permission sheet and no "
                + "error — the authorization request never returned.\n"
                + describe(app)
        )
    }

    /// Either HealthKit put its sheet up, or the app gave up and said something.
    private func resolved(_ app: XCUIApplication) -> Bool {
        // The authorization sheet is a remote view hosted in our own process, so
        // it is reachable through `app` rather than through springboard. Several
        // spellings, because the wording is Apple's and not ours to rely on.
        for label in ["Allow", "Turn On All", "Health Access", "Don't Allow"] {
            if app.buttons[label].exists || app.staticTexts[label].exists { return true }
        }
        // Our own failure copy. Matched on stems rather than in full, so
        // rewording a sentence does not silently stop this test noticing an
        // error it should have caught — but the stems have to be *kept*, and
        // one round of this test already reported a correctly-drawn message as
        // a hang because "has already asked" matched none of them. The card's
        // own headline is the cheapest guard against that happening again: it
        // is the same words whatever the message underneath says.
        for stem in [
            "That didn't work",
            "has already asked",
            "Nothing came back", "didn't respond", "timed out", "isn't available"
        ] {
            let predicate = NSPredicate(format: "label CONTAINS[c] %@", stem)
            if app.staticTexts.containing(predicate).firstMatch.exists { return true }
        }
        return false
    }

    /// What was on screen when it gave up — otherwise a failure here says only
    /// that nothing matched, which is the least useful half of the story.
    private func describe(_ app: XCUIApplication) -> String {
        let texts = app.staticTexts.allElementsBoundByIndex
            .prefix(25)
            .map(\.label)
            .filter { !$0.isEmpty }
        return "on screen: " + texts.joined(separator: " | ")
    }
}
