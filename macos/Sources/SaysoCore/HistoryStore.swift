import Foundation

public enum HistoryScope: String, CaseIterable, Identifiable, Sendable {
    case all
    case onDevice
    case appleSpeech
    case yourProvider
    case translated
    case recordings

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: "All"
        case .onDevice: "On-device"
        case .appleSpeech: "Apple Speech"
        case .yourProvider: "Your provider"
        case .translated: "Translated"
        case .recordings: "Recordings"
        }
    }
}

public enum HistoryFilter {
    public static func matching(
        _ entries: [Transcript],
        query: String,
        scope: HistoryScope = .all,
        availableRecordingIDs: Set<Transcript.ID> = []
    ) -> [Transcript] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let scoped = entries.filter { transcript in
            switch scope {
            case .all:
                true
            case .onDevice:
                transcript.route == .local
            case .appleSpeech:
                transcript.route == .appleSpeech
            case .yourProvider:
                transcript.route == .byok
            case .translated:
                transcript.hasTranslation
            case .recordings:
                availableRecordingIDs.contains(transcript.id)
            }
        }
        guard !query.isEmpty else { return scoped }

        return scoped.filter { transcript in
            [
                transcript.text,
                transcript.displayText,
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

    private enum PersistResult {
        case snapshot
        case journaled
        case failed

        var didCommit: Bool { self != .failed }
    }

    private struct HistoryJournal: Codable {
        let entries: [Transcript]
        let deferredAudioFileURLs: [URL]
    }

    private let fileURL: URL
    private let walURL: URL
    private let recordingsDirectory: URL
    private let maximumEntries: Int?
    private let fileManager: FileManager
    private let persistEntries: @Sendable (Data, URL) -> Bool
    private let persistJournal: @Sendable (Data, URL) -> Bool

    /// Pass nil to retain complete history. The production app opts in explicitly.
    public init(
        fileManager: FileManager = .default,
        maximumEntries: Int? = 500,
        persistEntries: @escaping @Sendable (Data, URL) -> Bool = HistoryStore.write,
        persistJournal: @escaping @Sendable (Data, URL) -> Bool = HistoryStore.write
    ) {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SaysoNotch", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        self.fileURL = root.appendingPathComponent("history.json")
        self.walURL = root.appendingPathComponent("history.json.wal")
        self.recordingsDirectory = root.appendingPathComponent("Recordings", isDirectory: true)
        self.maximumEntries = maximumEntries
        self.fileManager = fileManager
        self.persistEntries = persistEntries
        self.persistJournal = persistJournal
    }

    public init(
        fileURL: URL,
        maximumEntries: Int? = 500,
        recordingsDirectory: URL? = nil,
        fileManager: FileManager = .default,
        persistEntries: @escaping @Sendable (Data, URL) -> Bool = HistoryStore.write,
        persistJournal: @escaping @Sendable (Data, URL) -> Bool = HistoryStore.write
    ) {
        self.fileURL = fileURL
        self.walURL = fileURL.appendingPathExtension("wal")
        self.recordingsDirectory = recordingsDirectory
            ?? fileURL.deletingLastPathComponent().appendingPathComponent("Recordings", isDirectory: true)
        self.maximumEntries = maximumEntries
        self.fileManager = fileManager
        self.persistEntries = persistEntries
        self.persistJournal = persistJournal
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
        let expired: [Transcript]
        if let maximumEntries, entries.count > maximumEntries {
            expired = Array(entries.suffix(entries.count - maximumEntries))
            entries.removeLast(expired.count)
        } else {
            expired = []
        }
        discarded += expired
        let persistResult = persist(entries, deferringAudioRelease: discarded.map(\.audioFileURL))
        guard persistResult.didCommit else {
            releaseManagedAudio(
                [transcript.audioFileURL],
                retaining: recovered ? recoverableAudioURLs() : [],
                unlessReferencedBy: existing
            )
            return .failed
        }
        return recovered ? .recovered : .saved
    }

    @discardableResult
    public func remove(id: Transcript.ID) -> Bool {
        guard case let .entries(loadedEntries) = load() else { return false }
        var entries = loadedEntries
        let removed = entries.filter { $0.id == id }
        let originalCount = entries.count
        entries.removeAll { $0.id == id }
        guard entries.count != originalCount else { return false }
        let persistResult = persist(entries, deferringAudioRelease: removed.map(\.audioFileURL))
        guard persistResult.didCommit else { return false }
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
        let walFiles = ([walURL] + corruptWALBackupURLs())
            .filter { fileManager.fileExists(atPath: $0.path) }
        for url in Set(walFiles.map(\.standardizedFileURL)) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                return false
            }
        }
        guard !fileManager.fileExists(atPath: walURL.path),
              corruptWALBackupURLs().isEmpty else {
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
        all().reversed().map { "\($0.createdAt.formatted(date: .numeric, time: .shortened))\n\($0.displayText)" }
            .joined(separator: "\n\n")
    }

    private func persist(
        _ entries: [Transcript],
        deferringAudioRelease audioURLs: [URL?] = []
    ) -> PersistResult {
        var deferredAudioFileURLs = Set(journal()?.deferredAudioFileURLs ?? [])
        deferredAudioFileURLs.formUnion(audioURLs.compactMap { $0?.standardizedFileURL })
        let journal = HistoryJournal(
            entries: entries,
            deferredAudioFileURLs: Array(deferredAudioFileURLs)
        )
        guard let data = try? JSONEncoder().encode(journal), writeWAL(data) else { return .failed }
        guard let snapshot = try? JSONEncoder().encode(entries), persistEntries(snapshot, fileURL) else {
            return .journaled
        }
        try? fileManager.removeItem(at: walURL)
        releaseManagedAudio(
            Array(deferredAudioFileURLs).map(Optional.some),
            retaining: recoverableAudioURLs(),
            unlessReferencedBy: entries
        )
        return .snapshot
    }

    public static func write(_ data: Data, _ fileURL: URL) -> Bool {
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return false
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            try? handle.synchronize()
        }
        return true
    }

    private func load() -> LoadResult {
        let snapshot = loadSnapshot()
        guard fileManager.fileExists(atPath: walURL.path) else { return snapshot }
        guard let data = try? Data(contentsOf: walURL) else { return .unavailable }
        guard let journal = decodeJournal(data) else {
            guard preserveUnreadableWAL() else { return .unavailable }
            return snapshot
        }
        let entries = journal.entries

        if case .invalid = snapshot, !preserveUnreadableHistory() {
            return .entries(entries)
        }
        guard let snapshotData = try? JSONEncoder().encode(entries) else { return .entries(entries) }
        if persistEntries(snapshotData, fileURL) {
            try? fileManager.removeItem(at: walURL)
            releaseManagedAudio(
                journal.deferredAudioFileURLs.map(Optional.some),
                retaining: recoverableAudioURLs(),
                unlessReferencedBy: entries
            )
            if case let .entries(previousEntries) = snapshot {
                releaseManagedAudio(
                    previousEntries.map(\.audioFileURL),
                    retaining: recoverableAudioURLs(),
                    unlessReferencedBy: entries
                )
            }
        }
        return .entries(entries)
    }

    private func loadSnapshot() -> LoadResult {
        guard fileManager.fileExists(atPath: fileURL.path) else { return .missing }
        guard let data = try? Data(contentsOf: fileURL) else { return .unavailable }
        guard let entries = try? JSONDecoder().decode([Transcript].self, from: data) else { return .invalid }
        return .entries(entries)
    }

    private func writeWAL(_ data: Data) -> Bool {
        persistJournal(data, walURL)
    }

    private func journal() -> HistoryJournal? {
        guard let data = try? Data(contentsOf: walURL) else { return nil }
        return decodeJournal(data)
    }

    private func decodeJournal(_ data: Data) -> HistoryJournal? {
        if let journal = try? JSONDecoder().decode(HistoryJournal.self, from: data) {
            return journal
        }
        if let entries = try? JSONDecoder().decode([Transcript].self, from: data) {
            return HistoryJournal(entries: entries, deferredAudioFileURLs: [])
        }
        return nil
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
        corruptBackupURLs(for: fileURL)
    }

    private func corruptWALBackupURLs() -> [URL] {
        corruptBackupURLs(for: walURL)
    }

    private func corruptBackupURLs(for sourceURL: URL) -> [URL] {
        let parent = fileURL.deletingLastPathComponent()
        let prefix = "\(sourceURL.lastPathComponent).corrupt-"
        return ((try? fileManager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
    }

    private func nextCorruptBackupURL() -> URL {
        nextCorruptBackupURL(for: fileURL)
    }

    private func nextCorruptWALBackupURL() -> URL {
        nextCorruptBackupURL(for: walURL)
    }

    private func nextCorruptBackupURL(for sourceURL: URL) -> URL {
        sourceURL.deletingLastPathComponent()
            .appendingPathComponent("\(sourceURL.lastPathComponent).corrupt-\(UUID().uuidString)")
    }

    private func preserveUnreadableWAL() -> Bool {
        guard fileManager.fileExists(atPath: walURL.path) else { return false }
        do {
            try fileManager.moveItem(at: walURL, to: nextCorruptWALBackupURL())
            return true
        } catch {
            return false
        }
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
        audioURLsNamed(in: corruptBackupURLs() + corruptWALBackupURLs())
    }

    private func recoverableAudioURLs() -> Set<URL> {
        retainedAudioURLs(in: backupEntries())
            .union(audioURLsNamed(in: [fileURL, walURL] + corruptBackupURLs() + corruptWALBackupURLs()))
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
