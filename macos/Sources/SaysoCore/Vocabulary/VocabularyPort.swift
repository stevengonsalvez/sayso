import Foundation

/// Boundary to correction storage; `SaysoCorrectionLearning` adapts to it.
public protocol VocabularyPort: Sendable {
    func promote(candidateID: UUID) async throws
    func dismiss(candidateID: UUID) async throws
}
