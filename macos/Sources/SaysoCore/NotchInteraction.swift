import Foundation

public enum NotchInteractionRegion: Equatable, Sendable {
    case background
    case status
    case footer
    case outside
    case control
}

public enum NotchCollapsePolicy {
    public static func shouldCollapse(on region: NotchInteractionRegion) -> Bool {
        region != .control
    }
}
