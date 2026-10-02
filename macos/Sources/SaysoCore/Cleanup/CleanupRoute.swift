import Foundation

/// Which cleanup engine handles a transcript; a missing cloud prerequisite falls back to local rules.
public enum CleanupRoute: Equatable, Sendable {
    case rules
    case localSLM
    case cloud

    public static func resolve(
        mode: CleanupMode,
        cloudCleanupEnabled: Bool,
        byokConsentGranted: Bool,
        hasCloudKey: Bool,
        hasCloudBaseURL: Bool,
        hasCloudModel: Bool
    ) -> CleanupRoute {
        if mode == .localSLM { return .localSLM }
        guard mode == .cloudLLM || cloudCleanupEnabled, byokConsentGranted,
              hasCloudKey, hasCloudBaseURL, hasCloudModel else { return .rules }
        return .cloud
    }
}
