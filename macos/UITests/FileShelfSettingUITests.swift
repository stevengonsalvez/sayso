import XCTest

/// Settings pane: the file shelf toggle exists and is off by default. Launches with a throwaway settings suite
/// and never flips the toggle, so the user's real settings are neither read nor changed.
final class FileShelfSettingUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        let path = ProcessInfo.processInfo.environment["SAYSO_APP_PATH"] ?? "\(NSHomeDirectory())/.artifacts/Sayso Notch.app"
        app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchArguments = ["--ui-test-fresh-settings"]
        app.launch()
    }

    override func tearDown() { app.terminate() }

    func testFileShelfToggleIsPresentAndOffByDefault() {
        let tab = app.descendants(matching: .any)["studio-tab-settings"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "sidebar tab for Settings")
        tab.click()
        let toggle = app.descendants(matching: .any)["settings-file-shelf-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "file shelf toggle in Settings")
        XCTAssertEqual(isOn(toggle), false, "file shelf must be off unless the user turns it on (value: \(String(describing: toggle.value)))")
        XCTAssertFalse(app.descendants(matching: .any)["settings-file-shelf-add"].exists, "shelf controls only show while it is on")
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
