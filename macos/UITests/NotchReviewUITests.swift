import XCTest

/// Notch review card. `--ui-test-review` makes the app raise a synthetic critical Control review,
/// with no pending desktop step, so Approve and Deny cannot act on the user's desktop.
final class NotchReviewUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        let path = ProcessInfo.processInfo.environment["SAYSO_APP_PATH"] ?? "\(NSHomeDirectory())/.artifacts/Sayso Notch.app"
        app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchArguments = ["--ui-test-review"]
        app.launch()
    }

    override func tearDown() { app.terminate() }

    private func button(prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    /// The collapsed pill does not auto-expand for a review, so the user opens it first.
    private func expandNotch() {
        let pill = app.buttons["Open Sayso Dictation workspace"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 15), "collapsed notch pill")
        pill.click()
    }

    func testReviewCardOffersExplicitApproveAndDeny() {
        expandNotch()
        XCTAssertTrue(button(prefix: "Approve").waitForExistence(timeout: 15), "Approve button on the review card")
        XCTAssertTrue(button(prefix: "Deny").exists, "Deny button on the review card")
    }

    func testDenyDismissesTheReviewCard() {
        expandNotch()
        let deny = button(prefix: "Deny")
        XCTAssertTrue(deny.waitForExistence(timeout: 15))
        deny.click()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: button(prefix: "Deny"))
        waitForExpectations(timeout: 10)
    }
}
