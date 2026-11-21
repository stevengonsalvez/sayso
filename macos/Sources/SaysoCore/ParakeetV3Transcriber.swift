import CoreML
import FluidAudio
import Foundation
import OSLog

/// Which on-device engine transcribes a finished recording.
public enum LocalBatchEngine: Equatable, Sendable {
    case parakeetV3
    case realtimeEOU

    /// Parakeet TDT 0.6B v3 punctuates and spells words far better than the small realtime model, so it is
    /// used for English on the local route whenever its files are on this Mac; everything else keeps the
    /// existing engine.
    public static func choose(
        route: ProviderRoute,
        language: DictationLanguage,
        parakeetV3Installed: Bool
    ) -> LocalBatchEngine {
        route == .local && language == .english && parakeetV3Installed ? .parakeetV3 : .realtimeEOU
    }

    /// Runs `body`; a failure other than cancellation is logged and returns nil so the caller carries on down the
    /// existing engine chain instead of losing the recording.
    public static func attempt<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T? {
        do {
            return try await body()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Logger(subsystem: "ai.sayso.notch", category: "ParakeetV3")
                .error("Parakeet v3 failed, using the next engine: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// English on-device transcription of a recorded file with Parakeet TDT 0.6B v3 (FluidAudio). Audio stays on this Mac.
/// The model files are loaded straight from disk: FluidAudio's own loaders delete the model folder and download it
/// again when a load fails, and that folder is shared with other apps, so Sayso never calls them.
public actor ParakeetV3Transcriber {
    public static let shared = ParakeetV3Transcriber()
    public static let displayName = "Parakeet TDT 0.6B v3"

    private static var directory: URL { AsrModels.defaultCacheDirectory(for: .v3) }
    private static let requiredFiles = [
        ModelNames.ASR.preprocessorFile, ModelNames.ASR.encoderFile, ModelNames.ASR.decoderFile,
        ModelNames.ASR.jointV3File, ModelNames.ASR.vocabularyFile,
    ]

    private var loading: Task<AsrManager, Error>?

    /// True on Apple silicon when every file Sayso needs is already in FluidAudio's models folder.
    public nonisolated static var isInstalled: Bool {
        #if arch(arm64)
        return requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: directory.appending(path: $0).path) }
        #else
        return false
        #endif
    }

    /// Returns "" for a recording too short to hold speech, like the other engines.
    public func transcribe(fileURL: URL) async throws -> String {
        let manager = try await loadedManager()
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        do {
            let result = try await manager.transcribe(fileURL, decoderState: &state, language: .english)
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch ASRError.invalidAudioData {
            return ""
        }
    }

    private func loadedManager() async throws -> AsrManager {
        if let loading { return try await loading.value }
        let task = Task { try await Self.loadFromDisk() }
        loading = task
        do {
            return try await task.value
        } catch {
            loading = nil
            throw error
        }
    }

    private static func loadFromDisk() async throws -> AsrManager {
        let directory = Self.directory
        func model(_ name: String, units: MLComputeUnits) throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            return try MLModel(contentsOf: directory.appending(path: name), configuration: configuration)
        }
        let vocabularyData = try Data(contentsOf: directory.appending(path: ModelNames.ASR.vocabularyFile))
        guard let json = try JSONSerialization.jsonObject(with: vocabularyData) as? [String: String] else {
            throw SaysoError.unavailable("Parakeet vocabulary file")
        }
        var vocabulary: [Int: String] = [:]
        for (key, value) in json {
            if let id = Int(key) { vocabulary[id] = value }
        }
        let models = AsrModels(
            encoder: try model(ModelNames.ASR.encoderFile, units: .cpuAndNeuralEngine),
            preprocessor: try model(ModelNames.ASR.preprocessorFile, units: .cpuOnly),
            decoder: try model(ModelNames.ASR.decoderFile, units: .cpuAndNeuralEngine),
            joint: try model(ModelNames.ASR.jointV3File, units: .cpuAndNeuralEngine),
            configuration: AsrModels.defaultConfiguration(),
            vocabulary: vocabulary,
            version: .v3
        )
        let manager = AsrManager()
        try await manager.loadModels(models)
        return manager
    }
}
