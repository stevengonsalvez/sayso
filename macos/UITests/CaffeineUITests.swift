import XCTest

/// Caffeine in the Notch & HUD pane: start a 15 minute session, see it running, stop it.
/// `--ui-test-fresh-settings` gives the app a throwaway settings suite; Caffeine sessions live in memory only.
/// The power assertion itself is not visible to XCUITest; check it from outside with `pmset -g assertions`.
final class CaffeineUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        let path = ProcessInfo.processInfo.environment["SAYSO_APP_PATH"] ?? "\(NSHomeDirectory())/.artifacts/Sayso Notch.app"
        app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchArguments = ["--ui-test-fresh-settings"]
        app.launch()
    }

    override func tearDown() { app.terminate() }

    func testFifteenMinutesShowsARunningLabelAndStopClearsIt() {
        let tab = app.descendants(matching: .any)["studio-tab-notch"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "sidebar tab for Notch & HUD")
        tab.click()
        for id in ["caffeine-start-60", "caffeine-start-indefinite"] {
            XCTAssertTrue(app.descendants(matching: .any)[id].waitForExistence(timeout: 5), id)
        }
        let start = app.descendants(matching: .any)["caffeine-start-15"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), "Keep awake 15 min button")
        start.click()

        let status = app.descendants(matching: .any)["caffeine-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5), "running Caffeine status in the pane")
        let label = (status.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? status.label
        XCTAssertTrue(label.hasPrefix("Awake · 15 min left") || label.hasPrefix("Awake · 14 min left"), "running label, got \(label)")

        let stop = app.descendants(matching: .any)["caffeine-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "Stop button while Caffeine runs")
        stop.click()

        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: status)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(stop.exists, "Stop is gone after stop")
        // Stays stopped: the session does not come back while the app keeps running.
        XCTAssertFalse(status.waitForExistence(timeout: 2), "Caffeine status returned after stop")
    }
}
