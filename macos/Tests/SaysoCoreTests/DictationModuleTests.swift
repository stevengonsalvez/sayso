import Foundation
import Testing
@testable import SaysoCore

private func setup() -> (SaysoModuleHost, SaysoEventBus) {
    let bus = SaysoEventBus()
    let host = SaysoModuleHost(modules: [DictationModule()], events: bus)
    host.enable("dictation")
    return (host, bus)
}

private func phase(_ p: SessionPhase, error: String? = nil) -> DictationPhaseChanged {
    DictationPhaseChanged(phase: p, errorMessage: error)
}

@Test func phasesMapToOneUpdatingActivity() {
    let (host, bus) = setup()
    #expect(host.engine.stack.isEmpty)

    bus.publish(phase(.requestingPermission))
    #expect(host.engine.stack.map(\.title) == ["Waiting for microphone permission"])

    bus.publish(phase(.listening))
    #expect(host.engine.stack.map(\.title) == ["Listening"])
    #expect(host.engine.stack.first?.kind == .activeTask)

    bus.publish(phase(.processing))
    #expect(host.engine.stack.map(\.title) == ["Transcribing"])
    #expect(host.engine.stack.count == 1)

    bus.publish(phase(.idle))
    #expect(host.engine.stack.isEmpty)
}

@Test func speakingAndIdleClearTheActivity() {
    let (host, bus) = setup()
    bus.publish(phase(.listening))
    bus.publish(phase(.speaking))
    #expect(host.engine.stack.isEmpty)
}

@Test func failureShowsTheErrorMessageAndExpiresWithoutRestoringTheOldPhase() {
    let t0 = Date(timeIntervalSince1970: 500)
    final class Clock: @unchecked Sendable { var now: Date; init(_ n: Date) { now = n } }
    let clock = Clock(t0), bus = SaysoEventBus()
    let host = SaysoModuleHost(modules: [DictationModule()], now: { clock.now }, events: bus)
    host.enable("dictation")

    bus.publish(phase(.listening))
    bus.publish(phase(.failed, error: "Microphone is in use"))
    let failure = host.engine.stack.first
    #expect(failure?.kind == .failure)
    #expect(failure?.title == "Microphone is in use")
    #expect(failure?.expiresAfter != nil)

    clock.now += 60
    host.tick()
    #expect(host.engine.stack.isEmpty)
}

@Test func failureWithoutAMessageUsesAGenericTitle() {
    let (host, bus) = setup()
    bus.publish(phase(.failed))
    #expect(host.engine.stack.first?.title == "Dictation failed")
}

@Test func disabledDictationModuleIgnoresPhases() {
    let (host, bus) = setup()
    host.disable("dictation")
    bus.publish(phase(.listening))
    #expect(host.engine.stack.isEmpty)
}

@Test func dictationModulePassesTheGenericAcceptanceHarness() {
    #expect(SaysoModuleAcceptance.violations(for: DictationModule()) == [])
}
