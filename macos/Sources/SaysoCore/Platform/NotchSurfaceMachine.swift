import Foundation

/// Deterministic notch interaction state: no timers or AppKit, the caller feeds events with timestamps.
public struct NotchSurfaceMachine: Equatable, Sendable {
    public enum Surface: Equatable, Sendable { case hidden, closed, peek, expanded }
    public enum Event: Equatable, Sendable {
        case hoverEntered, hoverExited, topEdgeHover
        case click(NotchInteractionRegion)
        case swipe(SwipeDirection)
        case jump(Int)
    }
    public enum SwipeDirection: Equatable, Sendable { case previous, next }

    /// Hover time before the transport peek opens.
    public static let peekDelay: TimeInterval = 0.06

    public private(set) var surface: Surface
    public private(set) var selectedTab: String?
    private var tabs: [String]
    private let hidesWhenIdle: Bool
    private var hoverStartedAt: Date?

    public init(tabs: [String], startsHidden: Bool = false) {
        self.tabs = tabs
        self.selectedTab = tabs.first
        self.hidesWhenIdle = startsHidden
        self.surface = startsHidden ? .hidden : .closed
    }

    public mutating func setTabs(_ newTabs: [String]) {
        tabs = newTabs
        if let selectedTab, newTabs.contains(selectedTab) { return }
        selectedTab = newTabs.first
        if newTabs.isEmpty, surface == .expanded || surface == .peek { surface = idleSurface }
    }

    public mutating func tick(at now: Date) {
        guard surface == .closed, let start = hoverStartedAt, now.timeIntervalSince(start) >= Self.peekDelay - 1e-6 else { return }
        surface = .peek
    }

    public mutating func handle(_ event: Event, at now: Date) {
        switch event {
        case .hoverEntered:
            hoverStartedAt = now
        case .hoverExited:
            hoverStartedAt = nil
            if surface == .peek || (surface == .closed && hidesWhenIdle) { surface = idleSurface }
        case .topEdgeHover:
            if surface == .hidden { surface = .closed }
        case .click(let region):
            if surface == .expanded {
                if NotchCollapsePolicy.shouldCollapse(on: region) { surface = idleSurface }
            } else if surface != .hidden, region != .outside, !tabs.isEmpty {
                surface = .expanded
            }
        case .swipe(let direction):
            guard surface == .expanded, let selectedTab, let index = tabs.firstIndex(of: selectedTab) else { return }
            let target = direction == .next ? index + 1 : index - 1
            if tabs.indices.contains(target) { self.selectedTab = tabs[target] }
        case .jump(let number):
            guard tabs.indices.contains(number - 1) else { return }
            selectedTab = tabs[number - 1]
            surface = .expanded
        }
    }

    private var idleSurface: Surface { hidesWhenIdle ? .hidden : .closed }
}
