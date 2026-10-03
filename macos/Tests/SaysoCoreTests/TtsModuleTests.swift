import Foundation
import Testing
@testable import SaysoCore

/// Mirrors the real boundary: stop and replacement cancel asynchronously, reported later via `pump()`.
private final class FakeSynth: SpeechSynthesizing, @unchecked Sendable {
    var spoken: [SpeechPlan] = []
    var stops = 0
    var current: Int?
    var nextID = 0
    var pending: [Int] = []
    var onFinish: (@Sendable (Int) -> Void)?
    var isSpeaking: Bool { current != nil }

    func speak(_ plan: SpeechPlan) -> Int {
        if let current { pending.append(current) }
        spoken.append(plan)
        nextID += 1
        current = nextID
        return nextID
    }
    func stop() {
        stops += 1
        if let current { pending.append(current) }
        current = nil
    }
    /// Delivers deferred finish/cancel notifications, like the real delegate's main-actor hop.
    func pump() { let ids = pending; pending = []; ids.forEach { onFinish?($0) } }
    func finishNaturally() { if let id = current { current = nil; onFinish?(id) } }
}

private func makeHost(_ synth: FakeSynth) -> (SaysoModuleHost, TtsModule) {
    let module = TtsModule(synthesizer: synth)
    return (SaysoModuleHost(modules: [module]), module)
}

private let plan = SpeechPlan(text: "Hello", language: .english, voiceID: nil, rate: 0.5)

@Test func speakingForwardsThePlanAndShowsAStoppableActivity() {
    let synth = FakeSynth()
    let (host, module) = makeHost(synth)
    host.enable("tts")

    module.speak(plan)

    #expect(synth.spoken == [plan])
    #expect(host.engine.stack.map(\.title) == ["Speaking"])
    #expect(host.engine.stack.first?.actions.map(\.id) == ["stop"])
}

@Test func stopActionStopsSpeechAndClearsTheActivity() {
    let synth = FakeSynth()
    let (host, module) = makeHost(synth)
    host.enable("tts")
    module.speak(plan)

    #expect(host.perform(actionID: "stop", stackID: "speaking", moduleID: "tts"))
    synth.pump()
    #expect(synth.stops == 1)
    #expect(host.engine.stack.isEmpty)
}

@Test func naturalFinishClearsTheActivity() {
    let synth = FakeSynth()
    let (host, module) = makeHost(synth)
    host.enable("tts")
    module.speak(plan)

    synth.finishNaturally()
    #expect(host.engine.stack.isEmpty)
}

@Test func disablingStopsSpeechAndReleasesEverything() {
    let synth = FakeSynth()
    let (host, module) = makeHost(synth)
    host.enable("tts")
    module.speak(plan)

    host.disable("tts")
    #expect(synth.stops == 1)
    #expect(synth.onFinish == nil)
    #expect(host.engine.stack.isEmpty)
}

@Test func ttsModulePassesTheGenericAcceptanceHarness() {
    #expect(SaysoModuleAcceptance.violations(for: TtsModule(synthesizer: FakeSynth())) == [])
}

@Test func replacingAnUtteranceKeepsTheActivityOfTheNewOne() {
    let synth = FakeSynth()
    let (host, module) = makeHost(synth)
    host.enable("tts")
    module.speak(plan)
    module.speak(SpeechPlan(text: "Second", language: .english, voiceID: nil, rate: 0.5))

    synth.pump()
    #expect(host.engine.stack.map(\.title) == ["Speaking"])

    synth.finishNaturally()
    #expect(host.engine.stack.isEmpty)
}

@Test func speakingWhileDisabledOrAfterDisableDoesNothing() {
    let synth = FakeSynth()
    let (host, module) = makeHost(synth)
    module.speak(plan)
    #expect(synth.spoken.isEmpty)

    host.enable("tts")
    host.disable("tts")
    module.speak(plan)
    #expect(synth.spoken.isEmpty)
}
