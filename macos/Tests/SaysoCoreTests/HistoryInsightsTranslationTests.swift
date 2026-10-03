import Foundation
@preconcurrency import AVFoundation
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

@Test func historyInsightsFormatDuration() {
    #expect(HistoryInsights.formatDuration(0) == "0s")
    #expect(HistoryInsights.formatDuration(-10) == "0s")
    #expect(HistoryInsights.formatDuration(35) == "35s")
    #expect(HistoryInsights.formatDuration(60) == "1m")
    #expect(HistoryInsights.formatDuration(125) == "2m 5s")
    #expect(HistoryInsights.formatDuration(765) == "12m 45s")
    #expect(HistoryInsights.formatDuration(3600) == "1h")
    #expect(HistoryInsights.formatDuration(3605) == "1h 5s")
    #expect(HistoryInsights.formatDuration(3660) == "1h 1m")
    #expect(HistoryInsights.formatDuration(3665) == "1h 1m 5s")
}

@Test func historyInsightsWordsPerMinuteCalculation() {
    let zeroDuration = Transcript(
        text: "hello world",
        language: .english,
        route: .local,
        isFinal: true,
        duration: 0
    )
    #expect(HistoryInsights.make(from: [zeroDuration]).averageWordsPerMinute == 0)

    let noWords = Transcript(
        text: "   ",
        language: .english,
        route: .local,
        isFinal: true,
        duration: 60
    )
    #expect(HistoryInsights.make(from: [noWords]).averageWordsPerMinute == 0)

    let sixtySeconds = Transcript(
        text: "word1 word2 word3 word4 word5",
        language: .english,
        route: .local,
        isFinal: true,
        duration: 60
    )
    #expect(HistoryInsights.make(from: [sixtySeconds]).averageWordsPerMinute == 5.0)

    let thirtySeconds = Transcript(
        text: "alpha beta gamma delta",
        language: .english,
        route: .local,
        isFinal: true,
        duration: 30
    )
    #expect(HistoryInsights.make(from: [thirtySeconds]).averageWordsPerMinute == 8.0)

    let translated = Transcript(
        text: "one",
        translatedText: "one two three four five six",
        language: .english,
        route: .local,
        isFinal: true,
        duration: 60
    )
    #expect(HistoryInsights.make(from: [translated]).averageWordsPerMinute == 6.0)

    let entry1 = Transcript(text: "one two", language: .english, route: .local, isFinal: true, duration: 15)
    let entry2 = Transcript(text: "three four", language: .english, route: .local, isFinal: true, duration: 15)
    let combinedInsights = HistoryInsights.make(from: [entry1, entry2])
    #expect(combinedInsights.words == 4)
    #expect(combinedInsights.totalDurationSeconds == 30.0)
    #expect(combinedInsights.formattedDuration == "30s")
    #expect(combinedInsights.averageWordsPerMinute == 8.0)
}

@Test func historyInsightsEstimatedCloudSpendCalculation() {
    let local = Transcript(
        text: "local transcription",
        language: .english,
        route: .local,
        isFinal: true,
        duration: 60
    )
    let apple = Transcript(
        text: "apple speech transcription",
        language: .english,
        route: .appleSpeech,
        isFinal: true,
        duration: 60
    )
    let byokOneMin = Transcript(
        text: "byok transcription",
        language: .english,
        route: .byok,
        isFinal: true,
        duration: 60
    )
    let byokThirtySec = Transcript(
        text: "byok transcription two",
        language: .english,
        route: .byok,
        isFinal: true,
        duration: 30
    )

    #expect(HistoryInsights.make(from: [local]).estimatedCloudSpendUSD == 0.0)
    #expect(HistoryInsights.make(from: [apple]).estimatedCloudSpendUSD == 0.0)
    #expect(HistoryInsights.make(from: [byokOneMin]).estimatedCloudSpendUSD == 0.006)
    #expect(HistoryInsights.make(from: [byokThirtySec]).estimatedCloudSpendUSD == 0.003)

    let mixedInsights = HistoryInsights.make(from: [local, apple, byokOneMin])
    #expect(mixedInsights.totalDurationSeconds == 180.0)
    #expect(mixedInsights.formattedDuration == "3m")
    #expect(mixedInsights.estimatedCloudSpendUSD == 0.006)

    let customRateInsights = HistoryInsights.make(from: [byokOneMin], cloudCostPerMinuteUSD: 0.012)
    #expect(customRateInsights.estimatedCloudSpendUSD == 0.012)
}

@Test func historyInsightsDurationFromAudioFileURL() throws {
    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: 16000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false
    ]

    do {
        let file = try AVAudioFile(forWriting: tempURL, settings: settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32000)!
        buffer.frameLength = 32000 // 2 seconds at 16kHz
        try file.write(from: buffer)
    }

    let audioTranscript = Transcript(
        text: "two seconds",
        language: .english,
        route: .byok,
        isFinal: true,
        audioFileURL: tempURL
    )

    let insights = HistoryInsights.make(from: [audioTranscript])
    #expect(insights.totalDurationSeconds == 2.0)
    #expect(insights.formattedDuration == "2s")
    #expect(insights.averageWordsPerMinute == 60.0)
    #expect(insights.estimatedCloudSpendUSD == (2.0 / 60.0) * 0.006)
}

@Test func historyStoreInsightsActorIntegration() async {
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = HistoryStore(fileURL: fileURL)

    let entry1 = Transcript(text: "quick brown fox", language: .english, route: .local, isFinal: true, duration: 30)
    let entry2 = Transcript(text: "jumps over dog", language: .english, route: .byok, isFinal: true, duration: 30)
    await store.append(entry1)
    await store.append(entry2)

    let insights = await store.insights()
    #expect(insights.entries == 2)
    #expect(insights.words == 6)
    #expect(insights.totalDurationSeconds == 60.0)
    #expect(insights.formattedDuration == "1m")
    #expect(insights.averageWordsPerMinute == 6.0)
    #expect(insights.estimatedCloudSpendUSD == 0.003)
}
