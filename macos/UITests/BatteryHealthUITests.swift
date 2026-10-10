import XCTest

/// Battery health in the Notch & HUD pane and the notch. `--ui-test-battery healthy|worn|hot|none`, honoured only
/// together with `--ui-test-fresh-settings`, swaps the real IOKit reader for a fixed fake battery, so no test depends
/// on this Mac having a battery (a CI virtual machine has none) or on its real health. `--ui-test-fresh-settings`
/// gives the app a throwaway settings suite wiped at launch, so the user's settings are not read or written.
final class BatteryHealthUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() { continueAfterFailure = false }

    override func tearDown() { app?.terminate() }

    /// The fake worn battery holds 55% of its design capacity: the row reads Replace soon, the notch shows one
    /// health line, and Dismiss hides only the line while the row still says what is true.
    func testAWornBatteryReadsReplaceSoonAndItsNotchLineCanBeDismissed() {
        launch("worn")
        openNotchPane()
        waitForRow("battery-health-health", toContain: "Replace soon", timeout: 20)
        XCTAssertEqual(readRow("battery-health-health"), "55% · Replace soon")
        XCTAssertEqual(readRow("battery-health-cycles"), "1,234")
        XCTAssertEqual(readRow("battery-health-temperature"), "31.5 °C")
        XCTAssertEqual(readRow("battery-health-power"), "On battery · 3 h 20 min left")

        openNotch()
        let line = notchLine
        XCTAssertTrue(line.waitForExistence(timeout: 10), "the battery health line in the open notch")
        XCTAssertEqual(line.label, "Battery health 55% · Replace soon")

        dismissFromNotchMenu()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: line)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(minimizeButton.exists, "the notch is still open, so Dismiss removed the line")

        openNotchPane()
        XCTAssertEqual(readRow("battery-health-health"), "55% · Replace soon", "the battery is still worn after Dismiss")
    }

    /// A Mac with no battery reads No battery in every row and never shows a notch line; the toggle is on by default.
    func testAMacWithNoBatteryReadsNoBatteryAndShowsNoLine() {
        launch("none")
        openNotchPane()
        waitForRow("battery-health-health", toContain: "No battery", timeout: 20)
        for id in ["battery-health-cycles", "battery-health-temperature", "battery-health-power"] {
            XCTAssertEqual(readRow(id), "No battery", "\(id)")
        }
        openNotch()
        XCTAssertFalse(notchLine.exists, "no battery, no line")

        let toggle = openSettingsToggle()
        XCTAssertEqual(isOn(toggle), true, "on by default (value: \(String(describing: toggle.value)))")
    }

    /// The pane says Off only once the module has really stopped, so this fails if the setting stops reaching the
    /// module; turning it on again must bring the reading back.
    func testTurningTheThrowawaySettingOffShowsOffAndOnAgainShowsTheBattery() {
        launch("worn")
        let toggle = openSettingsToggle()
        XCTAssertEqual(isOn(toggle), true, "starts on (value: \(String(describing: toggle.value)))")
        toggle.click()
        XCTAssertEqual(isOn(toggle), false, "the click turned the throwaway setting off (value: \(String(describing: toggle.value)))")

        openNotchPane()
        let notice = element("battery-health-off")
        reveal(notice)
        for id in ["battery-health-health", "battery-health-cycles", "battery-health-temperature", "battery-health-power"] {
            XCTAssertEqual(readRow(id), "Off", "\(id) reads Off, not a stale figure")
        }
        openNotch()
        XCTAssertFalse(notchLine.exists, "no battery line while off")

        let again = openSettingsToggle()
        again.click()
        XCTAssertEqual(isOn(again), true, "the click turned the throwaway setting back on (value: \(String(describing: again.value)))")
        openNotchPane()
        waitForRow("battery-health-health", toContain: "Replace soon", timeout: 20)
        XCTAssertFalse(notice.exists, "the off notice is gone once it reads again")
    }

    private func launch(_ battery: String) {
        let path = ProcessInfo.processInfo.environment["SAYSO_APP_PATH"] ?? "\(NSHomeDirectory())/.artifacts/Sayso Notch.app"
        app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchArguments = ["--ui-test-fresh-settings", "--ui-test-battery", battery]
        app.launch()
    }

    /// This module's lines only: System stats has its own low battery line, which this Mac may show while unplugged.
    private var notchLine: XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Battery health", "Battery is hot"
        )).firstMatch
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func readRow(_ identifier: String) -> String {
        let row = element(identifier)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(identifier) row")
        return text(of: row)
    }

    private func waitForRow(_ identifier: String, toContain expected: String, timeout: TimeInterval) {
        let row = element(identifier)
        reveal(row)
        let reads = NSPredicate { element, _ in
            guard let element = element as? XCUIElement else { return false }
            return self.text(of: element).contains(expected)
        }
        expectation(for: reads, evaluatedWith: row)
        waitForExpectations(timeout: timeout)
    }

    private func openNotchPane() {
        let tab = element("studio-tab-notch")
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "sidebar tab for Notch & HUD")
        tab.click()
    }

    /// Scrolls the Notch & HUD pane straight down until `element` lies wholly inside it. The Battery section sits low
    /// in the long pane, and XCUITest's own scroll-to-visible also scrolls sideways and has left rows out of view.
    private func reveal(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(element) exists")
        let pane = app.scrollViews["studio-pane-notch"]
        for _ in 0..<15 where pane.exists && !pane.frame.contains(element.frame) {
            pane.scroll(byDeltaX: 0, deltaY: element.frame.minY < pane.frame.minY ? 300 : -300)
        }
        XCTAssertTrue(pane.frame.contains(element.frame), "in view, frame \(element.frame) in pane \(pane.frame)")
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
        // A SwiftUI Menu with an icon only label reaches XCUITest as a menu button with that text as its title.
        let menu = app.menuButtons.matching(NSPredicate(format: "title == %@", "More Sayso controls")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "the notch's More menu")
        menu.click()
        let dismiss = app.menuItems["Dismiss notification"].firstMatch
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "Dismiss notification in the notch menu")
        dismiss.click()
    }

    /// The toggle sits low in the long Settings pane: scroll straight down until it lies wholly inside the pane, in
    /// 300 pt steps, because XCUITest's own scroll-to-visible also scrolls sideways and has left rows unclickable.
    private func openSettingsToggle() -> XCUIElement {
        let tab = element("studio-tab-settings")
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "sidebar tab for Settings")
        tab.click()
        let toggle = element("settings-battery-health-toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Battery health toggle in Settings")
        let pane = app.scrollViews["studio-pane-settings"]
        for _ in 0..<15 where pane.exists && !pane.frame.contains(toggle.frame) {
            pane.scroll(byDeltaX: 0, deltaY: toggle.frame.minY < pane.frame.minY ? 300 : -300)
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
