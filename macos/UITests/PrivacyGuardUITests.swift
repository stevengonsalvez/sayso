import XCTest

/// Privacy guard in the Notch & HUD pane and the notch. `--ui-test-privacy mic`, honoured only together with
/// `--ui-test-fresh-settings`, swaps the real device reader for a fake that reports one microphone switched on and one
/// camera switched off, so no real microphone or camera is involved and nothing is ever opened or recorded.
/// `--ui-test-fresh-settings` gives the app a throwaway settings suite wiped at launch, so the user's settings are not
/// read or written.
final class PrivacyGuardUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        let path = ProcessInfo.processInfo.environment["SAYSO_APP_PATH"] ?? "\(NSHomeDirectory())/.artifacts/Sayso Notch.app"
        app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchArguments = ["--ui-test-fresh-settings", "--ui-test-privacy", "mic"]
        app.launch()
    }

    override func tearDown() { app.terminate() }

    /// The microphone row turns to In use once the module has seen it on twice in a row; the notch line names the one
    /// device; Dismiss hides the line while the pane still says In use, because the microphone is still on.
    func testARunningMicrophoneShowsInThePaneAndTheNotchAndDismissHidesOnlyTheLine() {
        openNotchPane()
        waitForRow("privacy-guard-mic", toRead: "In use", timeout: 20)
        XCTAssertEqual(readRow("privacy-guard-camera"), "Not in use", "the fake camera is switched off")

        openNotch()
        let line = notchLine
        XCTAssertTrue(line.waitForExistence(timeout: 10), "the privacy line in the open notch")
        XCTAssertEqual(line.label, "Microphone in use · UI Test Microphone", "one device, so the line names it")

        dismissFromNotchMenu()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: line)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(minimizeButton.exists, "the notch is still open, so Dismiss removed the line")

        openNotchPane()
        XCTAssertEqual(readRow("privacy-guard-mic"), "In use", "the microphone is still on after Dismiss")

        let toggle = openSettingsToggle()
        XCTAssertEqual(isOn(toggle), true, "on by default (value: \(String(describing: toggle.value)))")
    }

    /// The pane says Off only once the module has really stopped, so this fails if the setting stops reaching the
    /// module; turning it on again must bring the reading back.
    func testTurningTheThrowawaySettingOffShowsOffAndOnAgainShowsInUse() {
        let toggle = openSettingsToggle()
        XCTAssertEqual(isOn(toggle), true, "starts on (value: \(String(describing: toggle.value)))")
        toggle.click()
        XCTAssertEqual(isOn(toggle), false, "the click turned the throwaway setting off (value: \(String(describing: toggle.value)))")

        openNotchPane()
        XCTAssertTrue(element("privacy-guard-off").waitForExistence(timeout: 10), "the Privacy section says it is off")
        XCTAssertEqual(readRow("privacy-guard-mic"), "Off")
        XCTAssertEqual(readRow("privacy-guard-camera"), "Off")
        openNotch()
        XCTAssertFalse(notchLine.exists, "no privacy line while off")

        let again = openSettingsToggle()
        again.click()
        XCTAssertEqual(isOn(again), true, "the click turned the throwaway setting back on (value: \(String(describing: again.value)))")
        openNotchPane()
        waitForRow("privacy-guard-mic", toRead: "In use", timeout: 20)
        XCTAssertFalse(element("privacy-guard-off").exists, "the off notice is gone once it reads again")
    }

    private var notchLine: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Microphone in use")).firstMatch
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func readRow(_ identifier: String) -> String {
        let row = element(identifier)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(identifier) row")
        return text(of: row)
    }

    private func waitForRow(_ identifier: String, toRead expected: String, timeout: TimeInterval) {
        let row = element(identifier)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(identifier) row")
        let reads = NSPredicate { element, _ in
            guard let element = element as? XCUIElement else { return false }
            return self.text(of: element) == expected
        }
        expectation(for: reads, evaluatedWith: row)
        waitForExpectations(timeout: timeout)
    }

    private func openNotchPane() {
        let tab = element("studio-tab-notch")
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "sidebar tab for Notch & HUD")
        tab.click()
    }

    /// Opens the notch if it is collapsed, and proves it is open so an absent line is not a closed notch.
    /// Matched by label: SwiftUI gives the minimize button its symbol name as identifier.
    private func openNotch() {
        let pill = app.buttons["Open Sayso Dictation workspace"].firstMatch
        if pill.waitForExistence(timeout: 3) { pill.click() }
        XCTAssertTrue(minimizeButton.waitForExistence(timeout: 10), "expanded notch")
    }

    private var minimizeButton: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", "Minimize Sayso workspace")).firstMatch
    }

    private func dismissFromNotchMenu() {
        let menu = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "More Sayso controls")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "the notch's More menu")
        menu.click()
        let dismiss = app.menuItems["Dismiss notification"].firstMatch
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "Dismiss notification in the notch menu")
        dismiss.click()
    }

    /// The toggle sits low in the long Settings pane: scroll straight down until it lies wholly inside the pane,
    /// because XCUITest's own scroll-to-visible also scrolls sideways and has left rows unclickable.
    private func openSettingsToggle() -> XCUIElement {
        let tab = element("studio-tab-settings")
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "sidebar tab for Settings")
        tab.click()
        let toggle = element("settings-privacy-guard-toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Privacy guard toggle in Settings")
        let pane = app.scrollViews["studio-pane-settings"]
        for _ in 0..<40 where pane.exists && !pane.frame.contains(toggle.frame) {
            pane.scroll(byDeltaX: 0, deltaY: -100)
        }
        XCTAssertTrue(toggle.isHittable, "can be clicked, frame \(toggle.frame) in pane \(pane.frame)")
        return toggle
    }

    /// SwiftUI exposes a Text as its value or its label depending on the macOS release.
    private func text(of element: XCUIElement) -> String {
        (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
    }

    /// nil means unreadable, so the test cannot pass by failing to read the value.
    private func isOn(_ toggle: XCUIElement) -> Bool? {
        switch toggle.value {
        case let number as NSNumber: number.boolValue
        case let text as String where text == "0" || text == "1": text == "1"
        default: nil
        }
    }
}
