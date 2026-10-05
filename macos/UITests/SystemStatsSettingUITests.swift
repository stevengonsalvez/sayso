import XCTest

/// Settings pane: the System stats toggle exists and is on by default; turning it off leaves the System rows in
/// Notch & HUD in place, reading Off, and turning it on again brings the figures back. `--ui-test-fresh-settings` gives the app a throwaway settings suite wiped at
/// launch, so the only setting ever flipped is the throwaway one; the user's settings are not read or written. Other
/// app state (history, shortcuts, keychain) is still the user's. The module only reads counters either way.
final class SystemStatsSettingUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        let path = ProcessInfo.processInfo.environment["SAYSO_APP_PATH"] ?? "\(NSHomeDirectory())/.artifacts/Sayso Notch.app"
        app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchArguments = ["--ui-test-fresh-settings"]
        app.launch()
    }

    override func tearDown() { app.terminate() }

    func testSystemStatsToggleIsPresentAndOnByDefault() {
        let toggle = openSettingsToggle()
        XCTAssertEqual(isOn(toggle), true, "System stats were always on, so they stay on until the user turns them off (value: \(String(describing: toggle.value)))")
    }

    /// The pane says Off only when the module is really stopped, so this fails if the setting stops reaching the
    /// module, and the round trip fails if turning it back on does not restart sampling.
    func testTurningTheThrowawaySettingOffShowsTheSystemRowsAsOffAndOnAgainShowsFigures() {
        let toggle = openSettingsToggle()
        XCTAssertEqual(isOn(toggle), true, "starts on (value: \(String(describing: toggle.value)))")
        toggle.click()
        XCTAssertEqual(isOn(toggle), false, "the click turned the throwaway setting off (value: \(String(describing: toggle.value)))")

        openNotchPane()
        let notice = app.descendants(matching: .any)["system-stats-off"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "the System section says the stats are off")
        for id in Self.rowShapes.keys.sorted() {
            let row = app.descendants(matching: .any)[id]
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(id) is still shown")
            XCTAssertEqual(text(of: row), "Off", "\(id) reads Off, not a stale figure")
        }

        let again = openSettingsToggle()
        again.click()
        XCTAssertEqual(isOn(again), true, "the click turned the throwaway setting back on (value: \(String(describing: again.value)))")
        openNotchPane()
        for (id, shape) in Self.rowShapes.sorted(by: { $0.key < $1.key }) {
            let row = app.descendants(matching: .any)[id]
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(id) is shown")
            let figure = NSPredicate { element, _ in
                guard let element = element as? XCUIElement else { return false }
                return self.text(of: element).range(of: shape, options: .regularExpression) != nil
            }
            expectation(for: figure, evaluatedWith: row)
            waitForExpectations(timeout: 15)
        }
        XCTAssertFalse(notice.exists, "the off notice is gone once sampling runs again")
    }

    private static let rowShapes = [
        "system-stats-cpu": #"^([0-9]{1,3}%|Measuring)$"#,
        "system-stats-memory": #"^[0-9]{1,3}% used, pressure (normal|warning|critical)$"#,
        "system-stats-battery": #"^([0-9]{1,3}%(, (plugged in|on battery))?|No battery)$"#,
        "system-stats-disk": #"^[0-9]+\.[0-9] GB free$"#,
    ]

    private func openNotchPane() {
        let tab = app.descendants(matching: .any)["studio-tab-notch"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "sidebar tab for Notch & HUD")
        tab.click()
    }

    private func openSettingsToggle() -> XCUIElement {
        let tab = app.descendants(matching: .any)["studio-tab-settings"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "sidebar tab for Settings")
        tab.click()
        let toggle = app.descendants(matching: .any)["settings-system-stats-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "System stats toggle in Settings")
        return toggle
    }

    /// The text a row shows; SwiftUI exposes a Text as its value or its label depending on the macOS release.
    private func text(of element: XCUIElement) -> String {
        (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
    }

    /// macOS reports a toggle's value as a number or a string depending on its style; nil means unreadable,
    /// so the test cannot pass by failing to read the value.
    private func isOn(_ toggle: XCUIElement) -> Bool? {
        switch toggle.value {
        case let number as NSNumber: number.boolValue
        case let text as String where text == "0" || text == "1": text == "1"
        default: nil
        }
    }
}
