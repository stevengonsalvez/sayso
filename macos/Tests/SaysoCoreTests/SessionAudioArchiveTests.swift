@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import SaysoCore

private func finishedManagedRecording() throws -> URL {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let archive = try SessionAudioArchive(inputFormat: format)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
    buffer.frameLength = 8
    archive.append(buffer)
    return try #require(archive.finish())
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

@Test func historyRemovalDeletesItsManagedAudioAfterMetadataPersists() async throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let archive = try SessionAudioArchive(inputFormat: format)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
    buffer.frameLength = 8
    archive.append(buffer)
    let audioURL = try #require(archive.finish())
    let historyURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
        try? FileManager.default.removeItem(at: historyURL)
        SessionAudioArchive.deleteManagedRecording(audioURL)
    }
    let store = HistoryStore(fileURL: historyURL)
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
    let firstAudioURL = try finishedManagedRecording()
    let replacementAudioURL = try finishedManagedRecording()
    defer {
        SessionAudioArchive.deleteManagedRecording(firstAudioURL)
        SessionAudioArchive.deleteManagedRecording(replacementAudioURL)
    }
    let historyURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: historyURL) }
    let store = HistoryStore(fileURL: historyURL)
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
    let audioURL = try finishedManagedRecording()
    defer { SessionAudioArchive.deleteManagedRecording(audioURL) }
    let historyURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: historyURL) }
    let store = HistoryStore(fileURL: historyURL, maximumEntries: 1)
    let first = Transcript(text: "First", language: .english, route: .local, isFinal: true, audioFileURL: audioURL)
    let second = Transcript(text: "Second", language: .english, route: .local, isFinal: true, audioFileURL: audioURL)

    #expect(await store.append(first))
    #expect(await store.append(second))
    #expect(await store.all().map(\.id) == [second.id])
    #expect(FileManager.default.fileExists(atPath: audioURL.path))
    #expect(await store.remove(id: second.id))
    #expect(!FileManager.default.fileExists(atPath: audioURL.path))
}

@Test func clearingHistoryDoesNotDeleteAnUncommittedFinalRecording() async throws {
    let historicalAudioURL = try finishedManagedRecording()
    let finalAudioURL = try finishedManagedRecording()
    defer {
        SessionAudioArchive.deleteManagedRecording(historicalAudioURL)
        SessionAudioArchive.deleteManagedRecording(finalAudioURL)
    }
    let historyURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: historyURL) }
    let store = HistoryStore(fileURL: historyURL)

    #expect(await store.append(.init(text: "Existing", language: .english, route: .local, isFinal: true, audioFileURL: historicalAudioURL)))
    #expect(await store.clear())
    #expect(!FileManager.default.fileExists(atPath: historicalAudioURL.path))
    #expect(FileManager.default.fileExists(atPath: finalAudioURL.path))

    #expect(await store.append(.init(text: "Final", language: .english, route: .local, isFinal: true, audioFileURL: finalAudioURL)))
    #expect(await store.all().first?.audioFileURL == finalAudioURL)
}
