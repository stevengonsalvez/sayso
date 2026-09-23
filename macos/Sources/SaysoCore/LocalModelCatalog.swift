import Foundation

public enum LocalModelEngine: String, Codable, CaseIterable, Sendable {
    case sherpaONNX
}

public enum LocalModelArchitecture: String, Codable, CaseIterable, Sendable {
    case nemoTransducer
    case whisperEncoderDecoder
    case indicConformerCTC
    case moonshine
    case senseVoice
}

public enum LocalModelHostArchitecture: String, Codable, CaseIterable, Sendable {
    case appleSilicon
    case intel
}

public enum LocalModelLicense: Codable, Equatable, Sendable {
    case mit
    case apache20
    case ccBy40
    case custom(name: String, url: URL)

    public var displayName: String {
        switch self {
        case .mit: "MIT"
        case .apache20: "Apache-2.0"
        case .ccBy40: "CC-BY-4.0"
        case let .custom(name, _): name
        }
    }

    /// Custom model terms require an explicit distribution review before exposure.
    public var isApprovedForDistribution: Bool {
        switch self {
        case .mit, .apache20, .ccBy40: true
        case .custom: false
        }
    }
}

public struct LocalModelArtifact: Codable, Equatable, Sendable {
    public let url: URL
    public let relativePath: String
    public let byteCount: Int64
    public let sha256: String

    public init(url: URL, relativePath: String, byteCount: Int64, sha256: String) {
        self.url = url
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public enum LocalModelState: Equatable, Sendable {
    case notDownloaded
    case incomplete
    case installed
}

public enum LocalModelAvailability: Equatable, Sendable {
    case ready
    case downloadRequired
    case unavailable(reason: String)

    public var isSelectable: Bool { self == .ready }
}

public struct LocalModelEnvironment: Equatable, Sendable {
    public let hostArchitecture: LocalModelHostArchitecture
    public let availableEngines: Set<LocalModelEngine>

    public init(hostArchitecture: LocalModelHostArchitecture, availableEngines: Set<LocalModelEngine>) {
        self.hostArchitecture = hostArchitecture
        self.availableEngines = availableEngines
    }

    /// No third-party local runtime ships yet. A model cannot become selectable from this
    /// manifest alone.
    public static var app: LocalModelEnvironment {
        #if arch(arm64)
        .init(hostArchitecture: .appleSilicon, availableEngines: [])
        #else
        .init(hostArchitecture: .intel, availableEngines: [])
        #endif
    }
}

public struct LocalModelManifest: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let summary: String
    public let engine: LocalModelEngine
    public let architecture: LocalModelArchitecture
    public let supportedLanguages: Set<DictationLanguage>
    public let supportedHostArchitectures: Set<LocalModelHostArchitecture>
    public let license: LocalModelLicense
    public let artifacts: [LocalModelArtifact]
    public let expectedSizeBytes: Int64
    public let isRecommended: Bool

    public init(
        id: String,
        displayName: String,
        summary: String,
        engine: LocalModelEngine,
        architecture: LocalModelArchitecture,
        supportedLanguages: Set<DictationLanguage>,
        supportedHostArchitectures: Set<LocalModelHostArchitecture> = [.appleSilicon, .intel],
        license: LocalModelLicense,
        artifacts: [LocalModelArtifact],
        expectedSizeBytes: Int64,
        isRecommended: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.engine = engine
        self.architecture = architecture
        self.supportedLanguages = supportedLanguages
        self.supportedHostArchitectures = supportedHostArchitectures
        self.license = license
        self.artifacts = artifacts
        self.expectedSizeBytes = expectedSizeBytes
        self.isRecommended = isRecommended
    }

    public var downloadURLs: [URL] { artifacts.map(\.url) }

    public func supports(_ language: DictationLanguage) -> Bool {
        language != .automatic && supportedLanguages.contains(language)
    }
}

/// Immutable model manifest. Download, checksum validation, extraction and runtime loading
/// intentionally remain separate. A manifest entry is never a selectable dictation route.
public enum LocalModelCatalog {
    private static let sherpaRelease = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models"
    private static let indicRelease = "https://huggingface.co/parismitaglobalsolutions/indicconformer-sherpa-onnx/resolve/main"
    private static let supportedHosts: Set<LocalModelHostArchitecture> = [.appleSilicon, .intel]
    private static let indicLanguages: Set<DictationLanguage> = [
        .hindi, .tamil, .malayalam, .bengali, .gujarati, .kannada,
        .marathi, .punjabi, .telugu, .urdu,
    ]

    public static let all: [LocalModelManifest] = [
        archive(
            id: "sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8",
            displayName: "Parakeet 110M",
            summary: "Fast English daily dictation.",
            architecture: .nemoTransducer,
            languages: [.english],
            license: .ccBy40,
            expectedSizeBytes: 104_000_000,
            sha256: "17f945007b52ccd8b7200ffc7c5652e9e8e961dfdf479cefcabd06cf5703630b",
            recommended: true
        ),
        archive(
            id: "sherpa-onnx-whisper-tiny",
            displayName: "Whisper Multilingual Tiny",
            summary: "Compact multilingual fallback for English and Indian languages.",
            architecture: .whisperEncoderDecoder,
            languages: indicLanguages.union([.english]),
            license: .mit,
            expectedSizeBytes: 111_000_000,
            sha256: "c46116994e539aa165266d96b325252728429c12535eb9d8b6a2b10f129e66b1"
        ),
        archive(
            id: "sherpa-onnx-whisper-base",
            displayName: "Whisper Multilingual Base",
            summary: "Higher-accuracy multilingual fallback for English and Indian languages.",
            architecture: .whisperEncoderDecoder,
            languages: indicLanguages.union([.english]),
            license: .mit,
            expectedSizeBytes: 198_000_000,
            sha256: "911b2083efd7c0dca2ac3b358b75222660dc09fb716d64fbfc417ba6c99ff3de"
        ),
        indic(
            id: "ai4bharat-indicconformer-ta", displayName: "AI4Bharat Tamil",
            language: .tamil, languageCode: "ta", modelSizeBytes: 197_595_513,
            modelSHA256: "abb7b59d706b8d27ba3fb5e5e3db7671c9e1a09bf7bc6122de507c60030e65fb"
        ),
        indic(
            id: "ai4bharat-indicconformer-hi", displayName: "AI4Bharat Hindi",
            language: .hindi, languageCode: "hi", modelSizeBytes: 197_595_593,
            modelSHA256: "915c71e04dd7e5378a4057fdebb252b3a587188e4e99db6d7ce0909ad5ad05fa"
        ),
        indic(
            id: "ai4bharat-indicconformer-ml", displayName: "AI4Bharat Malayalam",
            language: .malayalam, languageCode: "ml", modelSizeBytes: 197_595_555,
            modelSHA256: "dcbdfa9f773db910508b40b703cb76c5974e8d4c6f123ea81265b40853c3f0c2"
        ),
        archive(
            id: "sherpa-onnx-moonshine-tiny-en-int8",
            displayName: "Moonshine Tiny",
            summary: "Small English model for quick local transcription.",
            architecture: .moonshine,
            languages: [.english],
            license: .mit,
            expectedSizeBytes: 108_000_000,
            sha256: "d5fe6ec4334fef36255b2a4010412cad4c007e33103fec62fb5d17cad88086f2"
        ),
        archive(
            id: "sherpa-onnx-moonshine-base-en-int8",
            displayName: "Moonshine Base",
            summary: "Higher-accuracy English local transcription.",
            architecture: .moonshine,
            languages: [.english],
            license: .mit,
            expectedSizeBytes: 251_000_000,
            sha256: "21870cecaa2e44e4e2bf63e02d1072bed183ccd10284871353bd9d24dad14e5e"
        ),
        archive(
            id: "sherpa-onnx-whisper-base.en",
            displayName: "Whisper Base English",
            summary: "English local transcription with robust punctuation.",
            architecture: .whisperEncoderDecoder,
            languages: [.english],
            license: .mit,
            expectedSizeBytes: 209_000_000,
            sha256: "475bc7052ce299c007f6d5d5407ba8601f819a2867f6eecee510ed17df581542"
        ),
        archive(
            id: "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8",
            displayName: "Parakeet 0.6B v3",
            summary: "Higher-capacity multilingual transcription.",
            architecture: .nemoTransducer,
            languages: [.english],
            license: .ccBy40,
            expectedSizeBytes: 487_000_000,
            sha256: "5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf"
        ),
        archive(
            id: "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09",
            displayName: "SenseVoice",
            summary: "English and East Asian speech recognition. Custom model terms require review.",
            architecture: .senseVoice,
            languages: [.english],
            license: .custom(
                name: "FunASR Model License",
                url: URL(string: "https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE")!
            ),
            expectedSizeBytes: 166_000_000,
            sha256: "7305f7905bfcf77fa0b39388a313f3da35c68d971661a65475b56fb2162c8e63"
        ),
    ]

    public static let recommendedEnglishModel = all.first { $0.isRecommended }!

    public static func model(id: String) -> LocalModelManifest? {
        all.first { $0.id == id }
    }

    public static func recommendedModel(for language: DictationLanguage) -> LocalModelManifest {
        switch language {
        case .tamil: model(id: "ai4bharat-indicconformer-ta")!
        case .hindi: model(id: "ai4bharat-indicconformer-hi")!
        case .malayalam: model(id: "ai4bharat-indicconformer-ml")!
        case .automatic, .bengali, .gujarati, .kannada, .marathi, .punjabi, .telugu, .urdu:
            model(id: "sherpa-onnx-whisper-tiny")!
        case .english: recommendedEnglishModel
        }
    }

    public static func state(
        for model: LocalModelManifest,
        in modelsDirectory: URL,
        fileManager: FileManager = .default
    ) -> LocalModelState {
        let directory = modelsDirectory.appending(path: model.id, directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            return .notDownloaded
        }
        guard isDirectory.boolValue else { return .incomplete }
        guard let files = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return .incomplete
        }
        return files.contains { ($0 as? URL)?.pathExtension == "onnx" } ? .installed : .incomplete
    }

    public static func availability(
        for model: LocalModelManifest,
        in modelsDirectory: URL,
        environment: LocalModelEnvironment = .app
    ) -> LocalModelAvailability {
        guard model.license.isApprovedForDistribution else {
            return .unavailable(reason: "Model license requires distribution review")
        }
        guard model.supportedHostArchitectures.contains(environment.hostArchitecture) else {
            return .unavailable(reason: "Model is unsupported on this Mac architecture")
        }
        switch state(for: model, in: modelsDirectory) {
        case .notDownloaded: return .downloadRequired
        case .incomplete: return .unavailable(reason: "Model installation is incomplete")
        case .installed:
            guard environment.availableEngines.contains(model.engine) else {
                return .unavailable(reason: "Required local runtime is not installed")
            }
            return .ready
        }
    }

    public static func selectable(
        in modelsDirectory: URL,
        environment: LocalModelEnvironment = .app
    ) -> [LocalModelManifest] {
        all.filter { availability(for: $0, in: modelsDirectory, environment: environment).isSelectable }
    }

    private static func archive(
        id: String,
        displayName: String,
        summary: String,
        architecture: LocalModelArchitecture,
        languages: Set<DictationLanguage>,
        license: LocalModelLicense,
        expectedSizeBytes: Int64,
        sha256: String,
        recommended: Bool = false
    ) -> LocalModelManifest {
        .init(
            id: id, displayName: displayName, summary: summary,
            engine: .sherpaONNX, architecture: architecture, supportedLanguages: languages,
            supportedHostArchitectures: supportedHosts, license: license,
            artifacts: [.init(
                url: URL(string: "\(sherpaRelease)/\(id).tar.bz2")!,
                relativePath: "\(id).tar.bz2", byteCount: expectedSizeBytes, sha256: sha256
            )], expectedSizeBytes: expectedSizeBytes, isRecommended: recommended
        )
    }

    private static func indic(
        id: String,
        displayName: String,
        language: DictationLanguage,
        languageCode: String,
        modelSizeBytes: Int64,
        modelSHA256: String
    ) -> LocalModelManifest {
        let tokensSizeBytes: Int64 = 67_605
        let tokensSHA256 = "ee60967630213f31951817ac8b402b92ec18cce80718a24a49b388e56672dfb2"
        return .init(
            id: id, displayName: displayName, summary: "Colloquial \(language.displayName) dictation.",
            engine: .sherpaONNX, architecture: .indicConformerCTC, supportedLanguages: [language],
            supportedHostArchitectures: supportedHosts, license: .apache20,
            artifacts: [
                .init(
                    url: URL(string: "\(indicRelease)/\(languageCode)/model.int8.onnx")!,
                    relativePath: "model.int8.onnx", byteCount: modelSizeBytes, sha256: modelSHA256
                ),
                .init(
                    url: URL(string: "\(indicRelease)/tokens.txt")!,
                    relativePath: "tokens.txt", byteCount: tokensSizeBytes, sha256: tokensSHA256
                ),
            ], expectedSizeBytes: modelSizeBytes + tokensSizeBytes
        )
    }
}
