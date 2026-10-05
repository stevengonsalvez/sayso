import XCTest

/// Voice output pane: Speak is gated on having text. Never presses Speak, so no audio plays.
final class VoiceOutputUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        let path = ProcessInfo.processInfo.environment["SAYSO_APP_PATH"] ?? "\(NSHomeDirectory())/.artifacts/Sayso Notch.app"
        app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launch()
    }

    override func tearDown() { app.terminate() }

    func testSpeakIsDisabledUntilTextIsEntered() {
        let tab = app.descendants(matching: .any)["studio-tab-tts"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.click()
        let speak = app.buttons["Speak"].firstMatch
        XCTAssertTrue(speak.waitForExistence(timeout: 5))
        XCTAssertFalse(speak.isEnabled, "empty editor must not be speakable")
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("Hello from the UI test")
        XCTAssertTrue(speak.isEnabled, "typed text enables Speak")
    }
}
