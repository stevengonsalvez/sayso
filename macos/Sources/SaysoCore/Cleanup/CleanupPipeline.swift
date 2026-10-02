import Foundation

public struct CleanupOutcome: Equatable, Sendable {
    public let text: String
    public let notice: String?
    public init(text: String, notice: String?) {
        self.text = text
        self.notice = notice
    }
}

/// Runs the chosen cleanup engine and applies the shared finishing steps; failures degrade to local rules.
public enum CleanupPipeline {
    public static let cloudUnavailableNotice = "Cloud cleanup unavailable. Applied smart rules."

    /// - Parameters:
    ///   - rulesOutput: text already produced by the local rules path, returned on any fallback.
    ///   - finish: smart formatting, profile post-processing, lexicon, pronunciations and corrections.
    @MainActor
    public static func run(
        text: String,
        route: CleanupRoute,
        rulesOutput: String,
        finish: @MainActor (String) -> String,
        localSLM: (@Sendable (String) async throws -> String)?,
        cloud: (@Sendable (String) async throws -> String)?
    ) async -> CleanupOutcome {
        switch route {
        case .rules:
            return CleanupOutcome(text: rulesOutput, notice: nil)
        case .localSLM:
            guard let localSLM, let cleaned = try? await localSLM(text) else {
                return CleanupOutcome(text: rulesOutput, notice: nil)
            }
            return CleanupOutcome(text: finish(cleaned), notice: nil)
        case .cloud:
            guard let cloud else { return CleanupOutcome(text: rulesOutput, notice: nil) }
            do {
                return CleanupOutcome(text: finish(try await cloud(text)), notice: nil)
            } catch {
                return CleanupOutcome(text: rulesOutput, notice: cloudUnavailableNotice)
            }
        }
    }
}
