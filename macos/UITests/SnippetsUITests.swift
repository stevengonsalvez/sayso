import AppKit
import XCTest

/// Snippets in the Notch & HUD pane. `--ui-test-clipboard "from the test"`, honoured only together with
/// `--ui-test-fresh-settings`, swaps the real pasteboard for an in-memory board whose text is the given words and which
/// records what Copy writes, so these tests never read or write the user's clipboard. `--ui-test-fresh-settings` gives
/// the app a throwaway settings suite wiped at launch, which also holds the snippets, so the user's snippets and
/// settings are not read or written.
final class SnippetsUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        let path = ProcessInfo.processInfo.environment["SAYSO_APP_PATH"] ?? "\(NSHomeDirectory())/.artifacts/Sayso Notch.app"
        app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchArguments = ["--ui-test-fresh-settings", "--ui-test-clipboard", "from the test"]
        app.launch()
    }

    override func tearDown() { app.terminate() }

    /// The copied text line shows what the module wrote to the fake board: `{clipboard}` read from the fake board at
    /// the moment of Copy, `{date}` from the app's clock in the medium date style of this Mac's locale.
    func testAnAddedSnippetIsListedAndCopyExpandsTheClipboardAndTheDate() {
        openNotchPane()
        addSnippet(name: "Sign off", body: "Thanks, {clipboard}, {date}")
        let copy = element("snippets-copy-Sign off")
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "the new snippet has a Copy button")
        XCTAssertTrue(element("snippets-list").descendants(matching: .any)["snippets-copy-Sign off"].exists, "inside the list")

        let before = NSPasteboard.general.changeCount
        let dayBefore = Self.today()
        reveal(copy)
        copy.click()
        waitFor("snippets-status", toRead: "Copied Sign off")
        let copied = readText("snippets-copied-text")
        let dayAfter = Self.today()
        XCTAssertTrue(
            [dayBefore, dayAfter].map { "Thanks, from the test, \($0)" }.contains(copied),
            "the expanded text, got \(copied), expected the date \(dayBefore)"
        )
        // Only the count is read, never the contents.
        XCTAssertEqual(NSPasteboard.general.changeCount, before, "the real pasteboard was not written")

        let toggle = openSettingsToggle()
        XCTAssertEqual(isOn(toggle), true, "on by default (value: \(String(describing: toggle.value)))")
    }

    /// The pane says Off only once the module has really stopped, so this fails if the setting stops reaching the
    /// module; turning it on again must read the saved snippet back from the store.
    func testTurningTheThrowawaySettingOffShowsOffAndOnAgainShowsTheList() {
        openNotchPane()
        addSnippet(name: "Sign off", body: "Thanks, {clipboard}")
        XCTAssertTrue(element("snippets-copy-Sign off").waitForExistence(timeout: 5), "listed while on")

        let toggle = openSettingsToggle()
        XCTAssertEqual(isOn(toggle), true, "starts on (value: \(String(describing: toggle.value)))")
        toggle.click()
        XCTAssertEqual(isOn(toggle), false, "the click turned the throwaway setting off (value: \(String(describing: toggle.value)))")

        openNotchPane()
        let off = element("snippets-off")
        XCTAssertTrue(off.waitForExistence(timeout: 10), "the Snippets section says it is off")
        XCTAssertEqual(readText("snippets-status"), "Off")
        XCTAssertFalse(element("snippets-copy-Sign off").exists, "no snippet is offered while off")
        XCTAssertFalse(element("snippets-add").isEnabled, "nothing can be added while off")

        let again = openSettingsToggle()
        again.click()
        XCTAssertEqual(isOn(again), true, "the click turned the throwaway setting back on (value: \(String(describing: again.value)))")
        openNotchPane()
        XCTAssertTrue(element("snippets-copy-Sign off").waitForExistence(timeout: 10), "the saved snippet is listed again")
        XCTAssertFalse(off.exists, "the off notice is gone")
    }

    /// The medium date style in this Mac's locale, as the app formats `{date}`.
    private static func today() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: Date())
    }

    private func addSnippet(name: String, body: String) {
        let nameField = element("snippets-name")
        reveal(nameField)
        nameField.click()
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText(name)
        let bodyField = element("snippets-body")
        reveal(bodyField)
        bodyField.click()
        bodyField.typeKey("a", modifierFlags: .command)
        bodyField.typeText(body)
        let add = element("snippets-add")
        reveal(add)
        XCTAssertTrue(add.isEnabled, "Add is offered")
        add.click()
        waitFor("snippets-status", toRead: "Added \(name)")
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func readText(_ identifier: String) -> String {
        let label = element(identifier)
        XCTAssertTrue(label.waitForExistence(timeout: 10), "\(identifier) label")
        return text(of: label)
    }

    private func waitFor(_ identifier: String, toRead expected: String) {
        let label = element(identifier)
        XCTAssertTrue(label.waitForExistence(timeout: 10), "\(identifier) label")
        let reads = NSPredicate { element, _ in
            guard let element = element as? XCUIElement else { return false }
            return self.text(of: element) == expected
        }
        expectation(for: reads, evaluatedWith: label)
        waitForExpectations(timeout: 10)
    }

    private func openNotchPane() {
        let tab = element("studio-tab-notch")
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "sidebar tab for Notch & HUD")
        tab.click()
    }

    /// Snippets is the last section of a long pane: scroll straight down until `element` lies wholly inside the pane,
    /// because XCUITest's own scroll-to-visible also scrolls sideways and has left rows unclickable. Frames, not
    /// `isHittable`, decide when to stop, since asking a half visible field took about 50 s in the file tools tests.
    private func reveal(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(element) exists")
        let pane = app.scrollViews["studio-pane-notch"]
        XCTAssertTrue(pane.exists, "the Notch & HUD pane")
        // A `while`, not `for ... where`: the filter would still query the frames on every remaining step.
        var steps = 0
        while steps < 15, !pane.frame.contains(element.frame) {
            pane.scroll(byDeltaX: 0, deltaY: element.frame.minY < pane.frame.minY ? 300 : -300)
            steps += 1
        }
        XCTAssertTrue(element.isHittable, "can be clicked, frame \(element.frame) in pane \(pane.frame)")
    }

    /// The toggle sits low in the long Settings pane: scroll straight down in 300 pt steps until it lies wholly inside.
    private func openSettingsToggle() -> XCUIElement {
        let tab = element("studio-tab-settings")
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "sidebar tab for Settings")
        tab.click()
        let toggle = element("settings-snippets-toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Snippets toggle in Settings")
        let pane = app.scrollViews["studio-pane-settings"]
        XCTAssertTrue(pane.exists, "the Settings pane")
        var steps = 0
        while steps < 15, !pane.frame.contains(toggle.frame) {
            pane.scroll(byDeltaX: 0, deltaY: toggle.frame.minY < pane.frame.minY ? 300 : -300)
            steps += 1
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
