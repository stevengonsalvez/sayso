import Foundation

public enum HistoryFilter {
    public static func matching(_ entries: [Transcript], query: String) -> [Transcript] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }

        return entries.filter { transcript in
            [
                transcript.text,
                transcript.translatedText,
                transcript.language.displayName,
                transcript.route.displayName
            ]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
}

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
    private enum LoadResult {
        case missing
        case entries([Transcript])
        case unreadable
    }

    private let fileURL: URL
    private let recordingsDirectory: URL
    private let maximumEntries: Int
    private let fileManager: FileManager

    public init(
        fileManager: FileManager = .default,
        maximumEntries: Int = 500
    ) {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SaysoNotch", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        self.fileURL = root.appendingPathComponent("history.json")
        self.recordingsDirectory = root.appendingPathComponent("Recordings", isDirectory: true)
        self.maximumEntries = maximumEntries
        self.fileManager = fileManager
    }

    public init(
        fileURL: URL,
        maximumEntries: Int = 500,
        recordingsDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.recordingsDirectory = recordingsDirectory
            ?? fileURL.deletingLastPathComponent().appendingPathComponent("Recordings", isDirectory: true)
        self.maximumEntries = maximumEntries
        self.fileManager = fileManager
    }

    public func all() -> [Transcript] {
        guard case let .entries(entries) = load() else { return [] }
        return entries
    }

    public func matching(_ query: String) -> [Transcript] {
        HistoryFilter.matching(all(), query: query)
    }

    @discardableResult
    public func append(_ transcript: Transcript) -> Bool {
        let existing: [Transcript]
        switch load() {
        case .missing:
            existing = []
        case let .entries(entries):
            existing = entries
        case .unreadable:
            guard transcript.isFinal, !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  preserveUnreadableHistory() else {
                return false
            }
            existing = []
        }
        guard transcript.isFinal, !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            releaseManagedAudio([transcript.audioFileURL], unlessReferencedBy: existing)
            return false
        }

        var transcript = transcript
        clearMissingAudioReference(in: &transcript)
        var seenIDs = Set<Transcript.ID>()
        var entries: [Transcript] = []
        var discarded: [Transcript] = []
        for entry in existing {
            if seenIDs.insert(entry.id).inserted {
                entries.append(entry)
            } else {
                discarded.append(entry)
            }
        }
        discarded += entries.filter { $0.id == transcript.id }
        entries.removeAll { $0.id == transcript.id }
        entries.insert(transcript, at: 0)
        let expired = entries.count > maximumEntries ? entries.suffix(entries.count - maximumEntries) : []
        if !expired.isEmpty { entries.removeLast(expired.count) }
        discarded += expired
        guard persist(entries) else {
            releaseManagedAudio([transcript.audioFileURL], unlessReferencedBy: existing)
            return false
        }
        releaseManagedAudio(discarded.map(\.audioFileURL), unlessReferencedBy: entries)
        return true
    }

    @discardableResult
    public func remove(id: Transcript.ID) -> Bool {
        guard case let .entries(loadedEntries) = load() else { return false }
        var entries = loadedEntries
        let removed = entries.filter { $0.id == id }
        let originalCount = entries.count
        entries.removeAll { $0.id == id }
        guard entries.count != originalCount, persist(entries) else { return false }
        releaseManagedAudio(removed.map(\.audioFileURL), unlessReferencedBy: entries)
        return true
    }

    @discardableResult
    public func clear() -> Bool {
        var succeeded = true
        let historyFiles = ([fileURL] + corruptBackupURLs())
            .filter { fileManager.fileExists(atPath: $0.path) }
        for url in Set(historyFiles.map(\.standardizedFileURL)) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                succeeded = false
            }
        }

        SessionAudioArchive.deleteAllManagedRecordings(directory: recordingsDirectory, fileManager: fileManager)
        return succeeded
            && !fileManager.fileExists(atPath: fileURL.path)
            && corruptBackupURLs().isEmpty
            && managedRecordings().isEmpty
    }

    public func reclaimUnreferencedAudio(olderThan: Date? = nil) {
        guard corruptBackupURLs().isEmpty else { return }
        let entries: [Transcript]
        switch load() {
        case .missing:
            entries = []
        case let .entries(loadedEntries):
            entries = loadedEntries
        case .unreadable:
            return
        }
        let retained = Set(entries.compactMap(\.audioFileURL).map(\.standardizedFileURL))
        SessionAudioArchive.sweepUnreferencedRecordings(
            retaining: retained,
            directory: recordingsDirectory,
            olderThan: olderThan,
            fileManager: fileManager
        )
    }

    public func plainTextExport() -> String {
        all().reversed().map { "\($0.createdAt.formatted(date: .numeric, time: .shortened))\n\($0.translatedText ?? $0.text)" }
            .joined(separator: "\n\n")
    }

    private func persist(_ entries: [Transcript]) -> Bool {
        guard let data = try? JSONEncoder().encode(entries) else { return false }
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func load() -> LoadResult {
        guard fileManager.fileExists(atPath: fileURL.path) else { return .missing }
        do {
            let data = try Data(contentsOf: fileURL)
            return .entries(try JSONDecoder().decode([Transcript].self, from: data))
        } catch {
            return .unreadable
        }
    }

    /// Moves undecodable history out of the active path before a fresh append can persist.
    private func preserveUnreadableHistory() -> Bool {
        guard fileManager.fileExists(atPath: fileURL.path) else { return false }
        do {
            try fileManager.moveItem(at: fileURL, to: nextCorruptBackupURL())
            return true
        } catch {
            return false
        }
    }

    private func corruptBackupURLs() -> [URL] {
        let parent = fileURL.deletingLastPathComponent()
        let prefix = "\(fileURL.lastPathComponent).corrupt-"
        return ((try? fileManager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
    }

    private func nextCorruptBackupURL() -> URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(UUID().uuidString)")
    }

    private func managedRecordings() -> [URL] {
        let urls = (try? fileManager.contentsOfDirectory(at: recordingsDirectory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter {
            SessionAudioArchive.isManagedRecording($0, directory: recordingsDirectory, fileManager: fileManager)
        }
    }

    private func clearMissingAudioReference(in transcript: inout Transcript) {
        guard let url = transcript.audioFileURL,
              url.isFileURL,
              !fileManager.fileExists(atPath: url.path) else { return }
        transcript.audioFileURL = nil
    }

    private func releaseManagedAudio(_ urls: [URL?], unlessReferencedBy entries: [Transcript]) {
        let retained = Set(entries.compactMap(\.audioFileURL).map { $0.standardizedFileURL })
        Set(urls.compactMap { $0?.standardizedFileURL }).forEach { url in
            guard !retained.contains(url) else { return }
            SessionAudioArchive.deleteManagedRecording(
                url,
                directory: recordingsDirectory,
                fileManager: fileManager
            )
        }
    }
}
