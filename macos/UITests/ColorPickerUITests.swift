import XCTest

/// Colour picker in the Notch & HUD pane. `--ui-test-color 336699`, honoured only together with
/// `--ui-test-fresh-settings`, makes the app use a fake sampler that returns that colour, so no human click is needed
/// and the real system sampler is never shown. Copy is never pressed: these tests must not touch the user's pasteboard.
final class ColorPickerUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        let path = ProcessInfo.processInfo.environment["SAYSO_APP_PATH"] ?? "\(NSHomeDirectory())/.artifacts/Sayso Notch.app"
        app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchArguments = ["--ui-test-fresh-settings", "--ui-test-color", "336699"]
        app.launch()
    }

    override func tearDown() { app.terminate() }

    func testAPickShowsTheColourInHexRgbAndHsl() {
        openNotchPane()
        pick()
        XCTAssertEqual(readRow("color-picker-hex"), "#336699")
        XCTAssertEqual(readRow("color-picker-rgb"), "rgb(51, 102, 153)")
        XCTAssertEqual(readRow("color-picker-hsl"), "hsl(210, 50%, 40%)")
        XCTAssertTrue(element("color-picker-swatch").exists, "a swatch of the picked colour")
        for format in ["hex", "rgb", "hsl"] {
            XCTAssertTrue(element("color-picker-copy-\(format)").exists, "a Copy button for \(format)")
        }
        XCTAssertTrue(element("color-picker-history").exists, "the recent picks list")
    }

    /// The module's short-lived pick notice reaches the open notch and then goes away on its own.
    func testAPickShowsBrieflyInTheOpenNotch() {
        openNotchPane()
        pick()
        XCTAssertEqual(readRow("color-picker-hex"), "#336699")
        openNotch()
        let line = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Picked #336699")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 5), "the pick line in the notch")
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: line)
        waitForExpectations(timeout: 15)
    }

    /// The pane's off notice and empty rows come from the module's state, not the setting, so this fails if the
    /// setting stops reaching the module.
    func testTheToggleIsOnByDefaultAndTurningItOffClearsThePicks() {
        openNotchPane()
        pick()
        XCTAssertEqual(readRow("color-picker-hex"), "#336699")

        let toggle = openSettingsToggle()
        XCTAssertEqual(isOn(toggle), true, "on by default (value: \(String(describing: toggle.value)))")
        toggle.click()
        XCTAssertEqual(isOn(toggle), false, "the click turned the throwaway setting off (value: \(String(describing: toggle.value)))")

        openNotchPane()
        XCTAssertTrue(element("color-picker-off").waitForExistence(timeout: 5), "the pane says the picker is off")
        XCTAssertFalse(element("color-picker-hex").exists, "turning it off cleared the pick")
        XCTAssertFalse(element("color-picker-pick").isEnabled, "nothing to pick with while off")

        let again = openSettingsToggle()
        again.click()
        XCTAssertEqual(isOn(again), true, "the click turned the throwaway setting back on (value: \(String(describing: again.value)))")
        openNotchPane()
        XCTAssertFalse(element("color-picker-off").exists, "the off notice is gone")
        XCTAssertFalse(element("color-picker-hex").exists, "nothing comes back after turning it on again")
        pick()
        XCTAssertEqual(readRow("color-picker-hex"), "#336699")
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func pick() {
        let button = element("color-picker-pick")
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Pick button")
        XCTAssertTrue(button.isEnabled, "Pick is offered")
        button.click()
    }

    private func readRow(_ identifier: String) -> String {
        let row = element(identifier)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(identifier) row")
        return text(of: row)
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
        let minimize = app.buttons.matching(NSPredicate(format: "label == %@", "Minimize Sayso workspace")).firstMatch
        XCTAssertTrue(minimize.waitForExistence(timeout: 10), "expanded notch")
    }

    private func openSettingsToggle() -> XCUIElement {
        let tab = element("studio-tab-settings")
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "sidebar tab for Settings")
        tab.click()
        let toggle = element("settings-color-picker-toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Colour picker toggle in Settings")
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
