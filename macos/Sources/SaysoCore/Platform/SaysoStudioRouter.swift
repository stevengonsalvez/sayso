import Foundation

public enum SaysoStudioRoute: Equatable, Sendable {
    case module(id: String, surface: SaysoModuleSurface)
    case permissionPrompt(id: String, capabilities: Set<SaysoCapability>)
    case moduleList
}

/// Decides where Studio sends the user for a module, so notch taps and deep links share one rule.
public enum SaysoStudioRouter {
    public static func route(
        moduleID: String,
        descriptors: [SaysoModuleDescriptor],
        health: (String) -> SaysoModuleHealth,
        isGranted: (SaysoCapability) -> Bool
    ) -> SaysoStudioRoute {
        guard let descriptor = descriptors.first(where: { $0.id == moduleID }) else { return .moduleList }
        switch health(moduleID) {
        case .permissionRequired:
            let missing = descriptor.capabilities.filter { !isGranted($0) }
            return .permissionPrompt(id: moduleID, capabilities: missing)
        case .disabled, .failed, .quarantined:
            return .module(id: moduleID, surface: first(of: [.settings, .detail, .expanded, .compact], in: descriptor))
        case .ready, .degraded:
            return .module(id: moduleID, surface: first(of: [.detail, .settings, .expanded, .compact], in: descriptor))
        }
    }

    private static func first(of order: [SaysoModuleSurface], in descriptor: SaysoModuleDescriptor) -> SaysoModuleSurface {
        order.first(where: descriptor.surfaces.contains) ?? descriptor.surfaces.sorted { $0.rawValue < $1.rawValue }.first ?? .settings
    }
}
