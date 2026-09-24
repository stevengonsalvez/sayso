import CoreGraphics
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
    #expect(AXCandidateCapturePolicy.includesCandidate(
        role: "AXRow",
        title: "Downloads",
        identifier: nil,
        supportsPress: false,
        supportsFocus: false,
        supportsSelection: true,
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

@Test func directControlsOutrankSelectionOnlyRows() {
    #expect(AXCandidateCapturePolicy.defersSelectionCandidate(
        supportsPress: false,
        supportsFocus: false,
        supportsSelection: true
    ))
    #expect(!AXCandidateCapturePolicy.defersSelectionCandidate(
        supportsPress: true,
        supportsFocus: false,
        supportsSelection: true
    ))
    #expect(!AXCandidateCapturePolicy.defersSelectionCandidate(
        supportsPress: false,
        supportsFocus: true,
        supportsSelection: true
    ))
}

@Test func pointerHitDecisionProtectsInteractiveRowChildren() {
    #expect(AXCandidateCapturePolicy.pointerHitDecision(
        hasInteractiveDescendant: false
    ) == .pointer)
    #expect(AXCandidateCapturePolicy.pointerHitDecision(
        hasInteractiveDescendant: true
    ) == .accessibilitySelection)
}

@Test func pointerRowsRequireVisibleCentre() {
    let parent = CGRect(x: 0, y: 0, width: 10, height: 10)
    let visibleRow = CGRect(x: 0, y: 0, width: 10, height: 10)
    let coveredRow = CGRect(x: 20, y: 20, width: 10, height: 10)

    #expect(AXCandidateCapturePolicy.visibleClip(parent: parent, frame: nil) == parent)
    #expect(AXCandidateCapturePolicy.visibleClip(parent: nil, frame: visibleRow) == visibleRow)
    #expect(AXCandidateCapturePolicy.visibleClip(parent: parent, frame: coveredRow)?.isNull == true)
    #expect(AXCandidateCapturePolicy.isCentreVisible(frame: visibleRow, in: parent))
    #expect(!AXCandidateCapturePolicy.isCentreVisible(
        frame: visibleRow,
        in: CGRect(x: 0, y: 0, width: 4, height: 4)
    ))
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
