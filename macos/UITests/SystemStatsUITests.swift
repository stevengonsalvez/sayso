import XCTest

/// System section of the Notch & HUD pane: CPU, memory, battery and disk rows each show a value read from this Mac.
/// `--ui-test-fresh-settings` gives the app a throwaway settings suite, so the user's settings are not read or
/// written. The module only reads counters, so nothing on the Mac is changed.
final class SystemStatsUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        let path = ProcessInfo.processInfo.environment["SAYSO_APP_PATH"] ?? "\(NSHomeDirectory())/.artifacts/Sayso Notch.app"
        app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchArguments = ["--ui-test-fresh-settings"]
        app.launch()
    }

    override func tearDown() { app.terminate() }

    /// The text a row shows; SwiftUI exposes a Text as its value or its label depending on the macOS release.
    private func text(of element: XCUIElement) -> String {
        (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
    }

    func testTheSystemSectionShowsAValueForEachRow() {
        // The notch starts collapsed, so only the open pane can speed sampling up: the CPU percent below then
        // proves the pane counts as watching.
        XCTAssertTrue(app.buttons["Open Sayso Dictation workspace"].firstMatch.waitForExistence(timeout: 10), "collapsed notch pill")
        let tab = app.descendants(matching: .any)["studio-tab-notch"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "sidebar tab for Notch & HUD")
        tab.click()

        let shapes = [
            "system-stats-cpu": #"^([0-9]{1,3}%|Measuring)$"#,
            "system-stats-memory": #"^[0-9]{1,3}% used, pressure (normal|warning|critical)$"#,
            "system-stats-battery": #"^([0-9]{1,3}%(, (plugged in|on battery))?|No battery)$"#,
            "system-stats-disk": #"^[0-9]+\.[0-9] GB free$"#,
        ]
        var seen: [String: String] = [:]
        for (id, shape) in shapes.sorted(by: { $0.key < $1.key }) {
            let row = app.descendants(matching: .any)[id]
            XCTAssertTrue(row.waitForExistence(timeout: 10), id)
            let value = text(of: row)
            XCTAssertFalse(value.isEmpty, "\(id) shows a value")
            XCTAssertNotNil(value.range(of: shape, options: .regularExpression), "\(id) reads \(value)")
            seen[id] = value
        }

        // While the pane is open the module samples every 5 s, so the second sample turns Measuring into a percent.
        let cpu = app.descendants(matching: .any)["system-stats-cpu"]
        let percent = NSPredicate { element, _ in
            guard let element = element as? XCUIElement else { return false }
            return self.text(of: element).hasSuffix("%")
        }
        expectation(for: percent, evaluatedWith: cpu)
        waitForExpectations(timeout: 15)
        seen["system-stats-cpu"] = text(of: cpu)
        // Logged so the proof ledger can quote what was shown, not only that a pattern matched.
        print("SYSTEM-STATS-OBSERVED " + seen.sorted { $0.key < $1.key }.map { "\($0.key)=\"\($0.value)\"" }.joined(separator: " "))
    }
}
