@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import SaysoCore

private func finishedManagedRecording(in directory: URL) throws -> URL {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let archive = try SessionAudioArchive(directory: directory, inputFormat: format)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
    buffer.frameLength = 8
    archive.append(buffer)
    return try #require(archive.finish())
}

private final class HistoryRemovalFailingFileManager: FileManager, @unchecked Sendable {
    private let protectedURL: URL

    init(protectedURL: URL) {
        self.protectedURL = protectedURL.standardizedFileURL
        super.init()
    }

    override func removeItem(at url: URL) throws {
        guard url.standardizedFileURL != protectedURL else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: url)
    }
}

@Test func importedAudioIsCopiedIntoManagedStorage() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("meeting.m4a")
    let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: source)

    let imported = try SessionAudioArchive.importRecording(from: source, directory: recordings)

    #expect(imported != source)
    #expect(FileManager.default.fileExists(atPath: imported.path))
    #expect(SessionAudioArchive.isManagedRecording(imported, directory: recordings))
    #expect(try Data(contentsOf: imported) == Data("audio".utf8))
}

@Test func importedAudioStaysUntilHistoryCanReferenceIt() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("recording.m4a")
    let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
    try Data("audio".utf8).write(to: source)
    try FileManager.default.setAttributes(
        [.modificationDate: Date.distantPast],
        ofItemAtPath: source.path
    )
    let launchDate = Date()

    let imported = try SessionAudioArchive.importRecording(from: source, directory: recordings)
    SessionAudioArchive.sweepUnreferencedRecordings(
        retaining: [],
        directory: recordings,
        olderThan: launchDate
    )

    #expect(FileManager.default.fileExists(atPath: imported.path))
}

@Test func importedAudioRejectsUnsupportedFileTypes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let unsupported = root.appendingPathComponent("recording.flac")
    try Data("audio".utf8).write(to: unsupported)

    #expect(throws: SaysoError.self) {
        try SessionAudioArchive.importRecording(from: unsupported, directory: root.appendingPathComponent("Recordings"))
    }
}

@Test func importedAudioRejectsDirectories() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("recording.m4a", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    #expect(throws: SaysoError.self) {
        try SessionAudioArchive.importRecording(from: directory, directory: root.appendingPathComponent("Recordings"))
    }
}

@Test func sessionAudioArchivePersistsReadableAudioOnlyAfterFramesArrive() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let archive = try SessionAudioArchive(directory: directory, inputFormat: format)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
    buffer.frameLength = 32
    let samples = try #require(buffer.floatChannelData?[0])
    for index in 0..<Int(buffer.frameLength) { samples[index] = 0.25 }

    archive.append(buffer)
    let url = try #require(archive.finish())
    let file = try AVAudioFile(forReading: url)

    #expect(file.length == 32)
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test func sessionAudioArchiveConverts48kPCMToRealtime16kAAC() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let archive = try SessionAudioArchive(directory: directory, inputFormat: sourceFormat)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 48_000))
    buffer.frameLength = 48_000

    archive.append(buffer)
    let url = try #require(archive.finish())
    let file = try AVAudioFile(forReading: url)
    let duration = Double(file.length) / file.processingFormat.sampleRate

    #expect(url.pathExtension == "m4a")
    #expect(file.processingFormat.sampleRate == 16_000)
    #expect(file.processingFormat.channelCount == 1)
    #expect(duration > 0.75)
    #expect(duration < 1.25)
}

@Test func sessionAudioArchiveDiscardRemovesUnfinishedRecording() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let archive = try SessionAudioArchive(directory: directory, inputFormat: format)
    let url = archive.recordingURL

    archive.discard()

    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(archive.finish() == nil)
}

@Test func sessionAudioArchiveSweepKeepsOnlyReferencedRecordings() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
    buffer.frameLength = 8

    let retainedArchive = try SessionAudioArchive(directory: directory, inputFormat: format)
    retainedArchive.append(buffer)
    let retainedURL = try #require(retainedArchive.finish())
    let staleArchive = try SessionAudioArchive(directory: directory, inputFormat: format)
    staleArchive.append(buffer)
    let staleURL = try #require(staleArchive.finish())
    let historicalCAF = directory.appendingPathComponent("Recording-legacy.caf")
    _ = try AVAudioFile(
        forWriting: historicalCAF,
        settings: format.settings,
        commonFormat: format.commonFormat,
        interleaved: format.isInterleaved
    )

    SessionAudioArchive.sweepUnreferencedRecordings(
        retaining: Set([retainedURL]),
        directory: directory
    )

    #expect(FileManager.default.fileExists(atPath: retainedURL.path))
    #expect(!FileManager.default.fileExists(atPath: staleURL.path))
    #expect(!FileManager.default.fileExists(atPath: historicalCAF.path))
}

@Test func sessionAudioArchiveSweepRespectsOlderThanCutoff() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let staleURL = try finishedManagedRecording(in: directory)
    let recentURL = try finishedManagedRecording(in: directory)
    let cutoff = Date()
    try FileManager.default.setAttributes([.modificationDate: cutoff.addingTimeInterval(-60)], ofItemAtPath: staleURL.path)
    try FileManager.default.setAttributes([.modificationDate: cutoff.addingTimeInterval(60)], ofItemAtPath: recentURL.path)

    SessionAudioArchive.sweepUnreferencedRecordings(
        retaining: [],
        directory: directory,
        olderThan: cutoff
    )

    #expect(!FileManager.default.fileExists(atPath: staleURL.path))
    #expect(FileManager.default.fileExists(atPath: recentURL.path))
}

@Test func sessionAudioArchiveRetainsReferenceThroughSymlinkedDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let actualDirectory = root.appendingPathComponent("Actual", isDirectory: true)
    let linkedDirectory = root.appendingPathComponent("Linked", isDirectory: true)
    let audioURL = try finishedManagedRecording(in: actualDirectory)
    try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: actualDirectory)
    let linkedAudioURL = linkedDirectory.appendingPathComponent(audioURL.lastPathComponent)

    SessionAudioArchive.sweepUnreferencedRecordings(
        retaining: Set([linkedAudioURL]),
        directory: actualDirectory
    )

    #expect(FileManager.default.fileExists(atPath: audioURL.path))
}

@Test func historyRemovalDeletesItsManagedAudioAfterMetadataPersists() async throws {
    let recordingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: recordingDirectory) }
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let archive = try SessionAudioArchive(directory: recordingDirectory, inputFormat: format)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
    buffer.frameLength = 8
    archive.append(buffer)
    let audioURL = try #require(archive.finish())
    let historyURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
        try? FileManager.default.removeItem(at: historyURL)
        SessionAudioArchive.deleteManagedRecording(audioURL, directory: recordingDirectory)
    }
    let store = HistoryStore(fileURL: historyURL, recordingsDirectory: recordingDirectory)
    let transcript = Transcript(
        text: "Saved recording",
        language: .english,
        route: .local,
        isFinal: true,
        audioFileURL: audioURL
    )

    #expect(await store.append(transcript))
    #expect(await store.remove(id: transcript.id))
    #expect(!FileManager.default.fileExists(atPath: audioURL.path))
}

@Test func historyReplacementKeepsOneTranscriptIDAndReleasesOnlyDetachedAudio() async throws {
    let recordingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: recordingDirectory) }
    let firstAudioURL = try finishedManagedRecording(in: recordingDirectory)
    let replacementAudioURL = try finishedManagedRecording(in: recordingDirectory)
    defer {
        SessionAudioArchive.deleteManagedRecording(firstAudioURL, directory: recordingDirectory)
        SessionAudioArchive.deleteManagedRecording(replacementAudioURL, directory: recordingDirectory)
    }
    let historyURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: historyURL) }
    let store = HistoryStore(fileURL: historyURL, recordingsDirectory: recordingDirectory)
    let id = UUID()

    #expect(await store.append(.init(id: id, text: "Original", language: .english, route: .local, isFinal: true, audioFileURL: firstAudioURL)))
    #expect(await store.append(.init(id: id, text: "Replacement", language: .english, route: .local, isFinal: true, audioFileURL: replacementAudioURL)))

    let entries = await store.all()
    #expect(entries.count == 1)
    #expect(entries.first?.text == "Replacement")
    #expect(!FileManager.default.fileExists(atPath: firstAudioURL.path))
    #expect(FileManager.default.fileExists(atPath: replacementAudioURL.path))
}

@Test func historyRetentionKeepsSharedAudioUntilNoTranscriptReferencesIt() async throws {
    let recordingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: recordingDirectory) }
    let audioURL = try finishedManagedRecording(in: recordingDirectory)
    defer { SessionAudioArchive.deleteManagedRecording(audioURL, directory: recordingDirectory) }
    let historyURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: historyURL) }
    let store = HistoryStore(fileURL: historyURL, maximumEntries: 1, recordingsDirectory: recordingDirectory)
    let first = Transcript(text: "First", language: .english, route: .local, isFinal: true, audioFileURL: audioURL)
    let second = Transcript(text: "Second", language: .english, route: .local, isFinal: true, audioFileURL: audioURL)

    #expect(await store.append(first))
    #expect(await store.append(second))
    #expect(await store.all().map(\.id) == [second.id])
    #expect(FileManager.default.fileExists(atPath: audioURL.path))
    #expect(await store.remove(id: second.id))
    #expect(!FileManager.default.fileExists(atPath: audioURL.path))
}

@Test func clearingHistoryDeletesAllManagedRecordingsInItsConfiguredDirectory() async throws {
    let recordingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: recordingDirectory) }
    let historicalAudioURL = try finishedManagedRecording(in: recordingDirectory)
    let finalAudioURL = try finishedManagedRecording(in: recordingDirectory)
    defer {
        SessionAudioArchive.deleteManagedRecording(historicalAudioURL, directory: recordingDirectory)
        SessionAudioArchive.deleteManagedRecording(finalAudioURL, directory: recordingDirectory)
    }
    let historyURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: historyURL) }
    let store = HistoryStore(fileURL: historyURL, recordingsDirectory: recordingDirectory)

    #expect(await store.append(.init(text: "Existing", language: .english, route: .local, isFinal: true, audioFileURL: historicalAudioURL)))
    #expect(await store.clear())
    #expect(!FileManager.default.fileExists(atPath: historicalAudioURL.path))
    #expect(!FileManager.default.fileExists(atPath: finalAudioURL.path))

    #expect(await store.append(.init(text: "Final", language: .english, route: .local, isFinal: true, audioFileURL: finalAudioURL)))
    #expect(await store.all().first?.audioFileURL == nil)
}

@Test func clearingHistoryPreservesAudioWhenHistoryRemovalFails() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let historyURL = root.appendingPathComponent("history.json")
    let recordingDirectory = root.appendingPathComponent("Recordings", isDirectory: true)
    let audioURL = try finishedManagedRecording(in: recordingDirectory)
    let transcript = Transcript(text: "Existing", language: .english, route: .local, isFinal: true, audioFileURL: audioURL)
    try JSONEncoder().encode([transcript]).write(to: historyURL)
    let store = HistoryStore(
        fileURL: historyURL,
        recordingsDirectory: recordingDirectory,
        fileManager: HistoryRemovalFailingFileManager(protectedURL: historyURL)
    )

    #expect(!(await store.clear()))
    #expect(FileManager.default.fileExists(atPath: historyURL.path))
    #expect(FileManager.default.fileExists(atPath: audioURL.path))
}

@Test func corruptHistoryAppendMovesBytesAsideAndPreservesManagedAudio() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let historyURL = root.appendingPathComponent("history.json")
    let recordingDirectory = root.appendingPathComponent("Recordings", isDirectory: true)
    let historicalAudioURL = try finishedManagedRecording(in: recordingDirectory)
    let appendedAudioURL = try finishedManagedRecording(in: recordingDirectory)
    let corruptData = Data("not valid history".utf8)
    try corruptData.write(to: historyURL)
    let originalHistory = try Data(contentsOf: historyURL)
    let store = HistoryStore(fileURL: historyURL, recordingsDirectory: recordingDirectory)
    let transcript = Transcript(text: "Recovered append", language: .english, route: .local, isFinal: true, audioFileURL: appendedAudioURL)

    #expect(await store.appendResult(transcript) == .recovered)
    let corruptBackups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("history.json.corrupt-") }
    #expect(corruptBackups.count == 1)
    #expect(try Data(contentsOf: try #require(corruptBackups.first)) == originalHistory)
    #expect(await store.all().map(\.id) == [transcript.id])
    #expect(FileManager.default.fileExists(atPath: historicalAudioURL.path))
    #expect(FileManager.default.fileExists(atPath: appendedAudioURL.path))
}

@Test func corruptHistoryRecoverySweepsOrphanedAudioWhenBackupCannotDecode() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let historyURL = root.appendingPathComponent("history.json")
    let recordingDirectory = root.appendingPathComponent("InjectedRecordings", isDirectory: true)
    let orphanedAudioURL = try finishedManagedRecording(in: recordingDirectory)
    try Data("not valid history".utf8).write(to: historyURL)
    let store = HistoryStore(fileURL: historyURL, recordingsDirectory: recordingDirectory)

    #expect(await store.append(.init(text: "Recovered", language: .english, route: .local, isFinal: true)))
    await store.reclaimUnreferencedAudio(olderThan: Date().addingTimeInterval(1))

    #expect(!FileManager.default.fileExists(atPath: orphanedAudioURL.path))
}

@Test func corruptHistoryRecoveryRetainsAudioReferencedByDecodableBackup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let historyURL = root.appendingPathComponent("history.json")
    let recordingDirectory = root.appendingPathComponent("InjectedRecordings", isDirectory: true)
    let retainedAudioURL = try finishedManagedRecording(in: recordingDirectory)
    let orphanedAudioURL = try finishedManagedRecording(in: recordingDirectory)
    let backup = [Transcript(text: "Retained", language: .english, route: .local, isFinal: true, audioFileURL: retainedAudioURL)]
    try JSONEncoder().encode(backup).write(to: root.appendingPathComponent("history.json.corrupt-restorable"))
    try Data("not valid history".utf8).write(to: historyURL)
    let store = HistoryStore(fileURL: historyURL, recordingsDirectory: recordingDirectory)

    #expect(await store.append(.init(text: "Recovered", language: .english, route: .local, isFinal: true)))
    await store.reclaimUnreferencedAudio(olderThan: Date().addingTimeInterval(1))

    #expect(FileManager.default.fileExists(atPath: retainedAudioURL.path))
    #expect(!FileManager.default.fileExists(atPath: orphanedAudioURL.path))
}

@Test func corruptHistoryRecoveryRetainsAudioNamedInUnreadableBackup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let historyURL = root.appendingPathComponent("history.json")
    let recordingDirectory = root.appendingPathComponent("InjectedRecordings", isDirectory: true)
    let retainedAudioURL = try finishedManagedRecording(in: recordingDirectory)
    let orphanedAudioURL = try finishedManagedRecording(in: recordingDirectory)
    try Data("truncated \(retainedAudioURL.lastPathComponent) history".utf8).write(to: historyURL)
    let store = HistoryStore(fileURL: historyURL, recordingsDirectory: recordingDirectory)

    #expect(await store.appendResult(.init(text: "Recovered", language: .english, route: .local, isFinal: true)) == .recovered)
    await store.reclaimUnreferencedAudio(olderThan: Date().addingTimeInterval(1))

    #expect(FileManager.default.fileExists(atPath: retainedAudioURL.path))
    #expect(!FileManager.default.fileExists(atPath: orphanedAudioURL.path))
}

@Test func corruptHistoryRecoveryRetainsImportedAudioNamedInUnreadableBackup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let historyURL = root.appendingPathComponent("history.json")
    let recordingDirectory = root.appendingPathComponent("InjectedRecordings", isDirectory: true)
    try FileManager.default.createDirectory(at: recordingDirectory, withIntermediateDirectories: true)
    let retainedAudioURL = recordingDirectory.appendingPathComponent("Imported-\(UUID().uuidString).m4a")
    try Data("saved audio".utf8).write(to: retainedAudioURL)
    let orphanedAudioURL = try finishedManagedRecording(in: recordingDirectory)
    try Data("truncated \(retainedAudioURL.lastPathComponent) history".utf8).write(to: historyURL)
    let store = HistoryStore(fileURL: historyURL, recordingsDirectory: recordingDirectory)

    #expect(await store.appendResult(.init(text: "Recovered", language: .english, route: .local, isFinal: true)) == .recovered)
    await store.reclaimUnreferencedAudio(olderThan: Date().addingTimeInterval(1))

    #expect(FileManager.default.fileExists(atPath: retainedAudioURL.path))
    #expect(!FileManager.default.fileExists(atPath: orphanedAudioURL.path))
}

@Test func corruptHistoryKeepsNamedAudioWhenEmptyAppendFails() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let historyURL = root.appendingPathComponent("history.json")
    let recordingDirectory = root.appendingPathComponent("Recordings", isDirectory: true)
    let existingAudioURL = try finishedManagedRecording(in: recordingDirectory)
    try Data("truncated \(existingAudioURL.lastPathComponent) history".utf8).write(to: historyURL)
    let store = HistoryStore(fileURL: historyURL, recordingsDirectory: recordingDirectory)

    let emptyReprocess = Transcript(
        text: "",
        language: .english,
        route: .local,
        isFinal: true,
        audioFileURL: existingAudioURL
    )

    #expect(await store.appendResult(emptyReprocess) == .failed)
    #expect(FileManager.default.fileExists(atPath: existingAudioURL.path))
}

@Test func failedRecoveryWriteKeepsAudioNamedByBackup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let historyURL = root.appendingPathComponent("history.json")
    let recordingDirectory = root.appendingPathComponent("Recordings", isDirectory: true)
    let existingAudioURL = try finishedManagedRecording(in: recordingDirectory)
    try Data("truncated \(existingAudioURL.lastPathComponent) history".utf8).write(to: historyURL)
    let store = HistoryStore(
        fileURL: historyURL,
        recordingsDirectory: recordingDirectory,
        persistEntries: { _, _ in false }
    )

    let reprocessed = Transcript(
        text: "Recovered",
        language: .english,
        route: .local,
        isFinal: true,
        audioFileURL: existingAudioURL
    )

    #expect(await store.appendResult(reprocessed) == .failed)
    #expect(FileManager.default.fileExists(atPath: existingAudioURL.path))
}

@Test func unavailableHistoryDoesNotMoveItAsideOrDropNewAudio() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let historyURL = root.appendingPathComponent("history.json", isDirectory: true)
    let recordingDirectory = root.appendingPathComponent("InjectedRecordings", isDirectory: true)
    let audioURL = try finishedManagedRecording(in: recordingDirectory)
    try FileManager.default.createDirectory(at: historyURL, withIntermediateDirectories: true)
    let store = HistoryStore(fileURL: historyURL, recordingsDirectory: recordingDirectory)

    #expect(!(await store.append(.init(text: "Do not overwrite", language: .english, route: .local, isFinal: true, audioFileURL: audioURL))))
    #expect(FileManager.default.fileExists(atPath: historyURL.path))
    #expect(FileManager.default.fileExists(atPath: audioURL.path))
    #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("history.json.corrupt-") }.isEmpty)
}

@Test func clearingCorruptHistoryPurgesBackupsAndConfiguredManagedRecordings() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let historyURL = root.appendingPathComponent("history.json")
    let recordingDirectory = root.appendingPathComponent("InjectedRecordings", isDirectory: true)
    let unrelatedDirectory = root.appendingPathComponent("UnrelatedRecordings", isDirectory: true)
    let firstManagedURL = try finishedManagedRecording(in: recordingDirectory)
    let secondManagedURL = try finishedManagedRecording(in: recordingDirectory)
    let unrelatedURL = try finishedManagedRecording(in: unrelatedDirectory)
    let corruptBackupURL = root.appendingPathComponent("history.json.corrupt-manual")
    try Data("not valid history".utf8).write(to: historyURL)
    try Data("older corrupt history".utf8).write(to: corruptBackupURL)
    let store = HistoryStore(fileURL: historyURL, recordingsDirectory: recordingDirectory)

    #expect(await store.clear())

    #expect(!FileManager.default.fileExists(atPath: historyURL.path))
    #expect(!FileManager.default.fileExists(atPath: corruptBackupURL.path))
    #expect(!FileManager.default.fileExists(atPath: firstManagedURL.path))
    #expect(!FileManager.default.fileExists(atPath: secondManagedURL.path))
    #expect(FileManager.default.fileExists(atPath: unrelatedURL.path))
}

@Test func customHistoryStoreReclaimsOnlyItsInjectedRecordingDirectory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let historyURL = root.appendingPathComponent("history.json")
    let managedDirectory = root.appendingPathComponent("Managed", isDirectory: true)
    let unrelatedDirectory = root.appendingPathComponent("Unrelated", isDirectory: true)
    let managedURL = try finishedManagedRecording(in: managedDirectory)
    let unrelatedURL = try finishedManagedRecording(in: unrelatedDirectory)
    let store = HistoryStore(fileURL: historyURL, recordingsDirectory: managedDirectory)

    await store.reclaimUnreferencedAudio(olderThan: Date().addingTimeInterval(1))

    #expect(!FileManager.default.fileExists(atPath: managedURL.path))
    #expect(FileManager.default.fileExists(atPath: unrelatedURL.path))
}
