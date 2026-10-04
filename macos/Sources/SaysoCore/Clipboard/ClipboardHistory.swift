import Foundation

public struct ClipboardHistory: Equatable, Sendable {
    public struct Entry: Equatable, Identifiable, Sendable {
        public let id: UUID
        public let text: String
        public let copiedAt: Date
    }

    public static let supportedLimits = [40, 100, 200, 500]

    public private(set) var entries: [Entry] = []
    public private(set) var limit: Int

    public init(limit: Int = 40) {
        self.limit = Self.supportedLimits.contains(limit) ? limit : 40
    }

    /// Re-copying existing text moves it to the front instead of duplicating it.
    public mutating func add(_ text: String, at date: Date) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        entries.removeAll { $0.text == text }
        entries.insert(Entry(id: UUID(), text: text, copiedAt: date), at: 0)
        trim()
    }

    public mutating func setLimit(_ newLimit: Int) {
        guard Self.supportedLimits.contains(newLimit) else { return }
        limit = newLimit
        trim()
    }

    public mutating func remove(id: Entry.ID) { entries.removeAll { $0.id == id } }

    public mutating func clear() { entries = [] }

    private mutating func trim() {
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }
}
