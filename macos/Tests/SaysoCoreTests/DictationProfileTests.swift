import Testing
@testable import SaysoCore

@Test func defaultDictationProfileKeepsTextUntouched() {
    #expect(DictationProfile.default.postProcess("  leave this alone  ") == "  leave this alone  ")
}

@Test func dictationProfilePrefersLongestCorrectionPhrase() {
    let profile = DictationProfile(
        name: "Sayso",
        corrections: [
            .init(source: "say", replacement: "SAY"),
            .init(source: "say so", replacement: "Sayso"),
        ]
    )

    #expect(profile.postProcess("say so say") == "Sayso SAY")
}

@Test func dictationProfilePostProcessingIsIdempotent() {
    let profile = DictationProfile(
        name: "Polished",
        corrections: [.init(source: "say so", replacement: "Sayso")],
        normalizesWhitespace: true,
        capitalizesSentences: true
    )
    let once = profile.postProcess("  say so!   welcome back.  ")

    #expect(once == "Sayso! Welcome back.")
    #expect(profile.postProcess(once) == once)
}
