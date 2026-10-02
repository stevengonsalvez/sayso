import Foundation
import Testing
@testable import SaysoCore

private final class Stops: @unchecked Sendable { var count = 0 }

private func setup() -> (SaysoModuleHost, SaysoEventBus, Stops) {
    let bus = SaysoEventBus(), stops = Stops()
    _ = bus.subscribe(DictationStopRequested.self) { _ in stops.count += 1 }
    let host = SaysoModuleHost(modules: [DictationModule()], events: bus)
    host.enable("dictation")
    return (host, bus, stops)
}

@Test func listeningShowsAStoppableActivityThatBecomesTranscribing() {
    let (host, bus, stops) = setup()
    bus.publish(DictationLifecycleEvent.listening)
    #expect(host.engine.stack.map(\.title) == ["Listening"])
    #expect(host.engine.stack.first?.kind == .activeTask)
    #expect(host.engine.stack.first?.actions.map(\.id) == ["stop"])

    #expect(host.perform(actionID: "stop", stackID: "session", moduleID: "dictation"))
    #expect(stops.count == 1)

    bus.publish(DictationLifecycleEvent.processing)
    #expect(host.engine.stack.map(\.title) == ["Transcribing"])
    #expect(host.engine.stack.first?.actions.isEmpty == true)
    #expect(!host.perform(actionID: "stop", stackID: "session", moduleID: "dictation"))
}

@Test func finishedAndCancelledClearTheSessionWhileFailureLeavesAnExpiringNotice() {
    let (host, bus, _) = setup()
    bus.publish(DictationLifecycleEvent.listening)
    bus.publish(DictationLifecycleEvent.ended(.finished))
    #expect(host.engine.stack.isEmpty)

    bus.publish(DictationLifecycleEvent.listening)
    bus.publish(DictationLifecycleEvent.ended(.cancelled))
    #expect(host.engine.stack.isEmpty)

    bus.publish(DictationLifecycleEvent.listening)
    bus.publish(DictationLifecycleEvent.ended(.failed))
    #expect(host.engine.stack.map(\.title) == ["Dictation failed"])
    #expect(host.engine.stack.first?.kind == .failure)
    #expect(host.engine.stack.first?.expiresAfter != nil)
}

@Test func disabledDictationIgnoresLifecycleEvents() {
    let (host, bus, _) = setup()
    host.disable("dictation")
    bus.publish(DictationLifecycleEvent.listening)
    #expect(host.engine.stack.isEmpty)
}

@Test func dictationModulePassesTheGenericAcceptanceHarness() {
    #expect(SaysoModuleAcceptance.violations(for: DictationModule()) == [])
}
