import Testing
@testable import SaysoCore

@Test func capturePolicyExcludesSecureControlsBeforeMetadataIsUsed() {
    #expect(AXCandidateCapturePolicy.isProtected(role: "AXSecureTextField", subrole: ""))
    #expect(AXCandidateCapturePolicy.isProtected(role: "AXTextField", subrole: "AXSecureTextField"))
    #expect(!AXCandidateCapturePolicy.isProtected(role: "AXTextField", subrole: ""))
}

@Test func capturePolicyRedactsSecureFocusedValues() {
    #expect(AXCandidateCapturePolicy.focusedValue("password", role: "AXSecureTextField", subrole: "") == "")
    #expect(AXCandidateCapturePolicy.focusedValue("password", role: "AXTextField", subrole: "AXSecureTextField") == "")
    #expect(AXCandidateCapturePolicy.focusedValue("message", role: "AXTextField", subrole: "") == "message")
}

@Test func capturePolicyRequiresSafeInteractiveLocator() {
    #expect(!AXCandidateCapturePolicy.includesCandidate(
        role: "AXButton",
        title: "Send",
        identifier: "send",
        supportsPress: true,
        supportsFocus: true,
        isProtected: true
    ))
    #expect(!AXCandidateCapturePolicy.includesCandidate(
        role: "AXButton",
        title: "",
        identifier: nil,
        supportsPress: true,
        supportsFocus: false,
        isProtected: false
    ))
    #expect(AXCandidateCapturePolicy.includesCandidate(
        role: "AXButton",
        title: "",
        identifier: "send",
        supportsPress: true,
        supportsFocus: false,
        isProtected: false
    ))
}

@Test func captureLimitsClampToSafeMinimumsAndBoundQueuedPaths() {
    let limits = AXCandidateCaptureLimits(maximumDepth: -1, maximumNodes: 0, maximumCandidates: 0)
    #expect(limits.maximumDepth == 0)
    #expect(limits.maximumNodes == 1)
    #expect(limits.maximumCandidates == 1)
    #expect(AXCandidateCapturePolicy.childPaths(from: [2, 1], childCount: 4, remainingNodeCapacity: 2) == [[2, 1, 0], [2, 1, 1]])
    #expect(AXCandidateCapturePolicy.childPaths(from: [], childCount: 4, remainingNodeCapacity: 0).isEmpty)
}

@Test func captureLocatorIsStableForSameBoundedAncestry() {
    let first = DesktopCandidateID(
        processIdentifier: 12,
        windowTitle: "Compose",
        role: "AXButton",
        identifier: "send",
        ancestry: [0, 3, 1]
    )
    let second = DesktopCandidateID(
        processIdentifier: 12,
        windowTitle: "Compose",
        role: "AXButton",
        identifier: "send",
        ancestry: [0, 3, 1]
    )

    #expect(first == second)
}
