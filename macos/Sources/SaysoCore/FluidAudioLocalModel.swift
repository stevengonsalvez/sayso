@preconcurrency import CoreML
import FluidAudio
import Foundation

public enum FluidAudioLocalModelError: LocalizedError, Equatable, Sendable {
    case unsupportedHardware
    case notInstalled

    public var errorDescription: String? {
        switch self {
        case .unsupportedHardware: "Local Parakeet needs Apple silicon."
        case .notInstalled: "Download the local English model before dictating."
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

/// Native Apple-silicon English transcription model. Files remain on this Mac.
@MainActor
public final class FluidAudioLocalModelManager: ObservableObject {
    public static let modelID = "local/streaming/fluidaudio/parakeet-realtime-eou-120m"
    public static let displayName = "Parakeet Realtime EOU 120M"

    @Published public private(set) var state: FluidAudioLocalModelState = .notInstalled
    @Published public private(set) var downloadProgress = 0.0

    private let fileManager: FileManager
    public let modelsDirectory: URL

    public static var supportsCurrentHardware: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
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
        guard state != .installing else { return }
        state = requiredArtifactsExist ? .installed : .notInstalled
        downloadProgress = state.isInstalled ? 1 : 0
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

    public func makeReadyManager() async throws -> StreamingEouAsrManager {
        guard Self.supportsCurrentHardware else { throw FluidAudioLocalModelError.unsupportedHardware }
        refresh()
        guard state.isInstalled else { throw FluidAudioLocalModelError.notInstalled }

        let manager = StreamingEouAsrManager(configuration: Self.configuration, chunkSize: .ms160)
        try await manager.loadModels(to: modelsDirectory, configuration: Self.configuration)
        return manager
    }

    private var modelDirectory: URL {
        modelsDirectory.appending(path: Repo.parakeetEou160.folderName, directoryHint: .isDirectory)
    }

    private var requiredArtifactsExist: Bool {
        ModelNames.ParakeetEOU.requiredModels.allSatisfy {
            fileManager.fileExists(atPath: modelDirectory.appending(path: $0).path)
        }
    }

    private func removePartialModel() {
        try? fileManager.removeItem(at: modelDirectory)
        downloadProgress = 0
    }

    private static var configuration: MLModelConfiguration {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        configuration.allowLowPrecisionAccumulationOnGPU = true
        return configuration
    }
}
