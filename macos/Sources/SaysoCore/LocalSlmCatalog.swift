import Foundation

/// Installation and runtime state of an on-device SLM.
public enum LocalSlmState: Equatable, Sendable {
    case notInstalled
    case installing
    case installed
    case failed(String)

    public var isInstalled: Bool { self == .installed }
}

/// Metadata and artifact definitions for on-device Small Language Models (SLMs) used for local text cleanup.
public struct LocalSlmManifest: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let parameterCount: String
    public let quantizedSizeMb: Int
    public let summary: String
    public let downloadURL: URL
    public let fileName: String
    public let latencyTier: ModelLatencyTier
    public let isRecommended: Bool
    public let tags: [String]

    public init(
        id: String,
        displayName: String,
        parameterCount: String,
        quantizedSizeMb: Int,
        summary: String,
        downloadURL: URL,
        fileName: String,
        latencyTier: ModelLatencyTier = .instant,
        isRecommended: Bool = false,
        tags: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.parameterCount = parameterCount
        self.quantizedSizeMb = quantizedSizeMb
        self.summary = summary
        self.downloadURL = downloadURL
        self.fileName = fileName
        self.latencyTier = latencyTier
        self.isRecommended = isRecommended
        self.tags = tags
    }

    public var sizeDisplay: String {
        if quantizedSizeMb >= 1024 {
            return String(format: "%.1f GB", Double(quantizedSizeMb) / 1024.0)
        }
        return "\(quantizedSizeMb) MB"
    }
}

/// Catalog of on-device SLMs for local private post-processing cleanup.
public enum LocalSlmCatalog {
    public static let qwen05b = LocalSlmManifest(
        id: "local-slm/qwen2.5-0.5b",
        displayName: "Qwen 2.5 (0.5B) Instruct",
        parameterCount: "0.5B",
        quantizedSizeMb: 468,
        summary: "Fast on-device SLM. Smart dictation, action items, and context rewrite with minimal memory usage.",
        downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf")!,
        fileName: "qwen2.5-0.5b-instruct-q4_k_m.gguf",
        latencyTier: .instant,
        isRecommended: true,
        tags: ["⚡ Instant", "Recommended", "Low Memory"]
    )

    public static let smolLm360m = LocalSlmManifest(
        id: "local-slm/smollm2-360m",
        displayName: "SmolLM2 (360M) Instruct",
        parameterCount: "360M",
        quantizedSizeMb: 230,
        summary: "Smallest on-device model for quick punctuation, formatting, and grammar cleanup.",
        downloadURL: URL(string: "https://huggingface.co/bartowski/SmolLM2-360M-Instruct-GGUF/resolve/main/SmolLM2-360M-Instruct-Q4_K_M.gguf")!,
        fileName: "SmolLM2-360M-Instruct-Q4_K_M.gguf",
        latencyTier: .instant,
        isRecommended: false,
        tags: ["⚡ Instant", "Ultra Compact"]
    )

    public static let qwen15b = LocalSlmManifest(
        id: "local-slm/qwen2.5-1.5b",
        displayName: "Qwen 2.5 (1.5B) Instruct",
        parameterCount: "1.5B",
        quantizedSizeMb: 986,
        summary: "Higher accuracy on-device SLM for structured notes, technical prose, and tone refinement.",
        downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf")!,
        fileName: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
        latencyTier: .fast,
        isRecommended: false,
        tags: ["⚡ Fast", "Balanced"]
    )

    public static let phi3Mini = LocalSlmManifest(
        id: "local-slm/phi-3-mini",
        displayName: "Microsoft Phi-3 Mini (3.8B)",
        parameterCount: "3.8B",
        quantizedSizeMb: 2390,
        summary: "Microsoft high-reasoning on-device SLM for advanced restructuring and concise rewriting.",
        downloadURL: URL(string: "https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-gguf/resolve/main/Phi-3-mini-4k-instruct-q4.gguf")!,
        fileName: "Phi-3-mini-4k-instruct-q4.gguf",
        latencyTier: .medium,
        isRecommended: false,
        tags: ["High Reasoning", "Advanced"]
    )

    public static let all: [LocalSlmManifest] = [
        qwen05b,
        smolLm360m,
        qwen15b,
        phi3Mini
    ]

    public static let defaultModel: LocalSlmManifest = qwen05b
    public static var defaultSlm: LocalSlmManifest { defaultModel }

    public static func byId(_ id: String) -> LocalSlmManifest? {
        let normalized = id.lowercased()
        return all.first {
            $0.id.lowercased() == normalized ||
            $0.id.lowercased().hasSuffix(normalized) ||
            normalized.hasSuffix($0.fileName.lowercased())
        }
    }

    public static func find(id: String) -> LocalSlmManifest? {
        byId(id)
    }

    /// Resolves local storage directory for SLM models on macOS.
    public static func modelsDirectory(fileManager: FileManager = .default) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let slmDir = appSupport.appendingPathComponent("ai.sayso.SaysoNotch/models/slm", isDirectory: true)
        try? fileManager.createDirectory(at: slmDir, withIntermediateDirectories: true)
        return slmDir
    }

    /// Checks whether a specific SLM model is present on disk.
    public static func isInstalled(_ manifest: LocalSlmManifest, fileManager: FileManager = .default) -> Bool {
        let path = modelsDirectory(fileManager: fileManager).appendingPathComponent(manifest.fileName).path
        return fileManager.fileExists(atPath: path)
    }

    /// Returns size on disk in bytes if installed.
    public static func installedSizeBytes(_ manifest: LocalSlmManifest, fileManager: FileManager = .default) -> Int64? {
        let path = modelsDirectory(fileManager: fileManager).appendingPathComponent(manifest.fileName).path
        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else {
            return nil
        }
        return size
    }

    /// Deletes the installed model from disk.
    public static func delete(_ manifest: LocalSlmManifest, fileManager: FileManager = .default) throws {
        let url = modelsDirectory(fileManager: fileManager).appendingPathComponent(manifest.fileName)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}
