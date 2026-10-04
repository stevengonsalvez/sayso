import Testing
@testable import SaysoCore

/// Transcripts produced by a real Apple Speech run in a separate scratch app (SFSpeechRecognizer on a macOS `say`
/// clip of "open Calculator", 2026-10-04) become fixtures here, so Control acceptance never needs a microphone.
private let appleSpeechTranscripts = [
    "Open calculator",
]

@Test func controlTryNowAcceptsTheRealAppleSpeechTranscript() {
    for transcript in appleSpeechTranscripts {
        #expect(ControlTryNowPolicy.acceptsTranscript(transcript))
    }
}

@Test func theCalculatorPlannerRecognisesTheAppleSpeechTranscriptAsAnOpenCommandWithoutAMathTask() {
    #expect(ControlPlanner.calculatorTask(from: "Open calculator") == nil)
}

@Test func nearMissTranscriptsFromSpeechRecognitionAreNotAccepted() {
    for transcript in ["Open the calculator", "Open Calculator and delete", "calculator", ""] {
        #expect(!ControlTryNowPolicy.acceptsTranscript(transcript))
    }
}
