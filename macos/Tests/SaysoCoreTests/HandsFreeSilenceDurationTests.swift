import Testing
@testable import SaysoCore

@Test @MainActor func handsFreeSilenceDurationDefaultsToCurrentDelay() {
    let transcriber = LiveTranscriber()

    #expect(transcriber.handsFreeSilenceDuration == .milliseconds(1_200))
}

@Test @MainActor func handsFreeSilenceDurationClampsToSafeRange() {
    #expect(
        LiveTranscriber.clampedHandsFreeSilenceDuration(.milliseconds(100))
            == LiveTranscriber.minimumHandsFreeSilenceDuration
    )
    #expect(
        LiveTranscriber.clampedHandsFreeSilenceDuration(.seconds(10))
            == LiveTranscriber.maximumHandsFreeSilenceDuration
    )
    #expect(
        LiveTranscriber.clampedHandsFreeSilenceDuration(.milliseconds(850))
            == .milliseconds(850)
    )
}

@Test @MainActor func handsFreeSilenceWaitsForSpeechBeforeStopping() {
    #expect(!LiveTranscriber.shouldScheduleHandsFreeStop(
        handsFree: true,
        isListening: true,
        hasHeardSpeech: false,
        inputLevel: 0
    ))
    #expect(!LiveTranscriber.shouldScheduleHandsFreeStop(
        handsFree: true,
        isListening: true,
        hasHeardSpeech: true,
        inputLevel: LiveTranscriber.handsFreeSpeechThreshold + 0.001
    ))
    #expect(LiveTranscriber.shouldScheduleHandsFreeStop(
        handsFree: true,
        isListening: true,
        hasHeardSpeech: true,
        inputLevel: 0
    ))
}
