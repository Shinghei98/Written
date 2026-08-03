import XCTest

/// Does the chat row actually swipe?
///
/// **This exists because a screenshot could not answer it.** The open state was
/// checked by forcing it from the launch line (`-chat swiped`), which proves the
/// buttons are drawn in the right order and proves nothing whatever about the
/// gesture that is supposed to reveal them — and the gesture was the part that
/// was broken. `simctl` sends taps and no drags, so XCUITest is the only thing
/// here that can put a finger on the glass.
///
/// Unlike `LayoutAuditTests` this one asserts. It is a single behaviour with a
/// yes or no answer, not a sweep whose findings are for a person to weigh.
final class SwipeActionsTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchChat() -> XCUIApplication {
        let app = XCUIApplication()
        // `-solo 1` for the reason the audit documents: every tab is mounted and
        // XCUITest honours none of the three ways the other four are hidden, so
        // without it "Unmatch" could be found on a screen nobody is looking at.
        app.launchArguments = ["-route", "home", "-tab", "chat", "-chat", "sample", "-solo", "1"]
        app.launch()
        Thread.sleep(forTimeInterval: 3)
        return app
    }

    func testSwipingARowRevealsUnmatchThenReport() {
        let app = launchChat()

        let row = app.staticTexts["Inés"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the sample chat list never drew")

        XCTAssertFalse(app.staticTexts["Unmatch"].exists, "the buttons are showing with no swipe")

        // From the row itself, leftward. `press(forDuration:thenDragTo:)` rather
        // than `swipeLeft()`: a swipe is a flick, and a flick that the scroll
        // view claims looks identical to a gesture that never fired. A slow drag
        // with a hold at the start is unambiguous, and it is also the thing a
        // person does.
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: -220, dy: 0))
        start.press(forDuration: 0.1, thenDragTo: end)
        Thread.sleep(forTimeInterval: 1)

        XCTAssertTrue(app.staticTexts["Unmatch"].exists, "the swipe revealed nothing")
        XCTAssertTrue(app.staticTexts["Report"].exists, "Report did not come with it")

        // Order, not just presence. Unmatch has to clear the edge first.
        let unmatch = app.staticTexts["Unmatch"].frame
        let report = app.staticTexts["Report"].frame
        XCTAssertLessThan(unmatch.minX, report.minX, "Report is revealed before Unmatch")
    }

    /// The other half of the same gesture: the list must still scroll.
    ///
    /// A row that swipes and a list that scrolls are one question, because the
    /// obvious way to make the first work is to take the drag away from the
    /// scroll view.
    func testTheListStillScrolls() {
        let app = launchChat()

        let first = app.staticTexts["Inés"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        let before = first.frame.minY

        app.swipeUp()
        Thread.sleep(forTimeInterval: 1)

        XCTAssertNotEqual(before, first.frame.minY, accuracy: 0.5, "the list did not scroll")
        XCTAssertFalse(app.staticTexts["Unmatch"].exists, "a vertical drag opened a row")
    }
}
