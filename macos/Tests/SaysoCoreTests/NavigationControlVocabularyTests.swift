import CoreGraphics
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
    #expect(DesktopKey.goForward.commandCharacter == "]")
    #expect(DesktopKey.goForward.virtualKey == 30)
    #expect(DesktopKey.goForward.modifierFlags == .maskCommand)
}

@Test func commandKeysUseCharactersInsteadOfPhysicalKeyPositions() {
    let azerty: [CGKeyCode: String] = [
        6: "w",
        13: "z",
        33: "]",
        30: "[",
    ]

    #expect(DesktopKey.keyCode(producing: "z") { azerty[$0] } == 13)
    #expect(DesktopKey.keyCode(producing: "w") { azerty[$0] } == 6)
    #expect(DesktopKey.keyCode(producing: "[") { azerty[$0] } == 30)
    #expect(DesktopKey.keyCode(producing: "]") { azerty[$0] } == 33)
    #expect(DesktopKey.keyCode(producing: "z") { _ in nil } == nil)
    #expect(DesktopKey.resolvedKeyCode(nil, fallback: DesktopKey.undo.virtualKey) == 6)
}
