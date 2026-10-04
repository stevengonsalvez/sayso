import XCTest

/// Drives the packaged app (`.artifacts/Sayso Notch.app`, bundle ai.sayso.notch). No other Sayso may be running.
final class StudioNavigationUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        let path = ProcessInfo.processInfo.environment["SAYSO_APP_PATH"] ?? "\(NSHomeDirectory())/.artifacts/Sayso Notch.app"
        app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launch()
    }

    override func tearDown() { app.terminate() }

    func testVoiceOutputTabOpensItsPane() {
        let tab = app.descendants(matching: .any)["studio-tab-tts"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "sidebar tab for TTS")
        tab.click()
        XCTAssertTrue(app.descendants(matching: .any)["studio-pane-tts"].waitForExistence(timeout: 5))
    }
}
