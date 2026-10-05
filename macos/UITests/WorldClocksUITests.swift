import XCTest

/// World clocks in the Notch & HUD pane: add Tokyo, see its time in the list and in the open notch, remove it.
/// `--ui-test-fresh-settings` gives the app a throwaway settings suite, wiped at launch, that also holds the
/// world clocks list, so the user's own list is never read or written.
final class WorldClocksUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        let path = ProcessInfo.processInfo.environment["SAYSO_APP_PATH"] ?? "\(NSHomeDirectory())/.artifacts/Sayso Notch.app"
        app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchArguments = ["--ui-test-fresh-settings"]
        app.launch()
    }

    override func tearDown() { app.terminate() }

    /// The notch line for the first clock, for example "Tokyo 21:04" or "Tokyo 9:04 PM +1d".
    private var notchLine: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label MATCHES %@", "Tokyo [0-9]{1,2}:[0-9]{2}.*")).firstMatch
    }

    /// Opens the notch if it is collapsed, and proves it is open so an absent line is not a closed notch.
    /// Matched by label: SwiftUI gives the minimize button its symbol name as identifier.
    private func openNotch() {
        let pill = app.buttons["Open Sayso Dictation workspace"].firstMatch
        if pill.waitForExistence(timeout: 3) { pill.click() }
        let minimize = app.buttons.matching(NSPredicate(format: "label == %@", "Minimize Sayso workspace")).firstMatch
        XCTAssertTrue(minimize.waitForExistence(timeout: 10), "expanded notch")
    }

    func testAddingTokyoListsItsTimeAndRemovingItClearsIt() {
        let tab = app.descendants(matching: .any)["studio-tab-notch"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "sidebar tab for Notch & HUD")
        tab.click()
        for id in ["world-clocks-add-Europe/London", "world-clocks-add-America/New_York", "world-clocks-add-Asia/Kolkata"] {
            XCTAssertTrue(app.descendants(matching: .any)[id].waitForExistence(timeout: 5), id)
        }
        let add = app.descendants(matching: .any)["world-clocks-add-Asia/Tokyo"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "quick add Tokyo button")
        let list = app.descendants(matching: .any)["world-clocks-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 5), "world clocks list")
        let row = list.descendants(matching: .any)["world-clocks-row-Asia/Tokyo"]
        XCTAssertFalse(row.exists, "fresh settings start with no clocks")

        add.click()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "a Tokyo row in the list")
        let label = (row.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? row.label
        let shape = #"^Tokyo [0-9]{1,2}:[0-9]{2}( [AP]M)?( [+-][0-9]+d)?$"#
        XCTAssertNotNil(label.range(of: shape, options: .regularExpression), "Tokyo row shows a time, got \(label)")

        openNotch()
        XCTAssertTrue(notchLine.waitForExistence(timeout: 10), "Tokyo time in the open notch")
        // Logged so the proof ledger can quote what was actually shown, not only that a pattern matched.
        print("WORLD-CLOCKS-OBSERVED row=\"\(label)\" notch=\"\(notchLine.label)\"")

        let remove = app.descendants(matching: .any)["world-clocks-remove-Asia/Tokyo"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "Remove button for Tokyo")
        remove.click()

        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: row)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(remove.exists, "Remove is gone with the row")

        openNotch()
        expectation(for: gone, evaluatedWith: notchLine)
        waitForExpectations(timeout: 5)
    }
}
