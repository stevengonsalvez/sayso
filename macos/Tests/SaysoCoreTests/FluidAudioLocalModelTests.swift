import FluidAudio
import Foundation
import Testing
@testable import SaysoCore

@Test @MainActor func fluidAudioModelRequiresEveryArtifact() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = FluidAudioLocalModelManager(modelsDirectory: root)

    #expect(manager.state == .notInstalled)

    let modelDirectory = root.appending(path: Repo.parakeetEou160.folderName, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
    for artifact in ModelNames.ParakeetEOU.requiredModels {
        let artifactURL = modelDirectory.appending(path: artifact)
        try FileManager.default.createDirectory(at: artifactURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: artifactURL)
    }

    manager.refresh()
    #expect(manager.state == .installed)
    manager.delete()
    #expect(manager.state == .notInstalled)
}

@Test @MainActor func installedNativeEnglishModelSkipsSpeechPermission() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = FluidAudioLocalModelManager(modelsDirectory: root)
    let modelDirectory = root.appending(path: Repo.parakeetEou160.folderName, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
    for artifact in ModelNames.ParakeetEOU.requiredModels {
        let artifactURL = modelDirectory.appending(path: artifact)
        try FileManager.default.createDirectory(at: artifactURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: artifactURL)
    }
    manager.refresh()

    let transcriber = LiveTranscriber(fluidAudioModels: manager)
    #expect(!transcriber.requiresSpeechRecognition(language: .english, route: .local))
    #expect(transcriber.requiresSpeechRecognition(language: .tamil, route: .local))
    #expect(transcriber.requiresSpeechRecognition(language: .english, route: .appleSpeech))
    #expect(FileTranscriber.prefersFluidAudio(language: .english, route: .local, localModelReady: true))
    #expect(!FileTranscriber.prefersFluidAudio(language: .english, route: .local, localModelReady: false))
}
