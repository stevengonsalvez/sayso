import Foundation
import Testing
@testable import SaysoCore

private final class FakePort: HistoryPort, @unchecked Sendable {
    var results: [HistoryAppendResult] = []
    var appended: [Transcript] = []
    func append(_ transcript: Transcript) async -> HistoryAppendResult {
        appended.append(transcript)
        return results.isEmpty ? .saved : results.removeFirst()
    }
}

private final class Sink: @unchecked Sendable { var appended: [HistoryAppended] = [] }

private func transcript(_ text: String = "hello") -> Transcript {
    Transcript(text: text, language: .english, route: .local)
}

private func makeHost(_ port: FakePort) -> (SaysoModuleHost, HistoryModule, SaysoEventBus, Sink) {
    let bus = SaysoEventBus()
    let module = HistoryModule(port: port)
    let sink = Sink()
    _ = bus.subscribe(HistoryAppended.self) { sink.appended.append($0) }
    return (SaysoModuleHost(modules: [module], events: bus), module, bus, sink)
}

@Test func completedTranscriptsAreAppendedOnceAndAnnounced() async {
    let port = FakePort()
    let (host, module, bus, sink) = makeHost(port)
    host.enable("history")
    let t = transcript()

    bus.publish(TranscriptCompleted(transcript: t))
    await module.waitUntilIdle()

    #expect(port.appended == [t])
    #expect(sink.appended == [HistoryAppended(transcriptID: t.id, result: .saved)])
    #expect(host.engine.stack.isEmpty)
}

@Test func failedSaveShowsRetryableFailureAndRetrySucceeds() async {
    let port = FakePort()
    port.results = [.failed, .saved]
    let (host, module, bus, sink) = makeHost(port)
    host.enable("history")
    let t = transcript()

    bus.publish(TranscriptCompleted(transcript: t))
    await module.waitUntilIdle()

    #expect(sink.appended.map(\.result) == [.failed])
    #expect(host.engine.stack.map(\.title) == ["History could not save"])
    #expect(host.engine.stack.first?.kind == .failure)

    #expect(host.perform(actionID: "retry", stackID: "save-failed", moduleID: "history"))
    await module.waitUntilIdle()

    #expect(port.appended == [t, t])
    #expect(sink.appended.map(\.result) == [.failed, .saved])
    #expect(host.engine.stack.isEmpty)
}

@Test func recoveredHistoryShowsAnExpiringNotice() async {
    let port = FakePort()
    port.results = [.recovered]
    let (host, module, bus, _) = makeHost(port)
    host.enable("history")

    bus.publish(TranscriptCompleted(transcript: transcript()))
    await module.waitUntilIdle()

    let notice = host.engine.stack.first
    #expect(notice?.title == "Recovered unreadable history to a local backup")
    #expect(notice?.expiresAfter != nil)
}

@Test func disabledHistoryIgnoresTranscripts() async {
    let port = FakePort()
    let (host, module, bus, sink) = makeHost(port)
    host.enable("history")
    host.disable("history")

    bus.publish(TranscriptCompleted(transcript: transcript()))
    await module.waitUntilIdle()

    #expect(port.appended.isEmpty)
    #expect(sink.appended.isEmpty)
}

@Test func historyModulePassesTheGenericAcceptanceHarness() {
    #expect(SaysoModuleAcceptance.violations(for: HistoryModule(port: FakePort())) == [])
}
