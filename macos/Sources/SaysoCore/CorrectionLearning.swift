import Combine
import Foundation
import SpeakCore

private enum CorrectionStoragePrivacy {
    private static let directoryPermissions: NSNumber = 0o700
    private static let filePermissions: NSNumber = 0o600

    static func prepareDirectory(_ directory: URL, fileManager: FileManager) {
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: directoryPermissions]
        )
        // `createDirectory` does not update permissions on an existing folder.
        try? fileManager.setAttributes([.posixPermissions: directoryPermissions], ofItemAtPath: directory.path)
    }

    static func restrictExistingFile(_ fileURL: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try? fileManager.setAttributes([.posixPermissions: filePermissions], ofItemAtPath: fileURL.path)
    }

    static func write(_ data: Data, to fileURL: URL, fileManager: FileManager) throws {
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: filePermissions], ofItemAtPath: fileURL.path)
    }
}

public actor SaysoPersonalLexiconStore: PersonalLexiconStoring {
    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let root = baseDirectory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SaysoNotch", isDirectory: true)
        let directory = root.appendingPathComponent("PersonalLexicon", isDirectory: true)
        CorrectionStoragePrivacy.prepareDirectory(directory, fileManager: fileManager)
        fileURL = directory.appendingPathComponent("lexicon.json")
        CorrectionStoragePrivacy.restrictExistingFile(fileURL, fileManager: fileManager)
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load() throws -> [PersonalLexiconRule] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        return try decoder.decode([PersonalLexiconRule].self, from: Data(contentsOf: fileURL))
    }

    public func save(_ rules: [PersonalLexiconRule]) throws {
        if rules.isEmpty {
            if fileManager.fileExists(atPath: fileURL.path) { try fileManager.removeItem(at: fileURL) }
            return
        }
        try CorrectionStoragePrivacy.write(encoder.encode(rules), to: fileURL, fileManager: fileManager)
    }
}

public actor SaysoAutoCorrectionStore: AutoCorrectionStoring {
    private static let candidateExpirationInterval: TimeInterval = 30 * 24 * 60 * 60

    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let root = baseDirectory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SaysoNotch", isDirectory: true)
        let directory = root.appendingPathComponent("AutoCorrections", isDirectory: true)
        CorrectionStoragePrivacy.prepareDirectory(directory, fileManager: fileManager)
        fileURL = directory.appendingPathComponent("candidates.json")
        CorrectionStoragePrivacy.restrictExistingFile(fileURL, fileManager: fileManager)
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load() throws -> [AutoCorrectionCandidate] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let candidates = try decoder.decode([AutoCorrectionCandidate].self, from: Data(contentsOf: fileURL))
        let expiry = Date().addingTimeInterval(-Self.candidateExpirationInterval)
        return candidates.filter { $0.seenCount > 1 || $0.lastSeenAt > expiry }
    }

    public func save(_ candidates: [AutoCorrectionCandidate]) throws {
        if candidates.isEmpty {
            if fileManager.fileExists(atPath: fileURL.path) { try fileManager.removeItem(at: fileURL) }
            return
        }
        try CorrectionStoragePrivacy.write(encoder.encode(candidates), to: fileURL, fileManager: fileManager)
    }

    public func deleteAll() throws {
        if fileManager.fileExists(atPath: fileURL.path) { try fileManager.removeItem(at: fileURL) }
    }
}

@MainActor
public final class SaysoCorrectionLearning: ObservableObject {
    private final class Configuration {
        var promotionThreshold: Int

        init(promotionThreshold: Int) {
            self.promotionThreshold = promotionThreshold
        }
    }

    public let lexicon: PersonalLexiconService
    private let engine: AutoCorrectionEngine
    private let configuration: Configuration
    private var observations = Set<AnyCancellable>()
    private var monitoringTask: Task<Void, Never>?
    private var monitoringID: UUID?

    @Published public private(set) var isMonitoring = false
    public var candidates: [AutoCorrectionCandidate] { engine.candidates.filter { !$0.dismissed } }
    public var rules: [PersonalLexiconRule] { lexicon.rules }

    public init(baseDirectory: URL? = nil, promotionThreshold: Int = 3) {
        let configuration = Configuration(promotionThreshold: Self.clampedThreshold(promotionThreshold))
        let lexicon = PersonalLexiconService(store: SaysoPersonalLexiconStore(baseDirectory: baseDirectory))
        self.configuration = configuration
        self.lexicon = lexicon
        engine = AutoCorrectionEngine(
            store: SaysoAutoCorrectionStore(baseDirectory: baseDirectory),
            lexiconService: lexicon,
            promotionThreshold: { configuration.promotionThreshold }
        )
        engine.objectWillChange
            .merge(with: lexicon.objectWillChange)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &observations)
    }

    public func waitUntilLoaded() async {
        await lexicon.waitUntilLoaded()
        await engine.waitUntilLoaded()
    }

    public func setPromotionThreshold(_ value: Int) {
        configuration.promotionThreshold = Self.clampedThreshold(value)
    }

    public func apply(to text: String, destinationApplication: String? = nil) -> PersonalLexiconApplicationResult {
        lexicon.apply(
            to: text,
            context: .init(tags: [], destinationApplication: destinationApplication, recentTranscriptWindow: "")
        )
    }

    public func importLegacy(_ replacements: [String: String]) async throws {
        await lexicon.waitUntilLoaded()
        for (source, replacement) in replacements.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
            let alias = source.trimmingCharacters(in: .whitespacesAndNewlines)
            let canonical = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !alias.isEmpty, !canonical.isEmpty else { continue }
            let alreadyImported = lexicon.rules.contains {
                $0.canonical.caseInsensitiveCompare(canonical) == .orderedSame
                    && $0.aliases.contains { $0.caseInsensitiveCompare(alias) == .orderedSame }
            }
            guard !alreadyImported else { continue }
            _ = try await lexicon.addRule(
                displayName: canonical,
                canonical: canonical,
                aliases: [alias],
                activation: .automatic,
                contextTags: [],
                confidence: .high,
                notes: "Migrated from Sayso lexicon",
                source: .manual
            )
        }
    }

    public func addRule(source: String, replacement: String) async throws {
        let alias = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty, !canonical.isEmpty else { return }
        _ = try await lexicon.addRule(
            displayName: canonical,
            canonical: canonical,
            aliases: [alias],
            activation: .automatic,
            contextTags: [],
            confidence: .high,
            notes: nil,
            source: .manual
        )
    }

    public func removeRule(id: UUID) async throws {
        try await lexicon.deleteRule(id: id)
    }

    public func recordEdit(original: String, edited: String, sourceApplication: String?) async throws {
        let dismissed = Set(engine.candidates.filter(\.dismissed).map(\.matchKey))
        for change in WordDiffer.findChanges(original: original, edited: edited) {
            let key = "\(change.original.lowercased())→\(change.corrected.lowercased())"
            guard !dismissed.contains(key) else { continue }
            try await engine.recordEdit(
                original: change.original,
                edited: change.corrected,
                app: sourceApplication
            )
        }
    }

    public func startMonitoring(insertedText: String, destination: TextOutput.Destination?) {
        guard !insertedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let destination else { return }
        stopMonitoring()
        guard let originalValue = TextOutput.currentValue(in: destination) else { return }
        let id = UUID()
        monitoringID = id
        isMonitoring = true
        let sentenceCount = insertedText.unicodeScalars.filter { ".!?".unicodeScalars.contains($0) }.count
        let delay = min(10 + Double(sentenceCount), 30)
        let sourceApplication = destination.recordingDestination.applicationName
        monitoringTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, self.monitoringID == id else { return }
            defer {
                if self.monitoringID == id {
                    self.monitoringID = nil
                    self.monitoringTask = nil
                    self.isMonitoring = false
                }
            }
            guard let edited = TextOutput.currentValue(in: destination) else { return }
            try? await self.recordEdit(original: originalValue, edited: edited, sourceApplication: sourceApplication)
        }
    }

    public func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
        monitoringID = nil
        isMonitoring = false
    }

    public func promote(_ candidate: AutoCorrectionCandidate) async throws {
        try await engine.promoteCandidate(candidate)
    }

    public func dismiss(id: UUID) async throws {
        try await engine.dismissCandidate(id: id)
    }

    private static func clampedThreshold(_ value: Int) -> Int {
        min(max(value, 2), 10)
    }
}
