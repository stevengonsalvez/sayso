import Testing
@testable import SaysoCore

@Test func selectionPlannerRequiresOneExactSelectableRow() throws {
    let snapshot = DesktopSnapshot(
        processIdentifier: 42,
        applicationName: "Finder",
        windowTitle: "Downloads",
        focusedRole: "AXOutline",
        focusedValue: "",
        isProtected: false,
        elements: [
            .init(id: "downloads", role: "AXRow", title: "Downloads", supportsPress: false, supportsSelection: true),
            .init(id: "documents", role: "AXRow", title: "Documents", supportsPress: false, supportsSelection: true),
        ]
    )

    let step = try ControlPlanner.plan(command: "select Downloads", snapshot: snapshot)

    #expect(step.action == .select(elementID: "downloads", expectedFingerprint: snapshot.fingerprint))
    #expect(ControlPolicy.canAutoRun(step))
    #expect(ControlPolicy.requiresActiveTarget(for: step.action))
    #expect(throws: SaysoError.self) { try ControlPlanner.plan(command: "click Downloads", snapshot: snapshot) }
}

@Test func selectionPlannerRejectsAmbiguousOrNonSelectableRows() {
    let snapshot = DesktopSnapshot(
        processIdentifier: 42,
        applicationName: "Finder",
        windowTitle: "Downloads",
        focusedRole: "AXOutline",
        focusedValue: "",
        isProtected: false,
        elements: [
            .init(id: "first", role: "AXRow", title: "Downloads", supportsPress: false, supportsSelection: true),
            .init(id: "second", role: "AXRow", title: "Downloads", supportsPress: false, supportsSelection: true),
            .init(id: "label", role: "AXStaticText", title: "Recents", supportsPress: false),
        ]
    )

    #expect(throws: SaysoError.self) { try ControlPlanner.plan(command: "select Downloads", snapshot: snapshot) }
    #expect(throws: SaysoError.self) { try ControlPlanner.plan(command: "select Recents", snapshot: snapshot) }
}
