import Testing
@testable import SaysoCore

private func candidate(
    title: String,
    identifier: String? = nil,
    enabled: Bool = true,
    pressable: Bool = true,
    focusable: Bool = false,
    selectable: Bool = false,
    protected: Bool = false,
    ancestry: [Int] = [0]
) -> DesktopCandidate {
    .init(
        id: .init(
            processIdentifier: 42,
            windowTitle: "Compose",
            role: "AXButton",
            identifier: identifier,
            ancestry: ancestry
        ),
        role: "AXButton",
        title: title,
        identifier: identifier,
        state: .init(
            isEnabled: enabled,
            supportsPress: pressable,
            supportsFocus: focusable,
            supportsSelection: selectable,
            isProtected: protected
        )
    )
}

@Test func candidateIDIsStableForSameAXLocator() {
    let first = DesktopCandidateID(
        processIdentifier: 42,
        windowTitle: "Compose",
        role: "AXButton",
        identifier: "sendButton",
        ancestry: [0, 2]
    )
    let second = DesktopCandidateID(
        processIdentifier: 42,
        windowTitle: "Compose",
        role: "AXButton",
        identifier: "sendButton",
        ancestry: [0, 2]
    )

    #expect(first == second)
}

@Test func candidateStateExcludesProtectedAndDisabledControls() {
    let protected = DesktopCandidateState(isEnabled: true, supportsPress: true, supportsFocus: true, supportsSelection: true, isProtected: true)
    let disabled = DesktopCandidateState(isEnabled: false, supportsPress: true, supportsFocus: true, supportsSelection: true, isProtected: false)
    let interactive = DesktopCandidateState(isEnabled: true, supportsPress: true, supportsFocus: true, supportsSelection: true, isProtected: false)
    let selectableRow = DesktopCandidateState(
        isEnabled: true, supportsPress: false, supportsFocus: false, supportsSelection: true, isProtected: false
    )

    #expect(!protected.isTargetable)
    #expect(!protected.isSelectable)
    #expect(!protected.isSelectionTarget)
    #expect(!disabled.isTargetable)
    #expect(!disabled.isSelectable)
    #expect(!disabled.isSelectionTarget)
    #expect(interactive.isTargetable)
    #expect(interactive.isSelectable)
    #expect(interactive.isSelectionTarget)
    #expect(selectableRow.isSelectionTarget)
}

@Test func resolverUsesOneExactTargetableCandidate() {
    let send = candidate(title: "Send", identifier: "sendButton", ancestry: [0, 1])
    let snapshot = DesktopCandidateSnapshot(
        processIdentifier: 42,
        applicationName: "Mail",
        windowTitle: "Compose",
        candidates: [send]
    )

    #expect(DesktopCandidateResolver.resolve("SÉND", in: snapshot) == .resolved(send))
    #expect(DesktopCandidateResolver.resolve("sendButton", in: snapshot) == .resolved(send))
}

@Test func resolverRejectsAmbiguousTargetableCandidatesDeterministically() {
    let first = candidate(title: "Send", ancestry: [0, 1])
    let second = candidate(title: "Send", ancestry: [0, 2])
    let snapshot = DesktopCandidateSnapshot(
        processIdentifier: 42,
        applicationName: "Mail",
        windowTitle: "Compose",
        candidates: [second, first]
    )

    let expected = [first.id, second.id].sorted { $0.rawValue < $1.rawValue }
    #expect(DesktopCandidateResolver.resolve("send", in: snapshot) == .ambiguous(expected))
}

@Test func resolverNeverTargetsProtectedOrDisabledMatches() {
    let protected = candidate(title: "Send", protected: true, ancestry: [0, 1])
    let disabled = candidate(title: "Send", enabled: false, ancestry: [0, 2])
    let snapshot = DesktopCandidateSnapshot(
        processIdentifier: 42,
        applicationName: "Mail",
        windowTitle: "Compose",
        candidates: [protected, disabled]
    )

    let expected = [protected.id, disabled.id].sorted { $0.rawValue < $1.rawValue }
    #expect(DesktopCandidateResolver.resolve("send", in: snapshot) == .excluded(expected))
}
