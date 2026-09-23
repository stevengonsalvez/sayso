@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import SaysoCore

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
