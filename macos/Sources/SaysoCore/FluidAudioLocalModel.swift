@preconcurrency import CoreML
@preconcurrency import AVFoundation
import FluidAudio
import Foundation

public enum FluidAudioLocalModelError: LocalizedError, Equatable, Sendable {
    case unsupportedHardware
    case notInstalled
    case unsupportedLanguage(DictationLanguage)

    public var errorDescription: String? {
        switch self {
        case .unsupportedHardware: "Native transcription needs Apple silicon."
        case .notInstalled: "Download the local model before dictating."
        case let .unsupportedLanguage(language): "No native FluidAudio model for \(language.displayName)."
        }
    }
}

public enum FluidAudioLocalModelState: Equatable, Sendable {
    case notInstalled
    case installing
    case installed
    case failed(String)

    public var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }
}

enum FluidAudioLocalSession: Sendable {
    case english(StreamingEouAsrManager)
    case multilingual(StreamingNemotronMultilingualAsrManager)

    func reset() async {
        switch self {
        case let .english(manager): await manager.reset()
        case let .multilingual(manager): await manager.reset()
        }
    }

    func setPartialCallback(_ callback: @escaping @Sendable (String) -> Void) async {
        switch self {
        case let .english(manager): await manager.setPartialCallback(callback)
        case let .multilingual(manager): await manager.setPartialCallback(callback)
        }
    }

    func process(audioBuffer: AVAudioPCMBuffer) async throws -> String {
        switch self {
        case let .english(manager): try await manager.process(audioBuffer: audioBuffer)
        case let .multilingual(manager): try await manager.process(audioBuffer: audioBuffer)
        }
    }

    func finish() async throws -> String {
        switch self {
        case let .english(manager): try await manager.finish()
        case let .multilingual(manager): try await manager.finish()
        }
    }

    func cleanup() async {
        switch self {
        case let .english(manager): await manager.cleanup()
        case let .multilingual(manager): await manager.cleanup()
        }
    }
}

/// Native Apple-silicon transcription models. Files remain on this Mac.
@MainActor
public final class FluidAudioLocalModelManager: ObservableObject {
    public static let modelID = "local/streaming/fluidaudio/parakeet-realtime-eou-120m"
    public static let displayName = "Parakeet Realtime EOU 120M"
    public static let multilingualModelID = "local/streaming/fluidaudio/nemotron-multilingual-0.6b"
    public static let multilingualDisplayName = "Nemotron Multilingual 0.6B"
    public static let multilingualChunkMilliseconds = 2240

    @Published public private(set) var state: FluidAudioLocalModelState = .notInstalled
    @Published public private(set) var downloadProgress = 0.0
    @Published public private(set) var multilingualState: FluidAudioLocalModelState = .notInstalled
    @Published public private(set) var multilingualDownloadProgress = 0.0

    private let fileManager: FileManager
    public let modelsDirectory: URL

    public static var supportsCurrentHardware: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    public static func supportsNativeModel(for language: DictationLanguage) -> Bool {
        language == .english || nemotronLanguageCode(for: language) != nil
    }

    public static func nemotronLanguageCode(for language: DictationLanguage) -> String? {
        switch language {
        case .hindi: "hi-IN"
        case .tamil: "ta-IN"
        case .malayalam: "ml-IN"
        case .bengali: "bn-IN"
        case .gujarati: "gu-IN"
        case .kannada: "kn-IN"
        case .marathi: "mr-IN"
        case .telugu: "te-IN"
        case .urdu: "ur-PK"
        case .automatic, .english, .punjabi: nil
        }
    }

    public init(fileManager: FileManager = .default, modelsDirectory: URL? = nil) {
        self.fileManager = fileManager
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        self.modelsDirectory = modelsDirectory ?? appSupport
            .appending(path: "SaysoNotch", directoryHint: .isDirectory)
            .appending(path: "LocalModels", directoryHint: .isDirectory)
            .appending(path: "FluidAudio", directoryHint: .isDirectory)
        refresh()
    }

    public func refresh() {
        if state != .installing {
            state = requiredArtifactsExist ? .installed : .notInstalled
            downloadProgress = state.isInstalled ? 1 : 0
        }
        if multilingualState != .installing {
            multilingualState = requiredMultilingualArtifactsExist ? .installed : .notInstalled
            multilingualDownloadProgress = multilingualState.isInstalled ? 1 : 0
        }
    }

    public func install() async {
        guard Self.supportsCurrentHardware else {
            state = .failed(FluidAudioLocalModelError.unsupportedHardware.localizedDescription)
            return
        }
        guard state != .installing else { return }

        state = .installing
        downloadProgress = 0
        do {
            try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            let manager = StreamingEouAsrManager(configuration: Self.configuration, chunkSize: .ms160)
            try await manager.loadModels(
                to: modelsDirectory,
                configuration: Self.configuration,
                progressHandler: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.downloadProgress = max(0, min(progress.fractionCompleted, 1))
                    }
                }
            )
            await manager.cleanup()
            guard requiredArtifactsExist else { throw FluidAudioLocalModelError.notInstalled }
            downloadProgress = 1
            state = .installed
        } catch {
            removePartialModel()
            state = .failed(error.localizedDescription)
        }
    }

    public func install(language: DictationLanguage) async {
        if language == .english {
            await install()
            return
        }
        guard let languageCode = Self.nemotronLanguageCode(for: language) else {
            multilingualState = .failed(FluidAudioLocalModelError.unsupportedLanguage(language).localizedDescription)
            return
        }
        guard Self.supportsCurrentHardware else {
            multilingualState = .failed(FluidAudioLocalModelError.unsupportedHardware.localizedDescription)
            return
        }
        guard multilingualState != .installing else { return }

        multilingualState = .installing
        multilingualDownloadProgress = 0
        do {
            try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            let directory = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                languageCode: languageCode,
                chunkMs: Self.multilingualChunkMilliseconds,
                to: modelsDirectory,
                progressHandler: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.multilingualDownloadProgress = max(0, min(progress.fractionCompleted, 1))
                    }
                }
            )
            let manager = StreamingNemotronMultilingualAsrManager(configuration: Self.configuration)
            try await manager.loadModels(from: directory)
            await manager.cleanup()
            guard requiredMultilingualArtifactsExist else { throw FluidAudioLocalModelError.notInstalled }
            multilingualDownloadProgress = 1
            multilingualState = .installed
        } catch {
            removePartialMultilingualModel()
            multilingualState = .failed(error.localizedDescription)
        }
    }

    public func delete() {
        guard state != .installing else { return }
        do {
            if fileManager.fileExists(atPath: modelDirectory.path) {
                try fileManager.removeItem(at: modelDirectory)
            }
            state = .notInstalled
            downloadProgress = 0
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    public func deleteMultilingual() {
        guard multilingualState != .installing else { return }
        do {
            if fileManager.fileExists(atPath: multilingualModelDirectory.path) {
                try fileManager.removeItem(at: multilingualModelDirectory)
            }
            multilingualState = .notInstalled
            multilingualDownloadProgress = 0
        } catch {
            multilingualState = .failed(error.localizedDescription)
        }
    }

    public func isInstalled(for language: DictationLanguage) -> Bool {
        switch language {
        case .english: state.isInstalled
        default: Self.nemotronLanguageCode(for: language) != nil && multilingualState.isInstalled
        }
    }

    public func makeReadyManager() async throws -> StreamingEouAsrManager {
        guard Self.supportsCurrentHardware else { throw FluidAudioLocalModelError.unsupportedHardware }
        refresh()
        guard state.isInstalled else { throw FluidAudioLocalModelError.notInstalled }

        let manager = StreamingEouAsrManager(configuration: Self.configuration, chunkSize: .ms160)
        try await manager.loadModels(to: modelsDirectory, configuration: Self.configuration)
        return manager
    }

    func makeReadySession(for language: DictationLanguage) async throws -> FluidAudioLocalSession {
        guard Self.supportsCurrentHardware else { throw FluidAudioLocalModelError.unsupportedHardware }
        refresh()
        if language == .english {
            return .english(try await makeReadyManager())
        }
        guard let languageCode = Self.nemotronLanguageCode(for: language) else {
            throw FluidAudioLocalModelError.unsupportedLanguage(language)
        }
        guard multilingualState.isInstalled else { throw FluidAudioLocalModelError.notInstalled }

        let manager = StreamingNemotronMultilingualAsrManager(configuration: Self.configuration)
        try await manager.loadModels(from: multilingualModelDirectory)
        await manager.setLanguage(languageCode)
        await manager.setForcedPrefix(true)
        return .multilingual(manager)
    }

    private var modelDirectory: URL {
        modelsDirectory.appending(path: Repo.parakeetEou160.folderName, directoryHint: .isDirectory)
    }

    private var multilingualModelDirectory: URL {
        modelsDirectory
            .appending(path: Repo.nemotronMultilingual.folderName, directoryHint: .isDirectory)
            .appending(path: "multilingual", directoryHint: .isDirectory)
            .appending(path: "\(Self.multilingualChunkMilliseconds)ms", directoryHint: .isDirectory)
    }

    private var requiredArtifactsExist: Bool {
        ModelNames.ParakeetEOU.requiredModels.allSatisfy {
            fileManager.fileExists(atPath: modelDirectory.appending(path: $0).path)
        }
    }

    private var requiredMultilingualArtifactsExist: Bool {
        let required = [
            ModelNames.NemotronMultilingualStreaming.metadata,
            ModelNames.NemotronMultilingualStreaming.tokenizer,
        ]
        guard required.allSatisfy({
            fileManager.fileExists(atPath: multilingualModelDirectory.appending(path: $0).path)
        }) else { return false }

        let hasEncoder = hasMultilingualModel(
            ModelNames.NemotronMultilingualStreaming.encoderFile,
            package: ModelNames.NemotronMultilingualStreaming.encoderPackage
        )
        let hasBareDecodePath = hasMultilingualModel(
            ModelNames.NemotronMultilingualStreaming.decoderFile,
            package: ModelNames.NemotronMultilingualStreaming.decoderPackage
        ) && hasMultilingualModel(
            ModelNames.NemotronMultilingualStreaming.jointFile,
            package: ModelNames.NemotronMultilingualStreaming.jointPackage
        )
        let hasFusedDecodePath = ["decoder_joint", "decoder_joint_noencproj", "decoder_joint_argmax"].contains {
            hasMultilingualModel("\($0).mlmodelc", package: "\($0).mlpackage")
        }
        return hasEncoder && (hasBareDecodePath || hasFusedDecodePath)
    }

    private func hasMultilingualModel(_ compiled: String, package: String) -> Bool {
        fileManager.fileExists(atPath: multilingualModelDirectory.appending(path: compiled).path)
            || fileManager.fileExists(atPath: multilingualModelDirectory.appending(path: package).path)
    }

    private func removePartialModel() {
        try? fileManager.removeItem(at: modelDirectory)
        downloadProgress = 0
    }

    private func removePartialMultilingualModel() {
        try? fileManager.removeItem(at: multilingualModelDirectory)
        multilingualDownloadProgress = 0
    }

    private static var configuration: MLModelConfiguration {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        configuration.allowLowPrecisionAccumulationOnGPU = true
        return configuration
    }
}
