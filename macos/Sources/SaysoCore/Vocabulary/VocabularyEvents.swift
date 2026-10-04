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

/// A candidate left the store (promoted or dismissed from another surface); suggestions for it must go.
public struct CorrectionCandidateResolved: SaysoEvent, Equatable {
    public let candidateID: UUID
    public init(candidateID: UUID) { self.candidateID = candidateID }
}
