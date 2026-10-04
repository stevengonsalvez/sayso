import Foundation

/// Glue between module routes and the Studio window, kept pure so the app only supplies its tab numbers.
public enum SaysoStudioNavigation {
    public static func tab(for route: SaysoStudioRoute, moduleTabs: [String: Int], settingsTab: Int, defaultTab: Int) -> Int {
        switch route {
        case .module(let id, _): moduleTabs[id] ?? defaultTab
        case .permissionPrompt: settingsTab
        case .moduleList: defaultTab
        }
    }

    /// System permissions that back a capability; capabilities without one are always available.
    public static func permissions(for capability: SaysoCapability) -> [PermissionKind] {
        switch capability {
        case .microphone: [.microphone]
        case .accessibility: [.accessibility]
        default: []
        }
    }

    public static func isGranted(_ capability: SaysoCapability, grantedPermissions: Set<PermissionKind>) -> Bool {
        permissions(for: capability).allSatisfy(grantedPermissions.contains)
    }
}
