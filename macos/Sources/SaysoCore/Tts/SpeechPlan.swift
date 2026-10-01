import Foundation

/// Deterministic speech decision: language, voice and rate, with no AVFoundation dependency.
public struct SpeechPlan: Equatable, Sendable {
    public let text: String
    public let language: DictationLanguage
    public let voiceID: String?
    public let rate: Double

    public static let rateRange: ClosedRange<Double> = 0.2...0.6

    public static func resolve(
        text: String,
        language: DictationLanguage?,
        settingsLanguage: DictationLanguage,
        selectedVoiceID: String?,
        rate: Double,
        availableVoiceIDs: Set<String>
    ) -> SpeechPlan? {
        guard !text.isEmpty else { return nil }
        let resolved = (language == nil || language == .automatic) ? settingsLanguage : language!
        let voice = resolved == .automatic ? nil : selectedVoiceID.flatMap { availableVoiceIDs.contains($0) ? $0 : nil }
        let clamped = min(max(rate, rateRange.lowerBound), rateRange.upperBound)
        return SpeechPlan(text: text, language: resolved, voiceID: voice, rate: clamped)
    }
}
