import Foundation

public struct HistoryInsights: Equatable, Sendable {
    public let entries: Int
    public let words: Int
    public let activeDays: Int

    public init(entries: Int, words: Int, activeDays: Int) {
        self.entries = entries; self.words = words; self.activeDays = activeDays
    }

    public static func make(from entries: [Transcript], calendar: Calendar = .current) -> HistoryInsights {
        let days = Set(entries.map { calendar.startOfDay(for: $0.createdAt) })
        return .init(entries: entries.count, words: entries.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }, activeDays: days.count)
    }
}

public actor HistoryStore {
    private let fileURL: URL
    private let maximumEntries: Int

    public init(
        fileManager: FileManager = .default,
        maximumEntries: Int = 500
    ) {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SaysoNotch", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        self.fileURL = root.appendingPathComponent("history.json")
        self.maximumEntries = maximumEntries
    }

    public init(fileURL: URL, maximumEntries: Int = 500) {
        self.fileURL = fileURL
        self.maximumEntries = maximumEntries
    }

    public func all() -> [Transcript] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Transcript].self, from: data)) ?? []
    }

    public func append(_ transcript: Transcript) {
        guard transcript.isFinal, !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var entries = all()
        entries.insert(transcript, at: 0)
        if entries.count > maximumEntries { entries.removeLast(entries.count - maximumEntries) }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    public func plainTextExport() -> String {
        all().reversed().map { "\($0.createdAt.formatted(date: .numeric, time: .shortened))\n\($0.translatedText ?? $0.text)" }
            .joined(separator: "\n\n")
    }
}
