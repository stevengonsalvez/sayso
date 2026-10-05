import XCTest

/// Settings pane: the Now Playing toggle exists and is off by default. `--ui-test-fresh-settings` gives the app a
/// throwaway settings suite, so the default is checked and the user's settings are not read or written; other app
/// state (history, shortcuts, keychain) is still the user's. The toggle is never flipped, so the module never asks
/// Music or Spotify anything, never launches either app and never triggers the macOS Automation prompt.
final class NowPlayingSettingUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        let path = ProcessInfo.processInfo.environment["SAYSO_APP_PATH"] ?? "\(NSHomeDirectory())/.artifacts/Sayso Notch.app"
        app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchArguments = ["--ui-test-fresh-settings"]
        app.launch()
    }

    override func tearDown() { app.terminate() }

    func testNowPlayingToggleIsPresentAndOffByDefault() {
        let tab = app.descendants(matching: .any)["studio-tab-settings"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "sidebar tab for Settings")
        tab.click()
        let toggle = app.descendants(matching: .any)["settings-now-playing-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Now Playing toggle in Settings")
        XCTAssertEqual(isOn(toggle), false, "Now Playing must be off unless the user turns it on (value: \(String(describing: toggle.value)))")
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
