import XCTest

/// Read-only: opens panes and checks their headings. Never edits settings or starts downloads.
final class StudioPaneContentUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        let path = ProcessInfo.processInfo.environment["SAYSO_APP_PATH"] ?? "\(NSHomeDirectory())/.artifacts/Sayso Notch.app"
        app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launch()
    }

    override func tearDown() { app.terminate() }

    private func open(_ id: String) {
        let tab = app.descendants(matching: .any)["studio-tab-\(id)"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.click()
    }

    func testControlPaneShowsDesktopControlHeading() {
        open("control")
        XCTAssertTrue(app.staticTexts["Desktop control"].waitForExistence(timeout: 5))
    }

    func testVocabularyPaneShowsItsHeading() {
        open("vocabulary")
        XCTAssertTrue(app.staticTexts["Vocabulary & Pronunciation"].waitForExistence(timeout: 5))
    }

    func testVoiceOutputPaneShowsItsHeading() {
        open("tts")
        XCTAssertTrue(app.staticTexts["Voice output"].waitForExistence(timeout: 5))
    }
}
