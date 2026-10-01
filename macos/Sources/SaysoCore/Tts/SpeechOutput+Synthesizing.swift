import Foundation

// ponytail: SpeechOutput is main-actor isolated; @preconcurrency turns a wrong-thread call into a runtime check.
extension SpeechOutput: @preconcurrency SpeechSynthesizing {
    public func speak(_ plan: SpeechPlan) {
        speak(plan.text, language: plan.language, voiceIdentifier: plan.voiceID, rate: plan.rate)
    }
}
