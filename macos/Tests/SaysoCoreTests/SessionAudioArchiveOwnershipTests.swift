import Foundation
import Testing
@testable import SaysoCore

@Test func historyCleanupRetainsForeignAudioAndRemovesOwnedFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let foreign = directory.appendingPathComponent("meeting.m4a")
    let owned = directory.appendingPathComponent("Recording-\(UUID().uuidString).m4a")
    try Data([0]).write(to: foreign)
    try Data([0]).write(to: owned)

    #expect(!SessionAudioArchive.isManagedRecording(foreign, directory: directory))
    #expect(SessionAudioArchive.isManagedRecording(owned, directory: directory))

    SessionAudioArchive.sweepUnreferencedRecordings(retaining: [], directory: directory)

    #expect(FileManager.default.fileExists(atPath: foreign.path))
    #expect(!FileManager.default.fileExists(atPath: owned.path))
}
