import Testing
@testable import SaysoCore

@Test func controlPlannerSupportsBoundedCountedScrollAndReviewedWindowKeys() throws {
    let snapshot = DesktopSnapshot(
        processIdentifier: 42,
        applicationName: "Browser",
        windowTitle: "Documentation",
        focusedRole: "AXWebArea",
        focusedValue: "",
        isProtected: false
    )

    #expect(try ControlPlanner.plan(command: "scroll down 12 lines", snapshot: snapshot).action == .scroll(lines: -12, expectedFingerprint: snapshot.fingerprint))
    #expect(try ControlPlanner.plan(command: "scroll up 1 line", snapshot: snapshot).action == .scroll(lines: 1, expectedFingerprint: snapshot.fingerprint))
    #expect(throws: SaysoError.self) { try ControlPlanner.plan(command: "scroll down 101 lines", snapshot: snapshot) }

    let undo = try ControlPlanner.plan(command: "undo", snapshot: snapshot)
    let close = try ControlPlanner.plan(command: "close window", snapshot: snapshot)
    #expect(undo.action == .key(.undo, expectedFingerprint: snapshot.fingerprint))
    #expect(close.action == .key(.closeWindow, expectedFingerprint: snapshot.fingerprint))
    #expect(ControlPolicy.requiresConfirmation(undo))
    #expect(ControlPolicy.requiresConfirmation(close))
}

@Test func controlPlannerSupportsReviewedSpaceKey() throws {
    let snapshot = DesktopSnapshot(
        processIdentifier: 42,
        applicationName: "Browser",
        windowTitle: "Documentation",
        focusedRole: "AXWebArea",
        focusedValue: "",
        isProtected: false
    )

    let step = try ControlPlanner.plan(command: "press space", snapshot: snapshot)

    #expect(step.action == .key(.space, expectedFingerprint: snapshot.fingerprint))
    #expect(ControlPolicy.requiresConfirmation(step))
}
