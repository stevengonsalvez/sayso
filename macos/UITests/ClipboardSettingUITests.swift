import XCTest

/// Settings pane: the clipboard module toggle exists and is off by default. Never flips it, so the user's
/// real settings are left untouched.
final class ClipboardSettingUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        let path = ProcessInfo.processInfo.environment["SAYSO_APP_PATH"] ?? "\(NSHomeDirectory())/.artifacts/Sayso Notch.app"
        app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launch()
    }

    override func tearDown() { app.terminate() }

    func testClipboardToggleIsPresentAndOffByDefault() {
        let tab = app.descendants(matching: .any)["studio-tab-settings"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "sidebar tab for Settings")
        tab.click()
        let toggle = app.descendants(matching: .any)["settings-clipboard-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "clipboard toggle in Settings")
        XCTAssertEqual(isOn(toggle), false, "clipboard module must be off unless the user turns it on (value: \(String(describing: toggle.value)))")
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
