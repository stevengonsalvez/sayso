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
    #expect(LiveTranscriber.prefersNativeFluidAudio(language: .english, route: .local, models: manager))
    #expect(!LiveTranscriber.prefersNativeFluidAudio(language: .tamil, route: .local, models: manager))
    #expect(transcriber.requiresSpeechRecognition(language: .english, route: .appleSpeech))
    #expect(FileTranscriber.prefersFluidAudio(language: .english, route: .local, localModelReady: true))
    #expect(!FileTranscriber.prefersFluidAudio(language: .english, route: .local, localModelReady: false))
}

@Test @MainActor func installedNativeMultilingualModelRoutesIndianLanguagesWithoutSpeechPermission() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = FluidAudioLocalModelManager(modelsDirectory: root)
    let modelDirectory = root
        .appending(path: Repo.nemotronMultilingual.folderName, directoryHint: .isDirectory)
        .appending(path: "multilingual", directoryHint: .isDirectory)
        .appending(path: "\(FluidAudioLocalModelManager.multilingualChunkMilliseconds)ms", directoryHint: .isDirectory)
    let artifacts = [
        ModelNames.NemotronMultilingualStreaming.metadata,
        ModelNames.NemotronMultilingualStreaming.tokenizer,
        ModelNames.NemotronMultilingualStreaming.encoderFile,
        ModelNames.NemotronMultilingualStreaming.decoderFile,
        ModelNames.NemotronMultilingualStreaming.jointFile,
    ]
    for artifact in artifacts {
        let artifactURL = modelDirectory.appending(path: artifact)
        try FileManager.default.createDirectory(at: artifactURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: artifactURL)
    }

    manager.refresh()

    let transcriber = LiveTranscriber(fluidAudioModels: manager)
    let supportedLanguages: [(DictationLanguage, String)] = [
        (.hindi, "hi-IN"), (.tamil, "ta-IN"), (.malayalam, "ml-IN"),
        (.bengali, "bn-IN"), (.gujarati, "gu-IN"), (.kannada, "kn-IN"),
        (.marathi, "mr-IN"), (.telugu, "te-IN"), (.urdu, "ur-PK"),
    ]
    for (language, languageCode) in supportedLanguages {
        #expect(!transcriber.requiresSpeechRecognition(language: language, route: .local))
        #expect(LiveTranscriber.prefersNativeFluidAudio(language: language, route: .local, models: manager))
        #expect(FileTranscriber.prefersFluidAudio(language: language, route: .local, localModelReady: true))
        #expect(FluidAudioLocalModelManager.nemotronLanguageCode(for: language) == languageCode)
    }
    #expect(!LiveTranscriber.prefersNativeFluidAudio(language: .english, route: .local, models: manager))
    #expect(!FileTranscriber.prefersFluidAudio(language: .punjabi, route: .local, localModelReady: true))
}

@Test @MainActor func localPunjabiRequiresItsOfflineModelBeforeAudioOrSpeechSetup() async throws {
    let fileURL = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    try Data().write(to: fileURL)

    await #expect(throws: SaysoError.unavailable("Download the local Punjabi model before dictating.")) {
        try await FileTranscriber.transcribe(fileURL: fileURL, language: .punjabi, route: .local)
    }
}
