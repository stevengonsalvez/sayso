import Foundation
import Testing
@testable import SaysoCore

private final class FakeSynth: SpeechSynthesizing, @unchecked Sendable {
    var spoken: [SpeechPlan] = []
    var stops = 0
    var speaking = false
    var onFinish: (@Sendable () -> Void)?
    var isSpeaking: Bool { speaking }
    func speak(_ plan: SpeechPlan) { spoken.append(plan); speaking = true }
    func stop() { stops += 1; speaking = false }
    func finish() { speaking = false; onFinish?() }
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
    #expect(synth.stops == 1)
    #expect(host.engine.stack.isEmpty)
}

@Test func naturalFinishClearsTheActivity() {
    let synth = FakeSynth()
    let (host, module) = makeHost(synth)
    host.enable("tts")
    module.speak(plan)

    synth.finish()
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
