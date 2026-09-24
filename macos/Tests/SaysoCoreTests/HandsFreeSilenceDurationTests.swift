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

@Test @MainActor func handsFreeMaximumDurationDefaultsAndClampsToSafeRange() {
    let transcriber = LiveTranscriber()

    #expect(transcriber.handsFreeMaximumDuration == .seconds(900))
    #expect(
        LiveTranscriber.clampedHandsFreeMaximumDuration(.seconds(1))
            == LiveTranscriber.minimumHandsFreeMaximumDuration
    )
    #expect(
        LiveTranscriber.clampedHandsFreeMaximumDuration(.seconds(3_601))
            == LiveTranscriber.maximumHandsFreeMaximumDuration
    )
    #expect(LiveTranscriber.clampedHandsFreeMaximumDuration(.seconds(600)) == .seconds(600))
}

@Test @MainActor func handsFreeSilenceWaitsForSustainedSpeechBeforeStopping() {
    var gate = HandsFreeSpeechGate()
    for _ in 0..<(HandsFreeSpeechGate.requiredSpeechFrames - 1) {
        gate.observe(level: LiveTranscriber.handsFreeSpeechThreshold + 0.001, threshold: LiveTranscriber.handsFreeSpeechThreshold)
    }
    #expect(!gate.hasHeardSpeech)

    gate.observe(level: LiveTranscriber.handsFreeSpeechThreshold + 0.001, threshold: LiveTranscriber.handsFreeSpeechThreshold)
    #expect(gate.hasHeardSpeech)

    var interruptedGate = HandsFreeSpeechGate()
    interruptedGate.observe(level: LiveTranscriber.handsFreeSpeechThreshold + 0.001, threshold: LiveTranscriber.handsFreeSpeechThreshold)
    interruptedGate.observe(level: 0, threshold: LiveTranscriber.handsFreeSpeechThreshold)
    for _ in 0..<HandsFreeSpeechGate.requiredSpeechFrames {
        interruptedGate.observe(level: LiveTranscriber.handsFreeSpeechThreshold + 0.001, threshold: LiveTranscriber.handsFreeSpeechThreshold)
    }
    #expect(interruptedGate.hasHeardSpeech)
    #expect(LiveTranscriber.defaultHandsFreeNoSpeechDuration == .seconds(8))
}
