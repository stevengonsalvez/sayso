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

    public enum Action: Equatable, Sendable { case grant, retry }

    /// Lightest colour of the expanded-surface gradient: the worst-case background for white text.
    public static let surfaceTop: (r: Double, g: Double, b: Double) = (0.09, 0.10, 0.12)
    public static let surfaceBottom: (r: Double, g: Double, b: Double) = (0.03, 0.03, 0.04)

    /// The pulse runs only if neither the scenario nor the system asks for reduced motion.
    public func pulseEnabled(systemReduceMotion: Bool) -> Bool {
        animationsEnabled && !systemReduceMotion
    }

    public func usesHighContrast(systemIncreaseContrast: Bool) -> Bool {
        highContrast || systemIncreaseContrast
    }

    public func offersGrantAction(hasHandler: Bool) -> Bool { showsGrantPrompt && hasHandler }
    public func offersRetryAction(hasHandler: Bool) -> Bool { showsRetry && hasHandler }

    /// Alpha of white secondary text, including the dimming applied to disabled cards.
    public func secondaryTextOpacity(highContrast: Bool) -> Double {
        let base = highContrast ? 0.92 : 0.60
        // Disabled cards dim text, but never below AA (4.5:1) when Increase Contrast is on.
        let dim = isMuted ? (highContrast ? 0.65 : 0.45) : 1
        return base * dim
    }

    public static func actionSummary(_ action: Action, scenarioID: String) -> String {
        switch action {
        case .grant: "Grant requested: \(scenarioID)"
        case .retry: "Retry requested: \(scenarioID)"
        }
    }
}
