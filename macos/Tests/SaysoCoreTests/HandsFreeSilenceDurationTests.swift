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
