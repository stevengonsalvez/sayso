import Foundation

/// Emitted by dictation and reprocessing when a final transcript should be kept.
public struct TranscriptCompleted: SaysoEvent {
    public let transcript: Transcript
    public init(transcript: Transcript) { self.transcript = transcript }
}

/// Emitted by the history module with the outcome of every save attempt.
public struct HistoryAppended: SaysoEvent, Equatable {
    public let transcriptID: Transcript.ID
    public let result: HistoryAppendResult
    public init(transcriptID: Transcript.ID, result: HistoryAppendResult) {
        self.transcriptID = transcriptID
        self.result = result
    }
}
