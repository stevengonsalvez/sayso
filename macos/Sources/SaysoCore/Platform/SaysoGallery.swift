import Foundation

public enum SaysoAccessibilityMode: String, CaseIterable, Sendable {
    case standard, reduceMotion, increaseContrast
}

public struct SaysoGalleryScenario: Equatable, Sendable {
    public let id: String
    public let moduleID: String
    public let title: String
    public let surface: SaysoModuleSurface
    public let health: SaysoModuleHealth
    public let accessibility: SaysoAccessibilityMode
}

/// Synthetic scenarios for every surface, health state and accessibility mode, with no live OS events.
public enum SaysoGallery {
    public static func scenarios(for descriptors: [SaysoModuleDescriptor]) -> [SaysoGalleryScenario] {
        descriptors.flatMap { descriptor in
            let states = healthStates(for: descriptor)
            return SaysoModuleSurface.allCases.filter(descriptor.surfaces.contains).flatMap { surface in
                states.flatMap { health in
                    SaysoAccessibilityMode.allCases.map { mode in
                        SaysoGalleryScenario(
                            id: "\(descriptor.id).\(surface.rawValue).\(health).\(mode.rawValue)",
                            moduleID: descriptor.id,
                            title: descriptor.title,
                            surface: surface,
                            health: health,
                            accessibility: mode
                        )
                    }
                }
            }
        }
    }

    private static func healthStates(for descriptor: SaysoModuleDescriptor) -> [SaysoModuleHealth] {
        var states: [SaysoModuleHealth] = [.ready, .disabled]
        if !descriptor.capabilities.isEmpty { states.append(.permissionRequired) }
        return states + [.degraded, .failed, .quarantined]
    }
}
