import Foundation
import Testing
@testable import SaysoCore

private final class FakePort: VocabularyPort, @unchecked Sendable {
    var promoted: [UUID] = []
    var dismissed: [UUID] = []
    var failNext = false
    struct Boom: Error {}
    func promote(candidateID: UUID) async throws {
        if failNext { failNext = false; throw Boom() }
        promoted.append(candidateID)
    }
    func dismiss(candidateID: UUID) async throws { dismissed.append(candidateID) }
}

private final class Sink: @unchecked Sendable { var changes: [VocabularyChanged] = [] }

private func setup() -> (SaysoModuleHost, VocabularyModule, SaysoEventBus, FakePort, Sink) {
    let bus = SaysoEventBus(), port = FakePort(), sink = Sink()
    let module = VocabularyModule(port: port)
    _ = bus.subscribe(VocabularyChanged.self) { sink.changes.append($0) }
    let host = SaysoModuleHost(modules: [module], events: bus)
    host.enable("vocabulary")
    return (host, module, bus, port, sink)
}

private func candidate(_ id: UUID = UUID()) -> CorrectionCandidateReady {
    CorrectionCandidateReady(candidateID: id, source: "sayso", replacement: "Sayso")
}

@Test func readyCandidateBecomesASuggestionWithAcceptAndDismiss() {
    let (host, _, bus, _, _) = setup()
    let id = UUID()
    bus.publish(candidate(id))

    let suggestion = host.engine.stack.first
    #expect(suggestion?.title == "Remember “sayso” as “Sayso”?")
    #expect(suggestion?.kind == .activeTask)
    #expect(suggestion?.actions.map(\.id) == ["accept", "dismiss"])
    #expect(suggestion?.interruption == .normal)
}

@Test func acceptingPromotesTheCandidateClearsTheSuggestionAndAnnouncesTheChange() async {
    let (host, module, bus, port, sink) = setup()
    let id = UUID()
    bus.publish(candidate(id))

    #expect(host.perform(actionID: "accept", stackID: "candidate-\(id)", moduleID: "vocabulary"))
    await module.waitUntilIdle()

    #expect(port.promoted == [id])
    #expect(host.engine.stack.isEmpty)
    #expect(sink.changes == [VocabularyChanged()])
}

@Test func dismissingNeverPromotes() async {
    let (host, module, bus, port, _) = setup()
    let id = UUID()
    bus.publish(candidate(id))

    #expect(host.perform(actionID: "dismiss", stackID: "candidate-\(id)", moduleID: "vocabulary"))
    await module.waitUntilIdle()

    #expect(port.dismissed == [id])
    #expect(port.promoted.isEmpty)
    #expect(host.engine.stack.isEmpty)
}

@Test func failedPromotionKeepsTheSuggestionAndShowsRetryableFailure() async {
    let (host, module, bus, port, sink) = setup()
    let id = UUID()
    port.failNext = true
    bus.publish(candidate(id))

    _ = host.perform(actionID: "accept", stackID: "candidate-\(id)", moduleID: "vocabulary")
    await module.waitUntilIdle()

    #expect(host.engine.stack.map(\.title).contains("Could not save correction"))
    #expect(host.engine.stack.contains { $0.stackID == "candidate-\(id)" })
    #expect(sink.changes.isEmpty)

    _ = host.perform(actionID: "accept", stackID: "candidate-\(id)", moduleID: "vocabulary")
    await module.waitUntilIdle()
    #expect(port.promoted == [id])
    #expect(host.engine.stack.isEmpty)
}

@Test func duplicateCandidateReplacesItsSuggestionAndDisabledModuleIgnoresCandidates() {
    let (host, _, bus, _, _) = setup()
    let id = UUID()
    bus.publish(candidate(id))
    bus.publish(candidate(id))
    #expect(host.engine.stack.count == 1)

    host.disable("vocabulary")
    bus.publish(candidate())
    #expect(host.engine.stack.isEmpty)
}

@Test func vocabularyModulePassesTheGenericAcceptanceHarness() {
    #expect(SaysoModuleAcceptance.violations(for: VocabularyModule(port: FakePort())) == [])
}

@Test func resolvedCandidateElsewhereClearsItsSuggestion() {
    let (host, _, bus, _, _) = setup()
    let id = UUID()
    bus.publish(candidate(id))
    #expect(host.engine.stack.count == 1)

    bus.publish(CorrectionCandidateResolved(candidateID: id))
    #expect(host.engine.stack.isEmpty)
}
