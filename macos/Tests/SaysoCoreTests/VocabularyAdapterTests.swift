import Foundation
import Testing
@testable import SaysoCore

private final class Seen: @unchecked Sendable { var ready: [CorrectionCandidateReady] = [] }

@MainActor
private func makeLearning() async -> (SaysoCorrectionLearning, URL) {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let learning = SaysoCorrectionLearning(baseDirectory: root, promotionThreshold: 5)
    await learning.waitUntilLoaded()
    return (learning, root)
}

@MainActor
@Test func bridgeAnnouncesEachNewCandidateOnceAndAcceptPromotesItIntoARule() async throws {
    let (learning, root) = await makeLearning()
    defer { try? FileManager.default.removeItem(at: root) }
    let bus = SaysoEventBus(), seen = Seen()
    _ = bus.subscribe(CorrectionCandidateReady.self) { seen.ready.append($0) }
    let bridge = VocabularyBridge(learning: learning, bus: bus)

    try await learning.recordEdit(original: "Alen", edited: "Allen", sourceApplication: "Mail")
    bridge.sync()
    bridge.sync()
    let candidate = try #require(learning.candidates.first)
    #expect(seen.ready == [CorrectionCandidateReady(candidateID: candidate.id, source: "Alen", replacement: "Allen")])

    try await bridge.promote(candidateID: candidate.id)
    #expect(learning.apply(to: "Alen arrived.").transformedText == "Allen arrived.")
}

@MainActor
@Test func dismissedCandidatesStopBeingOfferedAndUnknownIDsThrow() async throws {
    let (learning, root) = await makeLearning()
    defer { try? FileManager.default.removeItem(at: root) }
    let bus = SaysoEventBus(), seen = Seen()
    _ = bus.subscribe(CorrectionCandidateReady.self) { seen.ready.append($0) }
    let bridge = VocabularyBridge(learning: learning, bus: bus)

    try await learning.recordEdit(original: "Alen", edited: "Allen", sourceApplication: "Mail")
    bridge.sync()
    let candidate = try #require(learning.candidates.first)
    try await bridge.dismiss(candidateID: candidate.id)
    bridge.sync()
    #expect(seen.ready.count == 1)
    #expect(learning.candidates.isEmpty)

    await #expect(throws: VocabularyBridge.UnknownCandidate.self) { try await bridge.promote(candidateID: UUID()) }
}

private final class Resolved: @unchecked Sendable { var ids: [UUID] = [] }

@MainActor
@Test func syncAnnouncesCandidatesResolvedOutsideTheModule() async throws {
    let (learning, root) = await makeLearning()
    defer { try? FileManager.default.removeItem(at: root) }
    let bus = SaysoEventBus(), resolved = Resolved()
    _ = bus.subscribe(CorrectionCandidateResolved.self) { resolved.ids.append($0.candidateID) }
    let bridge = VocabularyBridge(learning: learning, bus: bus)

    try await learning.recordEdit(original: "Alen", edited: "Allen", sourceApplication: "Mail")
    bridge.sync()
    let candidate = try #require(learning.candidates.first)
    try await learning.dismiss(id: candidate.id)
    bridge.sync()
    bridge.sync()

    #expect(resolved.ids == [candidate.id])
}
