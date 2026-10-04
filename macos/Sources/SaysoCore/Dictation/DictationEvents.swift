import Foundation

/// The dictation pipeline moved to a new phase; emitted by whoever owns the transcriber.
public struct DictationPhaseChanged: SaysoEvent, Equatable {
    public let phase: SessionPhase
    public let errorMessage: String?
    public init(phase: SessionPhase, errorMessage: String? = nil) {
        self.phase = phase
        self.errorMessage = errorMessage
    }
}
