import Foundation

/// Latency and speed tiers for speech and language models.
public enum ModelLatencyTier: String, Codable, CaseIterable, Comparable, Sendable {
    case instant
    case fast
    case medium
    case slow

    public var displayName: String {
        switch self {
        case .instant: "Instant"
        case .fast: "Fast"
        case .medium: "Standard"
        case .slow: "Slow"
        }
    }

    public var badgeText: String {
        switch self {
        case .instant: "⚡ Instant"
        case .fast: "⚡ Fast"
        case .medium: "Standard"
        case .slow: "Slow"
        }
    }

    private var sortOrder: Int {
        switch self {
        case .instant: 0
        case .fast: 1
        case .medium: 2
        case .slow: 3
        }
    }

    public static func < (lhs: ModelLatencyTier, rhs: ModelLatencyTier) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

/// Service kind distinguishing Speech-to-Text from Language Models.
public enum CloudServiceKind: String, Codable, CaseIterable, Sendable {
    case transcription
    case cleanup
}

/// A specific model option offered by a cloud or local server provider.
public struct CloudModelOption: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let summary: String
    public let latencyTier: ModelLatencyTier
    public let estimatedLatencyMs: Int?
    public let isRecommended: Bool
    public let tags: [String]

    public init(
        id: String,
        displayName: String,
        summary: String,
        latencyTier: ModelLatencyTier = .medium,
        estimatedLatencyMs: Int? = nil,
        isRecommended: Bool = false,
        tags: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.latencyTier = latencyTier
        self.estimatedLatencyMs = estimatedLatencyMs
        self.isRecommended = isRecommended
        self.tags = tags
    }

    public var speedBadge: String {
        if let latency = estimatedLatencyMs {
            if latency <= 180 {
                return "⚡ Instant (\(latency)ms)"
            } else if latency <= 450 {
                return "⚡ Fast (\(latency)ms)"
            } else if tags.contains(where: { $0.contains("Reasoning") }) {
                return "🧠 Reasoning (\(latency)ms)"
            } else {
                return "🎯 Accurate (\(latency)ms)"
            }
        }
        return latencyTier.badgeText
    }

    public var isFast: Bool {
        latencyTier == .instant || latencyTier == .fast
    }

    public var isAccurate: Bool {
        tags.contains(where: { $0.contains("Accurate") || $0.contains("Quality") || $0.contains("Flagship") }) || latencyTier == .medium
    }
}

/// A provider offering cloud STT and/or LLM cleanup services.
public struct CloudProvider: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let defaultBaseURL: String
    public let apiKeyURL: URL?
    public let keychainServiceIdentifier: String
    public let supportedKinds: Set<CloudServiceKind>
    public let transcriptionModels: [CloudModelOption]
    public let cleanupModels: [CloudModelOption]

    public init(
        id: String,
        displayName: String,
        defaultBaseURL: String,
        apiKeyURL: URL?,
        keychainServiceIdentifier: String,
        supportedKinds: Set<CloudServiceKind>,
        transcriptionModels: [CloudModelOption],
        cleanupModels: [CloudModelOption]
    ) {
        self.id = id
        self.displayName = displayName
        self.defaultBaseURL = defaultBaseURL
        self.apiKeyURL = apiKeyURL
        self.keychainServiceIdentifier = keychainServiceIdentifier
        self.supportedKinds = supportedKinds
        self.transcriptionModels = transcriptionModels
        self.cleanupModels = cleanupModels
    }

    public var supportsTranscription: Bool {
        supportedKinds.contains(.transcription)
    }

    public var supportsCleanup: Bool {
        supportedKinds.contains(.cleanup)
    }
}

/// Catalog of pre-configured cloud providers for Speech-to-Text and LLM cleanup.
public enum CloudProviderCatalog {
    public static let saysoCloud = CloudProvider(
        id: "sayso",
        displayName: "Sayso Cloud",
        defaultBaseURL: "https://api.sayso.ai/v1",
        apiKeyURL: URL(string: "https://sayso.ai/account/api-keys"),
        keychainServiceIdentifier: "sayso-api-key",
        supportedKinds: [.transcription, .cleanup],
        transcriptionModels: [
            CloudModelOption(
                id: "sayso-whisper-v3-turbo",
                displayName: "Sayso Whisper v3 Turbo",
                summary: "Optimized multilingual cloud dictation. Fast and accurate.",
                latencyTier: .fast,
                estimatedLatencyMs: 250,
                isRecommended: true,
                tags: ["⚡ Fast", "Multilingual"]
            ),
            CloudModelOption(
                id: "sayso-whisper-v3",
                displayName: "Sayso Whisper v3",
                summary: "Full Whisper model for maximum accuracy with background noise.",
                latencyTier: .medium,
                estimatedLatencyMs: 600,
                isRecommended: false,
                tags: ["Accurate", "Multilingual"]
            )
        ],
        cleanupModels: [
            CloudModelOption(
                id: "sayso-clean-v1",
                displayName: "Sayso Clean v1",
                summary: "Low-latency smart dictation cleanup, punctuation, and formatting.",
                latencyTier: .fast,
                estimatedLatencyMs: 280,
                isRecommended: true,
                tags: ["⚡ Fast", "Formatting"]
            )
        ]
    )

    public static let groq = CloudProvider(
        id: "groq",
        displayName: "Groq Cloud",
        defaultBaseURL: "https://api.groq.com/openai/v1",
        apiKeyURL: URL(string: "https://console.groq.com/keys"),
        keychainServiceIdentifier: "groq-api-key",
        supportedKinds: [.transcription, .cleanup],
        transcriptionModels: [
            CloudModelOption(
                id: "distil-whisper-large-v3-en",
                displayName: "Distil-Whisper Large v3 (English)",
                summary: "Ultra-fast English transcription powered by Groq LPUs.",
                latencyTier: .instant,
                estimatedLatencyMs: 140,
                isRecommended: true,
                tags: ["⚡ Instant", "English"]
            ),
            CloudModelOption(
                id: "whisper-large-v3-turbo",
                displayName: "Whisper Large v3 Turbo",
                summary: "Lightning-fast multilingual transcription.",
                latencyTier: .fast,
                estimatedLatencyMs: 220,
                isRecommended: false,
                tags: ["⚡ Fast", "Multilingual"]
            ),
            CloudModelOption(
                id: "whisper-large-v3",
                displayName: "Whisper Large v3",
                summary: "Full multilingual Whisper transcription on Groq hardware.",
                latencyTier: .fast,
                estimatedLatencyMs: 350,
                isRecommended: false,
                tags: ["🎯 Accurate", "Multilingual", "High Fidelity"]
            )
        ],
        cleanupModels: [
            CloudModelOption(
                id: "llama-3.1-8b-instant",
                displayName: "Llama 3.1 8B Instant",
                summary: "Ultra-fast text cleanup, filler removal, and formatting.",
                latencyTier: .instant,
                estimatedLatencyMs: 110,
                isRecommended: true,
                tags: ["⚡ Instant", "Cheap"]
            ),
            CloudModelOption(
                id: "llama-3.3-70b-versatile",
                displayName: "Llama 3.3 70B Versatile",
                summary: "High reasoning cleanup, tone refinement, and structured summaries.",
                latencyTier: .fast,
                estimatedLatencyMs: 260,
                isRecommended: false,
                tags: ["⚡ Fast", "Quality"]
            ),
            CloudModelOption(
                id: "mixtral-8x7b-32768",
                displayName: "Mixtral 8x7B",
                summary: "MoE model with 32k context for long transcript formatting.",
                latencyTier: .fast,
                estimatedLatencyMs: 320,
                isRecommended: false,
                tags: ["Fast", "Long Context"]
            )
        ]
    )

    public static let openAI = CloudProvider(
        id: "openai",
        displayName: "OpenAI",
        defaultBaseURL: "https://api.openai.com/v1",
        apiKeyURL: URL(string: "https://platform.openai.com/api-keys"),
        keychainServiceIdentifier: "openai-api-key",
        supportedKinds: [.transcription, .cleanup],
        transcriptionModels: [
            CloudModelOption(
                id: "gpt-4o-mini-transcribe",
                displayName: "GPT-4o Mini Transcribe",
                summary: "Fast multi-modal speech transcription by OpenAI.",
                latencyTier: .fast,
                estimatedLatencyMs: 380,
                isRecommended: true,
                tags: ["⚡ Fast", "Multimodal"]
            ),
            CloudModelOption(
                id: "whisper-1",
                displayName: "Whisper 1",
                summary: "Standard cloud Whisper transcription across 99+ languages.",
                latencyTier: .medium,
                estimatedLatencyMs: 750,
                isRecommended: false,
                tags: ["🎯 Accurate", "Standard", "99+ Languages"]
            )
        ],
        cleanupModels: [
            CloudModelOption(
                id: "gpt-4o-mini",
                displayName: "GPT-4o Mini",
                summary: "Fast, cost-effective grammar correction and dictation cleanup.",
                latencyTier: .fast,
                estimatedLatencyMs: 320,
                isRecommended: true,
                tags: ["⚡ Fast", "Cheap"]
            ),
            CloudModelOption(
                id: "gpt-4.1-mini",
                displayName: "GPT-4.1 Mini",
                summary: "Next-gen compact model for prompt editing and tone alignment.",
                latencyTier: .fast,
                estimatedLatencyMs: 340,
                isRecommended: false,
                tags: ["Fast", "Quality"]
            ),
            CloudModelOption(
                id: "gpt-4o",
                displayName: "GPT-4o",
                summary: "Flagship intelligence for complex multi-paragraph restructuring.",
                latencyTier: .medium,
                estimatedLatencyMs: 650,
                isRecommended: false,
                tags: ["🎯 Accurate", "Flagship", "Complex Edits"]
            )
        ]
    )

    public static let anthropic = CloudProvider(
        id: "anthropic",
        displayName: "Anthropic",
        defaultBaseURL: "https://api.anthropic.com/v1",
        apiKeyURL: URL(string: "https://console.anthropic.com/settings/keys"),
        keychainServiceIdentifier: "anthropic-api-key",
        supportedKinds: [.cleanup],
        transcriptionModels: [],
        cleanupModels: [
            CloudModelOption(
                id: "claude-3-5-haiku-latest",
                displayName: "Claude 3.5 Haiku",
                summary: "Fast, human-like voice editing and style adaptation.",
                latencyTier: .fast,
                estimatedLatencyMs: 290,
                isRecommended: true,
                tags: ["⚡ Fast", "Nuance"]
            ),
            CloudModelOption(
                id: "claude-3-5-sonnet-latest",
                displayName: "Claude 3.5 Sonnet",
                summary: "State-of-the-art prose formatting, logic preservation, and coding polish.",
                latencyTier: .medium,
                estimatedLatencyMs: 750,
                isRecommended: false,
                tags: ["🎯 Accurate", "Developer", "Nuance"]
            )
        ]
    )

    public static let deepseek = CloudProvider(
        id: "deepseek",
        displayName: "DeepSeek",
        defaultBaseURL: "https://api.deepseek.com/v1",
        apiKeyURL: URL(string: "https://platform.deepseek.com/api_keys"),
        keychainServiceIdentifier: "deepseek-api-key",
        supportedKinds: [.cleanup],
        transcriptionModels: [],
        cleanupModels: [
            CloudModelOption(
                id: "deepseek-chat",
                displayName: "DeepSeek V3 (Chat)",
                summary: "Ultra low cost, high capability speech formatting and rewriting.",
                latencyTier: .fast,
                estimatedLatencyMs: 350,
                isRecommended: true,
                tags: ["⚡ Fast", "Ultra Cheap"]
            ),
            CloudModelOption(
                id: "deepseek-reasoner",
                displayName: "DeepSeek R1 (Reasoner)",
                summary: "Chain-of-thought reasoning for complex technical dictation.",
                latencyTier: .slow,
                estimatedLatencyMs: 1200,
                isRecommended: false,
                tags: ["🧠 Reasoning", "Technical", "CoT"]
            )
        ]
    )

    public static let ollama = CloudProvider(
        id: "ollama",
        displayName: "Ollama (Local Server)",
        defaultBaseURL: "http://localhost:11434/v1",
        apiKeyURL: nil,
        keychainServiceIdentifier: "ollama-local",
        supportedKinds: [.cleanup],
        transcriptionModels: [],
        cleanupModels: [
            CloudModelOption(
                id: "qwen2.5:0.5b",
                displayName: "Qwen 2.5 0.5B (Ollama)",
                summary: "Ultra-fast local SLM running on local Ollama server.",
                latencyTier: .instant,
                estimatedLatencyMs: 150,
                isRecommended: true,
                tags: ["⚡ Instant", "Private"]
            ),
            CloudModelOption(
                id: "qwen2.5:1.5b",
                displayName: "Qwen 2.5 1.5B (Ollama)",
                summary: "Higher accuracy local rewriting via Ollama server.",
                latencyTier: .fast,
                estimatedLatencyMs: 300,
                isRecommended: false,
                tags: ["⚡ Fast", "Private"]
            ),
            CloudModelOption(
                id: "llama3.2:1b",
                displayName: "Llama 3.2 1B (Ollama)",
                summary: "Compact Meta model for on-device dictation polish.",
                latencyTier: .fast,
                estimatedLatencyMs: 250,
                isRecommended: false,
                tags: ["Fast", "Private"]
            )
        ]
    )

    public static let custom = CloudProvider(
        id: "custom",
        displayName: "Custom (OpenAI Compatible)",
        defaultBaseURL: "https://api.openai.com/v1",
        apiKeyURL: nil,
        keychainServiceIdentifier: "custom-provider-api-key",
        supportedKinds: [.transcription, .cleanup],
        transcriptionModels: [
            CloudModelOption(
                id: "custom-stt",
                displayName: "Custom STT Model",
                summary: "Enter any OpenAI-compatible transcription model identifier.",
                latencyTier: .medium,
                estimatedLatencyMs: nil,
                isRecommended: false,
                tags: ["Custom"]
            )
        ],
        cleanupModels: [
            CloudModelOption(
                id: "custom-llm",
                displayName: "Custom LLM Model",
                summary: "Enter any OpenAI-compatible chat completion model identifier.",
                latencyTier: .medium,
                estimatedLatencyMs: nil,
                isRecommended: false,
                tags: ["Custom"]
            )
        ]
    )

    /// All registered providers.
    public static let all: [CloudProvider] = [
        saysoCloud,
        groq,
        openAI,
        anthropic,
        deepseek,
        ollama,
        custom
    ]

    /// Providers supporting Speech-to-Text transcription.
    public static var transcriptionProviders: [CloudProvider] {
        all.filter(\.supportsTranscription)
    }

    /// Providers supporting LLM text cleanup and rewriting.
    public static var cleanupProviders: [CloudProvider] {
        all.filter(\.supportsCleanup)
    }

    /// Default recommended provider.
    public static var defaultProvider: CloudProvider {
        saysoCloud
    }

    /// Lookup provider by id or prefix (e.g. "groq" or "groq/distil-whisper").
    public static func provider(for id: String) -> CloudProvider? {
        let key = id.contains("/") ? String(id.split(separator: "/").first ?? "") : id
        return all.first { $0.id.lowercased() == key.lowercased() }
    }

    /// Alias for provider(for:).
    public static func findProvider(id: String) -> CloudProvider? {
        provider(for: id)
    }

    /// Find a transcription model by provider and model IDs.
    public static func transcriptionModel(providerId: String, modelId: String) -> CloudModelOption? {
        guard let p = provider(for: providerId) else { return nil }
        return p.transcriptionModels.first { $0.id.lowercased() == modelId.lowercased() }
    }

    /// Find a cleanup model by provider and model IDs.
    public static func cleanupModel(providerId: String, modelId: String) -> CloudModelOption? {
        guard let p = provider(for: providerId) else { return nil }
        return p.cleanupModels.first { $0.id.lowercased() == modelId.lowercased() }
    }
}
