import SaysoCore

/// Multi-criteria scenario filter. An empty set for a criterion means "any".
public struct SaysoGalleryFilter: Equatable, Sendable {
    public var moduleIDs: Set<String>
    public var surfaces: Set<SaysoModuleSurface>
    public var healths: Set<SaysoModuleHealth>
    public var accessibility: Set<SaysoAccessibilityMode>

    public init(
        moduleIDs: Set<String> = [],
        surfaces: Set<SaysoModuleSurface> = [],
        healths: Set<SaysoModuleHealth> = [],
        accessibility: Set<SaysoAccessibilityMode> = []
    ) {
        self.moduleIDs = moduleIDs
        self.surfaces = surfaces
        self.healths = healths
        self.accessibility = accessibility
    }

    public var isActive: Bool {
        !(moduleIDs.isEmpty && surfaces.isEmpty && healths.isEmpty && accessibility.isEmpty)
    }

    public func matches(_ scenario: SaysoGalleryScenario) -> Bool {
        (moduleIDs.isEmpty || moduleIDs.contains(scenario.moduleID))
            && (surfaces.isEmpty || surfaces.contains(scenario.surface))
            && (healths.isEmpty || healths.contains(scenario.health))
            && (accessibility.isEmpty || accessibility.contains(scenario.accessibility))
    }

    public func apply(to scenarios: [SaysoGalleryScenario]) -> [SaysoGalleryScenario] {
        scenarios.filter(matches)
    }
}
