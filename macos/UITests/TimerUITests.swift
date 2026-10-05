import XCTest

/// Timers in the Notch & HUD pane: start a 25 minute Pomodoro, see it ticking in the notch, cancel it.
/// `--ui-test-fresh-settings` gives the app a throwaway settings suite; timers are in memory only, so the
/// user's settings and state are not touched. No sound is checked: XCUITest cannot hear the ping.
final class TimerUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        let path = ProcessInfo.processInfo.environment["SAYSO_APP_PATH"] ?? "\(NSHomeDirectory())/.artifacts/Sayso Notch.app"
        app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchArguments = ["--ui-test-fresh-settings"]
        app.launch()
    }

    override func tearDown() { app.terminate() }

    /// The notch status line for a running focus phase, for example "Focus 24:58 · 0%".
    private var focusLine: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label MATCHES %@", "Focus [0-9]{1,2}:[0-9]{2}.*")).firstMatch
    }

    /// Opens the notch if it is collapsed, and proves it is open so an absent line is not a closed notch.
    private func openNotch() {
        let pill = app.buttons["Open Sayso Dictation workspace"].firstMatch
        if pill.waitForExistence(timeout: 3) { pill.click() }
        XCTAssertTrue(app.buttons["Minimize Sayso workspace"].firstMatch.waitForExistence(timeout: 10), "expanded notch")
    }

    func testPomodoroStartsTicksInTheNotchAndCancelClearsIt() {
        let tab = app.descendants(matching: .any)["studio-tab-notch"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "sidebar tab for Notch & HUD")
        tab.click()
        let start = app.descendants(matching: .any)["timer-start-25"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), "Start 25 minute Pomodoro button")
        start.click()

        let status = app.descendants(matching: .any)["timer-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5), "running timer status in the pane")

        openNotch()
        XCTAssertTrue(focusLine.waitForExistence(timeout: 10), "running Pomodoro label in the notch")
        let first = focusLine.label
        let ticked = NSPredicate(format: "label MATCHES %@ AND label != %@", "Focus [0-9]{1,2}:[0-9]{2}.*", first)
        let later = app.buttons.matching(ticked).firstMatch
        XCTAssertTrue(later.waitForExistence(timeout: 5), "the notch label ticks on the wall clock (first: \(first))")

        let cancel = app.descendants(matching: .any)["timer-cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "Cancel button while the Pomodoro runs")
        cancel.click()
        XCTAssertTrue(start.waitForExistence(timeout: 5), "Start is offered again after cancel")
        XCTAssertFalse(cancel.exists, "Cancel is gone after cancel")

        openNotch()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: focusLine)
        waitForExpectations(timeout: 5)
    }
}
