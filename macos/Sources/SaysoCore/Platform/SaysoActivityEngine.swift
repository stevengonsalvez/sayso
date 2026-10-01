import Foundation

public struct SaysoActivityEngine: Sendable {
    private struct Entry: Sendable {
        var activity: SaysoActivity
        var expiry: Date?
    }

    private var entries: [Entry] = []

    public init() {}

    /// Highest cost-to-miss first; ties keep first-published order.
    public var stack: [SaysoActivity] {
        entries.map(\.activity).enumerated()
            .sorted { ($0.element.kind, $1.offset) > ($1.element.kind, $0.offset) }
            .map(\.element)
    }

    public var primary: SaysoActivity? { stack.first }

    /// Replaces any activity with the same `moduleID + stackID` in place.
    public mutating func publish(_ activity: SaysoActivity, at now: Date = Date()) {
        let entry = Entry(activity: activity, expiry: activity.expiresAfter.map { now.addingTimeInterval($0) })
        if let index = entries.firstIndex(where: {
            $0.activity.moduleID == activity.moduleID && $0.activity.stackID == activity.stackID
        }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    /// Drops every activity whose expiry is at or before `now`.
    public mutating func tick(at now: Date) {
        entries.removeAll { ($0.expiry ?? .distantFuture) <= now }
    }
}
