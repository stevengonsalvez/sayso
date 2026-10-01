import Foundation

public struct SaysoActivityEngine: Sendable {
    private struct Entry: Sendable {
        var activity: SaysoActivity
        var expiry: Date?
        /// Persistent activity this temporary alert shadows; restored when the alert expires.
        var restore: SaysoActivity?
    }

    private var entries: [Entry] = []
    private var pinned: (moduleID: String, stackID: String)?

    public init() {}

    /// Highest cost-to-miss first; ties keep first-published order.
    public var stack: [SaysoActivity] {
        entries.map(\.activity).enumerated()
            .sorted { ($0.element.kind, $1.offset) > ($1.element.kind, $0.offset) }
            .map(\.element)
    }

    /// A user pin wins over automation; only a critical confirmation overrides it.
    public var primary: SaysoActivity? {
        let ranked = stack
        let pinnedHit = pinned.flatMap { pin in
            ranked.first { $0.moduleID == pin.moduleID && $0.stackID == pin.stackID }
        }
        if let pinnedHit, pinnedHit.kind == .confirmation { return pinnedHit }
        if let top = ranked.first, top.kind == .confirmation { return top }
        return pinnedHit ?? ranked.first
    }

    public mutating func pin(moduleID: String, stackID: String) {
        pinned = (moduleID, stackID)
    }

    public mutating func unpin() {
        pinned = nil
    }

    public mutating func dismiss(moduleID: String, stackID: String) {
        entries.removeAll { $0.activity.moduleID == moduleID && $0.activity.stackID == stackID }
        prunePin()
    }

    /// Replaces any activity with the same `moduleID + stackID` in place; a temporary alert
    /// remembers the persistent activity it replaced so expiry restores it.
    public mutating func publish(_ activity: SaysoActivity, at now: Date = Date()) {
        var entry = Entry(activity: activity, expiry: activity.expiresAfter.map { now.addingTimeInterval($0) })
        if let index = entries.firstIndex(where: {
            $0.activity.moduleID == activity.moduleID && $0.activity.stackID == activity.stackID
        }) {
            if entry.expiry != nil {
                entry.restore = entries[index].expiry == nil ? entries[index].activity : entries[index].restore
            }
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    /// Drops every activity whose expiry is at or before `now`, restoring any it shadowed.
    public mutating func tick(at now: Date) {
        entries = entries.compactMap { entry in
            guard let expiry = entry.expiry, expiry <= now else { return entry }
            return entry.restore.map { Entry(activity: $0, expiry: nil, restore: nil) }
        }
        prunePin()
    }

    public mutating func dismissAll(moduleID: String) {
        entries.removeAll { $0.activity.moduleID == moduleID }
        prunePin()
    }

    private mutating func prunePin() {
        guard let pin = pinned else { return }
        if !entries.contains(where: { $0.activity.moduleID == pin.moduleID && $0.activity.stackID == pin.stackID }) {
            pinned = nil
        }
    }
}
