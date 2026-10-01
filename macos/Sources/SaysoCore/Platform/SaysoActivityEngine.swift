import Foundation

public struct SaysoActivityEngine: Sendable {
    private var activities: [SaysoActivity] = []

    public init() {}

    /// Highest cost-to-miss first; ties keep first-published order.
    public var stack: [SaysoActivity] {
        activities.enumerated()
            .sorted { ($0.element.kind, $1.offset) > ($1.element.kind, $0.offset) }
            .map(\.element)
    }

    public var primary: SaysoActivity? { stack.first }

    /// Replaces any activity with the same `moduleID + stackID` in place.
    public mutating func publish(_ activity: SaysoActivity) {
        if let index = activities.firstIndex(where: {
            $0.moduleID == activity.moduleID && $0.stackID == activity.stackID
        }) {
            activities[index] = activity
        } else {
            activities.append(activity)
        }
    }
}
