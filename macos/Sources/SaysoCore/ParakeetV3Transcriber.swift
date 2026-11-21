import FluidAudio
import Foundation

/// Which on-device engine transcribes a finished English recording.
public enum LocalBatchEngine: Equatable, Sendable {
    case parakeetV3
    case realtimeEOU

    /// Parakeet TDT 0.6B v3 punctuates and spells words far better than the small realtime model, so it is
    /// used for English whenever its files are on this Mac; everything else keeps the existing engine.
    public static func choose(language: DictationLanguage, parakeetV3Installed: Bool) -> LocalBatchEngine {
        language == .english && parakeetV3Installed ? .parakeetV3 : .realtimeEOU
    }
}

/// English on-device transcription of a recorded file with Parakeet TDT 0.6B v3 (FluidAudio). Audio stays on this Mac.
public actor ParakeetV3Transcriber {
    public static let shared = ParakeetV3Transcriber()
    public static let displayName = "Parakeet TDT 0.6B v3"

    private var manager: AsrManager?

    /// True when the model files are already in FluidAudio's models folder.
    public nonisolated static var isInstalled: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
    }

    public func transcribe(fileURL: URL) async throws -> String {
        let manager = try await loadedManager()
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(fileURL, decoderState: &state, language: .english)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadedManager() async throws -> AsrManager {
        if let manager { return manager }
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let created = AsrManager()
        try await created.loadModels(models)
        manager = created
        return created
    }
}
