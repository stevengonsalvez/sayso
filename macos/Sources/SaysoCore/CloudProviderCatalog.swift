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

    public var speedHint: String? {
        if let model = transcriptionModels.first(where: { $0.isRecommended }) ?? transcriptionModels.first,
           let ms = model.estimatedLatencyMs {
            return "⚡ ~\(ms)ms"
        }
        return nil
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

    public static let deepgram = CloudProvider(
        id: "deepgram",
        displayName: "Deepgram",
        defaultBaseURL: "https://api.deepgram.com/v1",
        apiKeyURL: URL(string: "https://console.deepgram.com"),
        keychainServiceIdentifier: "deepgram.apiKey",
        supportedKinds: [.transcription],
        transcriptionModels: [
            CloudModelOption(
                id: "deepgram/nova-3-streaming",
                displayName: "Deepgram Nova-3 (Streaming)",
                summary: "Real-time WebSocket streaming transcription with interim results.",
                latencyTier: .instant,
                estimatedLatencyMs: 200,
                isRecommended: true,
                tags: ["⚡ Instant", "Multilingual", "Interim Results"]
            ),
            CloudModelOption(
                id: "deepgram/flux-general-en-streaming",
                displayName: "Deepgram Flux (English Streaming)",
                summary: "Conversational streaming model with integrated end-of-turn detection.",
                latencyTier: .fast,
                estimatedLatencyMs: 180,
                isRecommended: false,
                tags: ["⚡ Fast", "Conversational", "English"]
            ),
            CloudModelOption(
                id: "deepgram/flux-general-multi-streaming",
                displayName: "Deepgram Flux (Multilingual Streaming)",
                summary: "Flux conversational streaming with multilingual detection and language hints.",
                latencyTier: .fast,
                estimatedLatencyMs: 220,
                isRecommended: false,
                tags: ["⚡ Fast", "Conversational", "Multilingual"]
            ),
            CloudModelOption(
                id: "deepgram/nova-3",
                displayName: "Deepgram Nova-3 (Batch)",
                summary: "High-accuracy batch file transcription with word timestamps and diarization.",
                latencyTier: .fast,
                estimatedLatencyMs: 500,
                isRecommended: false,
                tags: ["⚡ Fast", "High Accuracy", "Batch"]
            ),
            CloudModelOption(
                id: "deepgram/nova",
                displayName: "Deepgram Nova",
                summary: "Previous generation model. Fast and reliable.",
                latencyTier: .fast,
                estimatedLatencyMs: 400,
                isRecommended: false,
                tags: ["Fast", "Reliable"]
            ),
            CloudModelOption(
                id: "deepgram/enhanced",
                displayName: "Deepgram Enhanced",
                summary: "Optimized for specialized audio like phone calls and meetings.",
                latencyTier: .medium,
                estimatedLatencyMs: 600,
                isRecommended: false,
                tags: ["Standard", "Meetings"]
            ),
            CloudModelOption(
                id: "deepgram/base",
                displayName: "Deepgram Base",
                summary: "Base model with standard balance of speed and accuracy.",
                latencyTier: .medium,
                estimatedLatencyMs: 550,
                isRecommended: false,
                tags: ["Standard"]
            )
        ],
        cleanupModels: []
    )

    public static let assemblyAI = CloudProvider(
        id: "assemblyai",
        displayName: "AssemblyAI",
        defaultBaseURL: "https://api.assemblyai.com/v2",
        apiKeyURL: URL(string: "https://www.assemblyai.com/app/account"),
        keychainServiceIdentifier: "assemblyai.apiKey",
        supportedKinds: [.transcription],
        transcriptionModels: [
            CloudModelOption(
                id: "assemblyai/universal-3.5-pro-streaming",
                displayName: "AssemblyAI Universal-3.5 Pro (Streaming)",
                summary: "AssemblyAI flagship real-time model with native code switching across 18 languages.",
                latencyTier: .fast,
                estimatedLatencyMs: 250,
                isRecommended: true,
                tags: ["⚡ Fast", "Code Switching", "18 Languages"]
            ),
            CloudModelOption(
                id: "assemblyai/universal-3.5-pro",
                displayName: "AssemblyAI Universal-3.5 Pro (Batch)",
                summary: "AssemblyAI fastest, highest-accuracy batch model with 18-language code switching.",
                latencyTier: .medium,
                estimatedLatencyMs: 1500,
                isRecommended: false,
                tags: ["🎯 Accurate", "Batch", "Flagship"]
            ),
            CloudModelOption(
                id: "assemblyai/universal-2",
                displayName: "AssemblyAI Universal-2 (Batch)",
                summary: "Fast and reliable batch transcription from AssemblyAI.",
                latencyTier: .medium,
                estimatedLatencyMs: 1200,
                isRecommended: false,
                tags: ["Standard", "Reliable"]
            )
        ],
        cleanupModels: []
    )

    public static let elevenLabs = CloudProvider(
        id: "elevenlabs",
        displayName: "ElevenLabs",
        defaultBaseURL: "https://api.elevenlabs.io/v1",
        apiKeyURL: URL(string: "https://elevenlabs.io/app/settings/api-keys"),
        keychainServiceIdentifier: "elevenlabs.apiKey",
        supportedKinds: [.transcription],
        transcriptionModels: [
            CloudModelOption(
                id: "elevenlabs/scribe-v2-streaming",
                displayName: "ElevenLabs Scribe v2 (Streaming)",
                summary: "Real-time WebSocket transcription across 90+ languages.",
                latencyTier: .fast,
                estimatedLatencyMs: 200,
                isRecommended: true,
                tags: ["⚡ Fast", "90+ Languages"]
            ),
            CloudModelOption(
                id: "elevenlabs/scribe_v2",
                displayName: "ElevenLabs Scribe v2 (Batch)",
                summary: "High-accuracy speech-to-text with word-level timestamps across 90+ languages.",
                latencyTier: .fast,
                estimatedLatencyMs: 800,
                isRecommended: false,
                tags: ["🎯 Accurate", "Word Timestamps"]
            )
        ],
        cleanupModels: []
    )

    public static let cartesia = CloudProvider(
        id: "cartesia",
        displayName: "Cartesia",
        defaultBaseURL: "https://api.cartesia.ai",
        apiKeyURL: URL(string: "https://play.cartesia.ai/keys"),
        keychainServiceIdentifier: "cartesia.apiKey",
        supportedKinds: [.transcription],
        transcriptionModels: [
            CloudModelOption(
                id: "cartesia/ink-2-streaming",
                displayName: "Cartesia Ink-2 (Streaming)",
                summary: "English real-time STT with built-in turn detection and structured-data accuracy.",
                latencyTier: .instant,
                estimatedLatencyMs: 180,
                isRecommended: true,
                tags: ["⚡ Instant", "Turn Detection"]
            ),
            CloudModelOption(
                id: "cartesia/ink-whisper",
                displayName: "Cartesia Ink Whisper (Batch)",
                summary: "Multilingual file transcription with automatic language selection.",
                latencyTier: .medium,
                estimatedLatencyMs: 650,
                isRecommended: false,
                tags: ["Multilingual", "Accurate"]
            )
        ],
        cleanupModels: []
    )

    public static let gladia = CloudProvider(
        id: "gladia",
        displayName: "Gladia",
        defaultBaseURL: "https://api.gladia.io/v2",
        apiKeyURL: URL(string: "https://app.gladia.io/account"),
        keychainServiceIdentifier: "gladia.apiKey",
        supportedKinds: [.transcription],
        transcriptionModels: [
            CloudModelOption(
                id: "gladia/solaria-1-streaming",
                displayName: "Gladia Solaria-1 (Streaming)",
                summary: "Real-time multilingual STT with automatic language detection and partial transcripts.",
                latencyTier: .fast,
                estimatedLatencyMs: 220,
                isRecommended: true,
                tags: ["⚡ Fast", "Auto Language"]
            ),
            CloudModelOption(
                id: "gladia/solaria-1",
                displayName: "Gladia Solaria-1 (Batch)",
                summary: "Multilingual file transcription with per-utterance timings and code switching.",
                latencyTier: .medium,
                estimatedLatencyMs: 750,
                isRecommended: false,
                tags: ["Utterance Timings", "Code Switching"]
            )
        ],
        cleanupModels: []
    )

    public static let speechmatics = CloudProvider(
        id: "speechmatics",
        displayName: "Speechmatics",
        defaultBaseURL: "https://asr.api.speechmatics.com/v2",
        apiKeyURL: URL(string: "https://portal.speechmatics.com/manage-access-keys"),
        keychainServiceIdentifier: "speechmatics.apiKey",
        supportedKinds: [.transcription],
        transcriptionModels: [
            CloudModelOption(
                id: "speechmatics/enhanced-streaming",
                displayName: "Speechmatics Enhanced (Streaming)",
                summary: "Realtime WebSocket transcription with partial and final results.",
                latencyTier: .fast,
                estimatedLatencyMs: 220,
                isRecommended: true,
                tags: ["⚡ Fast", "High Accuracy"]
            ),
            CloudModelOption(
                id: "speechmatics/enhanced",
                displayName: "Speechmatics Enhanced (Batch)",
                summary: "Higher-accuracy file transcription tier with word timings and language ID.",
                latencyTier: .medium,
                estimatedLatencyMs: 900,
                isRecommended: false,
                tags: ["🎯 Accurate", "Word Timestamps"]
            ),
            CloudModelOption(
                id: "speechmatics/standard",
                displayName: "Speechmatics Standard (Batch)",
                summary: "Faster, lower-cost file transcription tier.",
                latencyTier: .fast,
                estimatedLatencyMs: 600,
                isRecommended: false,
                tags: ["Fast", "Economical"]
            )
        ],
        cleanupModels: []
    )

    public static let soniox = CloudProvider(
        id: "soniox",
        displayName: "Soniox",
        defaultBaseURL: "https://api.soniox.com/v1",
        apiKeyURL: URL(string: "https://soniox.com"),
        keychainServiceIdentifier: "soniox.apiKey",
        supportedKinds: [.transcription],
        transcriptionModels: [
            CloudModelOption(
                id: "soniox/stt-rt-v5-streaming",
                displayName: "Soniox Real-time v5 (Streaming)",
                summary: "Soniox v5 real-time STT with speaker separation and multilingual recognition across 60+ languages.",
                latencyTier: .fast,
                estimatedLatencyMs: 220,
                isRecommended: true,
                tags: ["⚡ Fast", "Speaker Separation", "60+ Languages"]
            ),
            CloudModelOption(
                id: "soniox/stt-async-v5",
                displayName: "Soniox Async v5 (Batch)",
                summary: "Soniox v5 async batch STT with speaker diarization and language identification.",
                latencyTier: .medium,
                estimatedLatencyMs: 1200,
                isRecommended: false,
                tags: ["Speaker Diarization", "Accurate"]
            )
        ],
        cleanupModels: []
    )

    public static let mistral = CloudProvider(
        id: "mistral",
        displayName: "Mistral AI",
        defaultBaseURL: "https://api.mistral.ai/v1",
        apiKeyURL: URL(string: "https://console.mistral.ai/api-keys"),
        keychainServiceIdentifier: "mistral.apiKey",
        supportedKinds: [.transcription, .cleanup],
        transcriptionModels: [
            CloudModelOption(
                id: "mistral/voxtral-realtime",
                displayName: "Mistral Voxtral Realtime (Streaming)",
                summary: "Natively streaming Voxtral model across 13 languages with automatic language detection.",
                latencyTier: .fast,
                estimatedLatencyMs: 480,
                isRecommended: true,
                tags: ["⚡ Fast", "13 Languages", "Auto Language"]
            ),
            CloudModelOption(
                id: "mistral/voxtral-mini-latest",
                displayName: "Voxtral Mini Latest (Batch)",
                summary: "Mistral Voxtral Mini batch transcription for long-form multilingual audio.",
                latencyTier: .fast,
                estimatedLatencyMs: 900,
                isRecommended: false,
                tags: ["Long-form", "Multilingual"]
            )
        ],
        cleanupModels: [
            CloudModelOption(
                id: "mistral-small-latest",
                displayName: "Mistral Small",
                summary: "Fast and cost-effective text cleanup.",
                latencyTier: .fast,
                estimatedLatencyMs: 250,
                isRecommended: true,
                tags: ["⚡ Fast", "Cost-effective"]
            )
        ]
    )

    public static let google = CloudProvider(
        id: "google",
        displayName: "Google Gemini",
        defaultBaseURL: "https://generativelanguage.googleapis.com/v1beta",
        apiKeyURL: URL(string: "https://aistudio.google.com/app/apikey"),
        keychainServiceIdentifier: "gemini.apiKey",
        supportedKinds: [.transcription, .cleanup],
        transcriptionModels: [
            CloudModelOption(
                id: "google/gemini-3.5-transcribe-live",
                displayName: "Gemini 3.5 Transcribe Live (Preview)",
                summary: "Real-time Gemini Live API transcription across 85+ languages with auto language detection.",
                latencyTier: .fast,
                estimatedLatencyMs: 200,
                isRecommended: true,
                tags: ["⚡ Fast", "85+ Languages", "Google"]
            ),
            CloudModelOption(
                id: "google/gemini-2.0-flash-001",
                displayName: "Gemini 2.0 Flash (Batch)",
                summary: "Fast multimodal model with strong shorthand transcription.",
                latencyTier: .fast,
                estimatedLatencyMs: 600,
                isRecommended: false,
                tags: ["⚡ Fast", "Multimodal"]
            ),
            CloudModelOption(
                id: "google/gemini-2.0-flash-lite-001",
                displayName: "Gemini 2.0 Flash Lite (Batch)",
                summary: "Low-latency, budget-friendly multimodal option.",
                latencyTier: .fast,
                estimatedLatencyMs: 400,
                isRecommended: false,
                tags: ["⚡ Fast", "Budget"]
            )
        ],
        cleanupModels: [
            CloudModelOption(
                id: "gemini-2.0-flash",
                displayName: "Gemini 2.0 Flash",
                summary: "High-speed multimodal cleanup and summarization.",
                latencyTier: .fast,
                estimatedLatencyMs: 200,
                isRecommended: true,
                tags: ["⚡ Fast", "Multimodal"]
            )
        ]
    )

    public static let xai = CloudProvider(
        id: "xai",
        displayName: "xAI",
        defaultBaseURL: "https://api.x.ai/v1",
        apiKeyURL: URL(string: "https://console.x.ai"),
        keychainServiceIdentifier: "xai.apiKey",
        supportedKinds: [.transcription, .cleanup],
        transcriptionModels: [
            CloudModelOption(
                id: "xai/think-fast-2-voice-streaming",
                displayName: "Grok Voice Think Fast 2.0 (Streaming)",
                summary: "xAI flagship realtime voice model used in transcription-only mode with live captions.",
                latencyTier: .fast,
                estimatedLatencyMs: 200,
                isRecommended: true,
                tags: ["⚡ Fast", "Flagship Voice"]
            ),
            CloudModelOption(
                id: "xai/stt-realtime",
                displayName: "xAI Speech-to-Text (Streaming)",
                summary: "Dedicated realtime speech-to-text with interim captions and authoritative final transcript.",
                latencyTier: .fast,
                estimatedLatencyMs: 200,
                isRecommended: false,
                tags: ["⚡ Fast", "Interim Captions"]
            ),
            CloudModelOption(
                id: "xai/stt-batch",
                displayName: "xAI Speech-to-Text (Batch)",
                summary: "Dedicated file transcription endpoint with word timings and keyterm biasing.",
                latencyTier: .fast,
                estimatedLatencyMs: 700,
                isRecommended: false,
                tags: ["Word Timings", "Biasing"]
            )
        ],
        cleanupModels: [
            CloudModelOption(
                id: "grok-2-latest",
                displayName: "Grok 2",
                summary: "High-intelligence text cleanup and tone editing.",
                latencyTier: .medium,
                estimatedLatencyMs: 400,
                isRecommended: true,
                tags: ["Quality"]
            )
        ]
    )

    public static let revai = CloudProvider(
        id: "revai",
        displayName: "Rev.ai",
        defaultBaseURL: "https://api.rev.ai/speechtotext/v1",
        apiKeyURL: URL(string: "https://www.rev.ai/access_token"),
        keychainServiceIdentifier: "revai.apiKey",
        supportedKinds: [.transcription],
        transcriptionModels: [
            CloudModelOption(
                id: "revai/reverb-streaming",
                displayName: "Rev.ai Reverb (Streaming)",
                summary: "Streaming speech-to-text on the Reverb model with per-segment finals.",
                latencyTier: .fast,
                estimatedLatencyMs: 300,
                isRecommended: true,
                tags: ["⚡ Fast", "Reverb Model"]
            ),
            CloudModelOption(
                id: "revai/default",
                displayName: "Rev.ai (Batch)",
                summary: "High-accuracy speech recognition with speaker identification.",
                latencyTier: .medium,
                estimatedLatencyMs: 1500,
                isRecommended: false,
                tags: ["Speaker Identification", "High Accuracy"]
            )
        ],
        cleanupModels: []
    )

    public static let modulate = CloudProvider(
        id: "modulate",
        displayName: "Modulate",
        defaultBaseURL: "https://api.modulate.ai/v1",
        apiKeyURL: URL(string: "https://modulate.ai"),
        keychainServiceIdentifier: "modulate.apiKey",
        supportedKinds: [.transcription],
        transcriptionModels: [
            CloudModelOption(
                id: "modulate/velma-2-stt-streaming",
                displayName: "Modulate Velma-2 (Streaming)",
                summary: "Real-time multilingual WebSocket transcription with diarization and signal detection.",
                latencyTier: .fast,
                estimatedLatencyMs: 220,
                isRecommended: true,
                tags: ["⚡ Fast", "Diarization"]
            ),
            CloudModelOption(
                id: "modulate/velma-2-stt-batch",
                displayName: "Modulate Velma-2 Batch",
                summary: "Multilingual batch transcription with diarization, emotion, and PII/PHI filtering.",
                latencyTier: .medium,
                estimatedLatencyMs: 1200,
                isRecommended: false,
                tags: ["Emotion", "PII/PHI Filter"]
            ),
            CloudModelOption(
                id: "modulate/velma-2-stt-batch-english-vfast",
                displayName: "Modulate Velma-2 Batch (English Fast)",
                summary: "High-throughput English batch transcription with automatic capitalization.",
                latencyTier: .fast,
                estimatedLatencyMs: 700,
                isRecommended: false,
                tags: ["High Throughput", "English"]
            )
        ],
        cleanupModels: []
    )

    public static let azure = CloudProvider(
        id: "azure",
        displayName: "Azure Speech",
        defaultBaseURL: "https://eastus.api.cognitive.microsoft.com",
        apiKeyURL: URL(string: "https://portal.azure.com"),
        keychainServiceIdentifier: "azure.speech.apiKey",
        supportedKinds: [.transcription],
        transcriptionModels: [
            CloudModelOption(
                id: "azure/realtime",
                displayName: "Azure Speech (Streaming)",
                summary: "Microsoft Azure cognitive services realtime speech recognition.",
                latencyTier: .fast,
                estimatedLatencyMs: 200,
                isRecommended: true,
                tags: ["⚡ Fast", "Microsoft Azure"]
            ),
            CloudModelOption(
                id: "azure/batch",
                displayName: "Azure Speech (Batch)",
                summary: "Microsoft Azure fast batch transcription API.",
                latencyTier: .medium,
                estimatedLatencyMs: 900,
                isRecommended: false,
                tags: ["Batch", "Microsoft Azure"]
            )
        ],
        cleanupModels: []
    )

    public static let meta = CloudProvider(
        id: "meta",
        displayName: "Meta Muse",
        defaultBaseURL: "https://api.metamodel.ai/v1",
        apiKeyURL: URL(string: "https://metamodel.ai"),
        keychainServiceIdentifier: "meta.apiKey",
        supportedKinds: [.transcription],
        transcriptionModels: [
            CloudModelOption(
                id: "meta/voice-transcribe-streaming",
                displayName: "Meta Muse Voice Transcribe (Streaming)",
                summary: "Meta Model API realtime speech-to-text with model-detected utterance boundaries.",
                latencyTier: .fast,
                estimatedLatencyMs: 200,
                isRecommended: true,
                tags: ["⚡ Fast", "Meta Model API"]
            ),
            CloudModelOption(
                id: "meta/voice-transcribe-batch",
                displayName: "Meta Muse Voice Transcribe (Batch)",
                summary: "Meta Model API file transcription with turn-level timestamps and vocabulary biasing.",
                latencyTier: .fast,
                estimatedLatencyMs: 800,
                isRecommended: false,
                tags: ["Turn Timestamps", "Vocabulary Biasing"]
            )
        ],
        cleanupModels: []
    )

    public static let openRouter = CloudProvider(
        id: "openrouter",
        displayName: "OpenRouter",
        defaultBaseURL: "https://openrouter.ai/api/v1",
        apiKeyURL: URL(string: "https://openrouter.ai/keys"),
        keychainServiceIdentifier: "openrouter.apiKey",
        supportedKinds: [.transcription, .cleanup],
        transcriptionModels: [
            CloudModelOption(
                id: "google/gemini-2.0-flash-001",
                displayName: "Gemini 2.0 Flash (OpenRouter)",
                summary: "Fast multimodal model with strong shorthand transcription routed via OpenRouter.",
                latencyTier: .fast,
                estimatedLatencyMs: 600,
                isRecommended: true,
                tags: ["⚡ Fast", "Multimodal"]
            ),
            CloudModelOption(
                id: "google/gemini-2.0-flash-lite-001",
                displayName: "Gemini 2.0 Flash Lite (OpenRouter)",
                summary: "Low-latency, budget-friendly multimodal option on OpenRouter.",
                latencyTier: .fast,
                estimatedLatencyMs: 400,
                isRecommended: false,
                tags: ["⚡ Fast", "Budget"]
            )
        ],
        cleanupModels: [
            CloudModelOption(
                id: "anthropic/claude-3.5-haiku",
                displayName: "Claude 3.5 Haiku (OpenRouter)",
                summary: "Fast text formatting and rewrite via OpenRouter.",
                latencyTier: .fast,
                estimatedLatencyMs: 300,
                isRecommended: true,
                tags: ["⚡ Fast"]
            )
        ]
    )

    /// All registered providers.
    public static let all: [CloudProvider] = [
        saysoCloud,
        deepgram,
        assemblyAI,
        groq,
        openAI,
        elevenLabs,
        cartesia,
        gladia,
        speechmatics,
        soniox,
        mistral,
        google,
        xai,
        revai,
        modulate,
        azure,
        meta,
        openRouter,
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
