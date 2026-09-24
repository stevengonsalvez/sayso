import Testing
@testable import SaysoCore

@Test func focusPlannerRequiresOneExactFocusableField() throws {
    let snapshot = DesktopSnapshot(
        processIdentifier: 42,
        applicationName: "Browser",
        windowTitle: "Search",
        focusedRole: "AXWebArea",
        focusedValue: "",
        isProtected: false,
        elements: [
            .init(id: "search", role: "AXTextField", title: "Search", supportsPress: false, supportsFocus: true),
            .init(id: "send", role: "AXButton", title: "Send", supportsPress: true)
        ]
    )

    let step = try ControlPlanner.plan(command: "focus Search", snapshot: snapshot)

    #expect(step.action == .focus(elementID: "search", expectedFingerprint: snapshot.fingerprint))
    #expect(ControlPolicy.canAutoRun(step))
    #expect(ControlPolicy.requiresActiveTarget(for: step.action))
    #expect(throws: SaysoError.self) { try ControlPlanner.plan(command: "click Search", snapshot: snapshot) }
}

@Test func focusPlannerRejectsAmbiguousAndNonFocusableTitles() {
    let snapshot = DesktopSnapshot(
        processIdentifier: 42,
        applicationName: "Browser",
        windowTitle: "Search",
        focusedRole: "AXWebArea",
        focusedValue: "",
        isProtected: false,
        elements: [
            .init(id: "first", role: "AXTextField", title: "Search", supportsPress: false, supportsFocus: true),
            .init(id: "second", role: "AXTextField", title: "Search", supportsPress: false, supportsFocus: true),
            .init(id: "label", role: "AXStaticText", title: "Address")
        ]
    )

    #expect(throws: SaysoError.self) { try ControlPlanner.plan(command: "focus Search", snapshot: snapshot) }
    #expect(throws: SaysoError.self) { try ControlPlanner.plan(command: "focus Address", snapshot: snapshot) }
}
