import XCTest

/// Calculator in the Notch & HUD pane: type an expression, press Return, read the result label.
/// `--ui-test-fresh-settings` gives the app a throwaway settings suite wiped at launch, so the only setting ever
/// flipped is the throwaway one. Copy is never pressed: these tests must not touch the user's pasteboard.
final class CalculatorUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        let path = ProcessInfo.processInfo.environment["SAYSO_APP_PATH"] ?? "\(NSHomeDirectory())/.artifacts/Sayso Notch.app"
        app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchArguments = ["--ui-test-fresh-settings"]
        app.launch()
    }

    override func tearDown() { app.terminate() }

    func testTheTimesSignMultiplies() {
        openNotchPane()
        XCTAssertEqual(evaluate("12 × 3"), "36")
        let copy = app.descendants(matching: .any)["calculator-copy"]
        XCTAssertTrue(copy.exists, "a Copy button for the result")
        XCTAssertTrue(copy.isEnabled, "Copy is offered for a result")

        // The module's short-lived result notice reaches the open notch.
        openNotch()
        let line = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "12 × 3 = 36")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 5), "the result line in the notch")
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: line)
        waitForExpectations(timeout: 15)
    }

    /// Opens the notch if it is collapsed, and proves it is open so an absent line is not a closed notch.
    /// Matched by label: SwiftUI gives the minimize button its symbol name as identifier.
    private func openNotch() {
        let pill = app.buttons["Open Sayso Dictation workspace"].firstMatch
        if pill.waitForExistence(timeout: 3) { pill.click() }
        let minimize = app.buttons.matching(NSPredicate(format: "label == %@", "Minimize Sayso workspace")).firstMatch
        XCTAssertTrue(minimize.waitForExistence(timeout: 10), "expanded notch")
    }

    func testKilometresConvertToMiles() {
        openNotchPane()
        let shown = evaluate("5 km in miles")
        let number = shown.split(separator: " ").first.flatMap { Double($0) }
        XCTAssertNotNil(number, "result starts with a number, got \(shown)")
        XCTAssertEqual(number ?? 0, 3.10686, accuracy: 0.00001, "5 km is about 3.10686 miles, got \(shown)")
        XCTAssertTrue(shown.hasSuffix(" mi"), "names the unit, got \(shown)")
    }

    func testDivisionByZeroShowsAnErrorAndTheAppKeepsRunning() {
        openNotchPane()
        XCTAssertEqual(evaluate("1/0"), "Cannot divide by zero")
        XCTAssertEqual(app.state, .runningForeground, "the app is still running")
        XCTAssertFalse(app.descendants(matching: .any)["calculator-copy"].isEnabled, "nothing to copy for an error")
        // Still usable afterwards.
        XCTAssertEqual(evaluate("2 + 2"), "4")
    }

    /// The pane's off notice comes from the module's state, not the setting, and the off message comes from the
    /// module refusing to evaluate, so this fails if the setting stops reaching the module.
    func testTheToggleIsOnByDefaultAndTurningItOffStopsTheCalculator() {
        let toggle = openSettingsToggle()
        XCTAssertEqual(isOn(toggle), true, "on by default (value: \(String(describing: toggle.value)))")
        toggle.click()
        XCTAssertEqual(isOn(toggle), false, "the click turned the throwaway setting off (value: \(String(describing: toggle.value)))")

        openNotchPane()
        XCTAssertTrue(app.descendants(matching: .any)["calculator-off"].waitForExistence(timeout: 5), "the pane says the calculator is off")
        XCTAssertEqual(evaluate("2 + 2"), "Calculator is off. Turn it on in Settings.")

        let again = openSettingsToggle()
        again.click()
        XCTAssertEqual(isOn(again), true, "the click turned the throwaway setting back on (value: \(String(describing: again.value)))")
        openNotchPane()
        XCTAssertEqual(evaluate("2 + 2"), "4")
        XCTAssertFalse(app.descendants(matching: .any)["calculator-off"].exists, "the off notice is gone")
    }

    /// Replaces the field's text, presses Return and returns the result label once it shows something new.
    private func evaluate(_ input: String) -> String {
        let field = app.descendants(matching: .any)["calculator-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "calculator input field")
        let result = app.descendants(matching: .any)["calculator-result"]
        let before = result.exists ? text(of: result) : nil
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(input + "\r")
        XCTAssertTrue(result.waitForExistence(timeout: 5), "calculator result label")
        let changed = NSPredicate { element, _ in
            guard let element = element as? XCUIElement else { return false }
            return self.text(of: element) != before || before == nil
        }
        expectation(for: changed, evaluatedWith: result)
        waitForExpectations(timeout: 5)
        return text(of: result)
    }

    private func openNotchPane() {
        let tab = app.descendants(matching: .any)["studio-tab-notch"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "sidebar tab for Notch & HUD")
        tab.click()
    }

    private func openSettingsToggle() -> XCUIElement {
        let tab = app.descendants(matching: .any)["studio-tab-settings"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "sidebar tab for Settings")
        tab.click()
        let toggle = app.descendants(matching: .any)["settings-calculator-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Calculator toggle in Settings")
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
