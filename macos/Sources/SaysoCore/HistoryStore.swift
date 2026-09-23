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

public enum HistoryAppendResult: Equatable, Sendable {
    case saved
    case recovered
    case failed

    public var didSave: Bool { self != .failed }
}

public actor HistoryStore {
    private enum LoadResult {
        case missing
        case entries([Transcript])
        case invalid
        case unavailable
    }

    private let fileURL: URL
    private let recordingsDirectory: URL
    private let maximumEntries: Int
    private let fileManager: FileManager
    private let persistEntries: @Sendable (Data, URL) -> Bool

    public init(
        fileManager: FileManager = .default,
        maximumEntries: Int = 500,
        persistEntries: @escaping @Sendable (Data, URL) -> Bool = HistoryStore.write
    ) {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SaysoNotch", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        self.fileURL = root.appendingPathComponent("history.json")
        self.recordingsDirectory = root.appendingPathComponent("Recordings", isDirectory: true)
        self.maximumEntries = maximumEntries
        self.fileManager = fileManager
        self.persistEntries = persistEntries
    }

    public init(
        fileURL: URL,
        maximumEntries: Int = 500,
        recordingsDirectory: URL? = nil,
        fileManager: FileManager = .default,
        persistEntries: @escaping @Sendable (Data, URL) -> Bool = HistoryStore.write
    ) {
        self.fileURL = fileURL
        self.recordingsDirectory = recordingsDirectory
            ?? fileURL.deletingLastPathComponent().appendingPathComponent("Recordings", isDirectory: true)
        self.maximumEntries = maximumEntries
        self.fileManager = fileManager
        self.persistEntries = persistEntries
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
        appendResult(transcript).didSave
    }

    @discardableResult
    public func appendResult(_ transcript: Transcript) -> HistoryAppendResult {
        let existing: [Transcript]
        let recovered: Bool
        switch load() {
        case .missing:
            existing = []
            recovered = false
        case let .entries(entries):
            existing = entries
            recovered = false
        case .invalid:
            guard transcript.isFinal, !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                releaseManagedAudio(
                    [transcript.audioFileURL],
                    retaining: recoverableAudioURLs(),
                    unlessReferencedBy: []
                )
                return .failed
            }
            guard preserveUnreadableHistory() else {
                releaseManagedAudio(
                    [transcript.audioFileURL],
                    retaining: recoverableAudioURLs(),
                    unlessReferencedBy: []
                )
                return .failed
            }
            existing = []
            recovered = true
        case .unavailable:
            // Keep opted-in audio while history storage may be temporarily unavailable.
            return .failed
        }
        guard transcript.isFinal, !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            releaseManagedAudio([transcript.audioFileURL], unlessReferencedBy: existing)
            return .failed
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
            releaseManagedAudio(
                [transcript.audioFileURL],
                retaining: recovered ? recoverableAudioURLs() : [],
                unlessReferencedBy: existing
            )
            return .failed
        }
        releaseManagedAudio(discarded.map(\.audioFileURL), unlessReferencedBy: entries)
        return recovered ? .recovered : .saved
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

        guard succeeded,
              !fileManager.fileExists(atPath: fileURL.path),
              corruptBackupURLs().isEmpty else {
            return false
        }
        SessionAudioArchive.deleteAllManagedRecordings(directory: recordingsDirectory, fileManager: fileManager)
        return managedRecordings().isEmpty
    }

    public func reclaimUnreferencedAudio(olderThan: Date? = nil) {
        let entries: [Transcript]
        switch load() {
        case .missing:
            entries = []
        case let .entries(loadedEntries):
            entries = loadedEntries
        case .invalid, .unavailable:
            return
        }
        let retained = retainedAudioURLs(in: entries)
            .union(retainedAudioURLs(in: backupEntries()))
            .union(audioURLsNamedInBackups())
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
        return persistEntries(data, fileURL)
    }

    public static func write(_ data: Data, _ fileURL: URL) -> Bool {
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func load() -> LoadResult {
        guard fileManager.fileExists(atPath: fileURL.path) else { return .missing }
        guard let data = try? Data(contentsOf: fileURL) else { return .unavailable }
        guard let entries = try? JSONDecoder().decode([Transcript].self, from: data) else { return .invalid }
        return .entries(entries)
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

    private func backupEntries() -> [Transcript] {
        corruptBackupURLs().reduce(into: [Transcript]()) { entries, url in
            guard let data = try? Data(contentsOf: url),
                  let backup = try? JSONDecoder().decode([Transcript].self, from: data) else {
                return
            }
            entries.append(contentsOf: backup)
        }
    }

    private func retainedAudioURLs(in entries: [Transcript]) -> Set<URL> {
        Set(entries.compactMap(\.audioFileURL).map(\.standardizedFileURL).filter {
            SessionAudioArchive.isManagedRecording($0, directory: recordingsDirectory, fileManager: fileManager)
        })
    }

    private func audioURLsNamedInBackups() -> Set<URL> {
        audioURLsNamed(in: corruptBackupURLs())
    }

    private func recoverableAudioURLs() -> Set<URL> {
        retainedAudioURLs(in: backupEntries())
            .union(audioURLsNamed(in: [fileURL] + corruptBackupURLs()))
    }

    private func audioURLsNamed(in sourceURLs: [URL]) -> Set<URL> {
        var urls = Set<URL>()
        for sourceURL in sourceURLs {
            let text = String(decoding: (try? Data(contentsOf: sourceURL)) ?? Data(), as: UTF8.self)
            let range = NSRange(text.startIndex..., in: text)
            for match in Self.recordingNamePattern.matches(in: text, range: range) {
                guard let matchRange = Range(match.range, in: text) else { continue }
                let url = recordingsDirectory.appendingPathComponent(String(text[matchRange])).standardizedFileURL
                guard SessionAudioArchive.isManagedRecording(url, directory: recordingsDirectory, fileManager: fileManager) else { continue }
                urls.insert(url)
            }
        }
        return urls
    }

    private static let recordingNamePattern = try! NSRegularExpression(
        pattern: #"(?i)\b(?:Recording|Imported)-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(?:"#
            + SessionAudioArchive.managedFileExtensions.sorted().joined(separator: "|")
            + #")\b"#
    )

    private func clearMissingAudioReference(in transcript: inout Transcript) {
        guard let url = transcript.audioFileURL,
              url.isFileURL,
              !fileManager.fileExists(atPath: url.path) else { return }
        transcript.audioFileURL = nil
    }

    private func releaseManagedAudio(
        _ urls: [URL?],
        retaining protectedURLs: Set<URL> = [],
        unlessReferencedBy entries: [Transcript]
    ) {
        let retained = Set(entries.compactMap(\.audioFileURL).map { $0.standardizedFileURL })
            .union(protectedURLs.map(\.standardizedFileURL))
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
