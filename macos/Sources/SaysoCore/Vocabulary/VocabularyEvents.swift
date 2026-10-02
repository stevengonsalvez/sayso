import Foundation

/// An automatic correction reached its promotion threshold and can be offered to the user.
public struct CorrectionCandidateReady: SaysoEvent, Equatable {
    public let candidateID: UUID
    public let source: String
    public let replacement: String
    public init(candidateID: UUID, source: String, replacement: String) {
        self.candidateID = candidateID
        self.source = source
        self.replacement = replacement
    }
}

/// The personal vocabulary changed; consumers that cache rules should reload.
public struct VocabularyChanged: SaysoEvent, Equatable {
    public init() {}
}
