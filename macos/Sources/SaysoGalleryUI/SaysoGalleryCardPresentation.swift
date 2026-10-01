import SaysoCore

/// Pure, testable mapping from a gallery scenario to how its card should look and behave.
public struct SaysoGalleryCardPresentation: Equatable, Sendable {
    public enum Tone: Equatable, Sendable { case normal, muted, warning, error }

    public let statusLabel: String
    public let tone: Tone
    public let showsGrantPrompt: Bool
    public let showsRetry: Bool
    public let isMuted: Bool
    public let animationsEnabled: Bool
    public let highContrast: Bool

    public init(scenario: SaysoGalleryScenario) {
        switch scenario.health {
        case .ready: (statusLabel, tone) = ("Ready", .normal)
        case .disabled: (statusLabel, tone) = ("Disabled", .muted)
        case .permissionRequired: (statusLabel, tone) = ("Permission needed", .warning)
        case .degraded: (statusLabel, tone) = ("Degraded", .warning)
        case .failed: (statusLabel, tone) = ("Failed", .error)
        case .quarantined: (statusLabel, tone) = ("Quarantined", .error)
        }
        showsGrantPrompt = scenario.health == .permissionRequired
        showsRetry = scenario.health == .failed || scenario.health == .quarantined
        isMuted = scenario.health == .disabled
        animationsEnabled = scenario.accessibility != .reduceMotion
        highContrast = scenario.accessibility == .increaseContrast
    }
}
