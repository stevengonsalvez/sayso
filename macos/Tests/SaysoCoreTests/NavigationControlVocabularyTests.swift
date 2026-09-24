import Testing
@testable import SaysoCore

@Test func goForwardUsesReviewedNavigationKey() throws {
    let snapshot = DesktopSnapshot(
        processIdentifier: 42,
        applicationName: "Safari",
        windowTitle: "Documentation",
        focusedRole: "AXWebArea",
        focusedValue: "",
        isProtected: false
    )

    let step = try ControlPlanner.plan(command: "go forward", snapshot: snapshot)

    #expect(step.action == .key(.goForward, expectedFingerprint: snapshot.fingerprint))
    #expect(step.reason == "Go forward")
    #expect(ControlPolicy.requiresConfirmation(step))
    #expect(DesktopKey.goForward.virtualKey == 30)
    #expect(DesktopKey.goForward.modifierFlags == .maskCommand)
}
