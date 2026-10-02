import Foundation

/// Connects the real correction store to the vocabulary module: announces new candidates as events and
/// carries out accept/dismiss. The app calls `sync()` whenever the store changes.
@MainActor
public final class VocabularyBridge: VocabularyPort {
    public struct UnknownCandidate: Error {}

    private let learning: SaysoCorrectionLearning
    private let bus: SaysoEventBus
    private var announced: Set<UUID> = []

    public init(learning: SaysoCorrectionLearning, bus: SaysoEventBus) {
        self.learning = learning
        self.bus = bus
    }

    /// Emits `CorrectionCandidateReady` once per candidate id.
    public func sync() {
        for candidate in learning.candidates where announced.insert(candidate.id).inserted {
            bus.publish(CorrectionCandidateReady(
                candidateID: candidate.id, source: candidate.original, replacement: candidate.corrected
            ))
        }
    }

    public func promote(candidateID: UUID) async throws {
        guard let candidate = learning.candidates.first(where: { $0.id == candidateID }) else { throw UnknownCandidate() }
        try await learning.promote(candidate)
    }

    public func dismiss(candidateID: UUID) async throws {
        try await learning.dismiss(id: candidateID)
    }
}
