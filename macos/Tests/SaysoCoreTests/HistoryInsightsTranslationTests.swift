import Testing
@testable import SaysoCore

@Test func historyInsightsCountDisplayedTranslationWords() {
    let translated = Transcript(
        text: "one",
        translatedText: "one two three",
        language: .english,
        route: .local,
        isFinal: true
    )

    #expect(HistoryInsights.make(from: [translated]).words == 3)
}
