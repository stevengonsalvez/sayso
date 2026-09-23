@preconcurrency import AVFoundation
import Foundation
import SherpaOnnx

public enum SherpaPunjabiModelError: LocalizedError, Equatable, Sendable {
    case notInstalled
    case unsupportedLanguage(DictationLanguage)
    case unsupportedAudioFormat

    public var errorDescription: String? {
        switch self {
        case .notInstalled: "Download the local Punjabi model before dictating."
        case let .unsupportedLanguage(language): "No local Sherpa model for \(language.displayName)."
        case .unsupportedAudioFormat: "Punjabi model needs PCM audio."
        }
    }
}

public enum SherpaPunjabiModelState: Equatable, Sendable {
    case notInstalled
    case installing
    case installed
    case failed(String)

    public var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }
}

/// Installed Punjabi model and its local-only Sherpa runtime.
@MainActor
public final class SherpaPunjabiModelManager: ObservableObject {
    nonisolated public static let modelID = "ai4bharat-indicconformer-pa"
    nonisolated public static let displayName = "AI4Bharat Punjabi"

    @Published public private(set) var state: SherpaPunjabiModelState = .notInstalled

    private let fileManager: FileManager
    public let modelsDirectory: URL

    public static var model: LocalModelManifest {
        LocalModelCatalog.model(id: modelID)!
    }

    public init(fileManager: FileManager = .default, modelsDirectory: URL? = nil) {
        self.fileManager = fileManager
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        self.modelsDirectory = modelsDirectory ?? appSupport
            .appending(path: "SaysoNotch", directoryHint: .isDirectory)
            .appending(path: "LocalModels", directoryHint: .isDirectory)
            .appending(path: "SherpaONNX", directoryHint: .isDirectory)
        refresh()
    }

    public func refresh() {
        guard state != .installing else { return }
        state = LocalModelCatalog.state(for: Self.model, in: modelsDirectory, fileManager: fileManager) == .installed
            ? .installed
            : .notInstalled
    }

    public func install() async {
        guard state != .installing else { return }
        state = .installing
        do {
            _ = try await LocalModelDownloader().install(
                Self.model,
                in: modelsDirectory,
                environment: .init(
                    hostArchitecture: Self.hostArchitecture,
                    availableEngines: [.sherpaONNX]
                )
            )
            refresh()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    public func delete() {
        guard state != .installing else { return }
        do {
            let directory = modelDirectory
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
            state = .notInstalled
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func makeReadySession(for language: DictationLanguage) throws -> SherpaPunjabiLocalSession {
        guard language == .punjabi else { throw SherpaPunjabiModelError.unsupportedLanguage(language) }
        refresh()
        guard state.isInstalled else { throw SherpaPunjabiModelError.notInstalled }
        return try SherpaPunjabiLocalSession(modelDirectory: modelDirectory)
    }

    private static var hostArchitecture: LocalModelHostArchitecture {
        #if arch(arm64)
        .appleSilicon
        #else
        .intel
        #endif
    }

    private var modelDirectory: URL {
        modelsDirectory.appending(path: Self.modelID, directoryHint: .isDirectory)
    }
}

/// Offline CTC session. It keeps raw microphone samples local and emits only at stop.
actor SherpaPunjabiLocalSession {
    private final class ConversionInput: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var supplied = false

        init(buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }
    }

    private let recognizer: SherpaOnnxOfflineRecognizer
    private var stream: SherpaOnnxOfflineStreamWrapper
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    init(modelDirectory: URL) throws {
        let model = modelDirectory.appending(path: "model.int8.onnx")
        let tokens = modelDirectory.appending(path: "tokens.txt")
        guard FileManager.default.fileExists(atPath: model.path),
              FileManager.default.fileExists(atPath: tokens.path) else {
            throw SherpaPunjabiModelError.notInstalled
        }
        let nemo = sherpaOnnxOfflineNemoEncDecCtcModelConfig(model: model.path)
        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: tokens.path,
            nemoCtc: nemo,
            numThreads: 2,
            modelType: "nemo_ctc"
        )
        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80),
            modelConfig: modelConfig
        )
        recognizer = SherpaOnnxOfflineRecognizer(config: &config)
        stream = recognizer.createStream()
    }

    func append(audioBuffer: AVAudioPCMBuffer) throws {
        guard audioBuffer.frameLength > 0 else { return }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else { throw SherpaPunjabiModelError.unsupportedAudioFormat }
        if converter == nil || converterInputFormat?.isEqual(audioBuffer.format) == false {
            converter = AVAudioConverter(from: audioBuffer.format, to: targetFormat)
            converterInputFormat = audioBuffer.format
        }
        guard let converter else { throw SherpaPunjabiModelError.unsupportedAudioFormat }
        let capacity = AVAudioFrameCount(max(1_024, Int(Double(audioBuffer.frameLength) * 16_000 / audioBuffer.format.sampleRate) + 128))
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw SherpaPunjabiModelError.unsupportedAudioFormat
        }
        let input = ConversionInput(buffer: audioBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
            if input.supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            input.supplied = true
            inputStatus.pointee = .haveData
            return input.buffer
        }
        if status == .error {
            throw conversionError ?? SherpaPunjabiModelError.unsupportedAudioFormat
        }
        guard let channel = converted.floatChannelData?[0] else {
            throw SherpaPunjabiModelError.unsupportedAudioFormat
        }
        stream.acceptWaveform(
            samples: Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))),
            sampleRate: 16_000
        )
    }

    func finish() throws -> String {
        recognizer.decode(stream: stream)
        return recognizer.getResult(stream: stream).text
    }

    func reset() {
        stream = recognizer.createStream()
        converter = nil
        converterInputFormat = nil
    }
}
