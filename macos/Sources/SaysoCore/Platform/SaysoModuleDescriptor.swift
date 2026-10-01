import Foundation

public enum SaysoModuleHealth: Equatable, Sendable {
    case ready
    case disabled
    case permissionRequired
    case degraded
    case failed
    case quarantined
}

public struct SaysoModuleDescriptor: Equatable, Sendable {
    public let id: String
    public let title: String
    public let capabilities: Set<SaysoCapability>
    public let surfaces: Set<SaysoModuleSurface>

    public init(
        id: String,
        title: String,
        capabilities: Set<SaysoCapability> = [],
        surfaces: Set<SaysoModuleSurface> = [.compact, .expanded]
    ) {
        self.id = id
        self.title = title
        self.capabilities = capabilities
        self.surfaces = surfaces
    }
}
