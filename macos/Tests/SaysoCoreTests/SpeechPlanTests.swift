import Testing
@testable import SaysoCore

private func plan(
    _ text: String = "Hello",
    language: DictationLanguage? = nil,
    settingsLanguage: DictationLanguage = .english,
    voice: String? = nil,
    rate: Double = 0.5,
    installed: Set<String> = []
) -> SpeechPlan? {
    SpeechPlan.resolve(
        text: text, language: language, settingsLanguage: settingsLanguage,
        selectedVoiceID: voice, rate: rate, installedVoiceIDs: { _ in installed }
    )
}

@Test func emptyTextProducesNoPlan() {
    #expect(plan("") == nil)
}

@Test func missingOrAutomaticLanguageFallsBackToTheSettingsLanguage() {
    #expect(plan(language: nil, settingsLanguage: .hindi)?.language == .hindi)
    #expect(plan(language: .automatic, settingsLanguage: .hindi)?.language == .hindi)
    #expect(plan(language: .tamil, settingsLanguage: .hindi)?.language == .tamil)
}

@Test func selectedVoiceSurvivesOnlyWhenInstalledAndIgnoredForAutomaticLanguage() {
    #expect(plan(voice: "v1", installed: ["v1"])?.voiceID == "v1")
    #expect(plan(voice: "gone", installed: ["v1"])?.voiceID == nil)
    #expect(plan(settingsLanguage: .automatic, voice: "v1", installed: ["v1"])?.voiceID == nil)
}

@Test func rateIsClampedToTheSupportedRange() {
    #expect(plan(rate: 9)?.rate == 0.6)
    #expect(plan(rate: 0)?.rate == 0.2)
    #expect(plan(rate: 0.45)?.rate == 0.45)
}

@Test func voiceIsCheckedAgainstTheVoicesInstalledForTheResolvedLanguage() {
    let result = SpeechPlan.resolve(
        text: "Hi", language: nil, settingsLanguage: .hindi, selectedVoiceID: "hi-voice", rate: 0.5,
        installedVoiceIDs: { $0 == .hindi ? ["hi-voice"] : [] }
    )
    #expect(result?.voiceID == "hi-voice")

    let other = SpeechPlan.resolve(
        text: "Hi", language: .tamil, settingsLanguage: .hindi, selectedVoiceID: "hi-voice", rate: 0.5,
        installedVoiceIDs: { $0 == .hindi ? ["hi-voice"] : [] }
    )
    #expect(other?.voiceID == nil)
}
