import Foundation

public enum SaysoMode: String, Codable, CaseIterable, Sendable {
    case dictation
    case control
}

public enum SessionPhase: String, Codable, Sendable {
    case idle
    case requestingPermission
    case listening
    case processing
    case speaking
    case failed
}

public enum DictationLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case english = "en-GB"
    case hindi = "hi-IN"
    case tamil = "ta-IN"
    case malayalam = "ml-IN"
    case bengali = "bn-IN"
    case gujarati = "gu-IN"
    case kannada = "kn-IN"
    case marathi = "mr-IN"
    case punjabi = "pa-IN"
    case telugu = "te-IN"
    case urdu = "ur-IN"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .english: "English"
        case .hindi: "Hindi"
        case .tamil: "Tamil"
        case .malayalam: "Malayalam"
        case .bengali: "Bengali"
        case .gujarati: "Gujarati"
        case .kannada: "Kannada"
        case .marathi: "Marathi"
        case .punjabi: "Punjabi"
        case .telugu: "Telugu"
        case .urdu: "Urdu"
        }
    }

    public var localeIdentifier: String? {
        self == .automatic ? nil : rawValue
    }
}

public enum ProviderRoute: String, Codable, CaseIterable, Identifiable, Sendable {
    case local
    case appleSpeech
    case byok

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .local: "On-device"
        case .appleSpeech: "Apple Speech"
        case .byok: "Your provider"
        }
    }

    public var transmitsData: Bool { self != .local }
}

public struct Transcript: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var text: String
    public var translatedText: String?
    public var language: DictationLanguage
    public var route: ProviderRoute
    public var isFinal: Bool

    public init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        text: String,
        translatedText: String? = nil,
        language: DictationLanguage,
        route: ProviderRoute,
        isFinal: Bool
    ) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.translatedText = translatedText
        self.language = language
        self.route = route
        self.isFinal = isFinal
    }
}

public struct SaysoSettings: Codable, Equatable, Sendable {
    public var mode: SaysoMode = .dictation
    public var language: DictationLanguage = .automatic
    public var route: ProviderRoute = .local
    public var translationEnabled = false
    public var outputLanguage: DictationLanguage = .english
    public var autoInsert = true
    public var handsFree = false
    public var soundCues = true
    public var onboardingCompleted = false
    public var cloudConsentGranted = false
    public var desktopControlEnabled = false
    public var byokBaseURL = "https://api.openai.com/v1"
    public var byokTranslationModel = "gpt-4.1-mini"
    public var lexicon: [String: String] = [:]

    public init() {}
}

public enum LexiconCorrections {
    public static func apply(_ text: String, replacements: [String: String]) -> String {
        replacements.reduce(text) { result, replacement in
            result.replacingOccurrences(of: replacement.key, with: replacement.value, options: [.caseInsensitive])
        }
    }
}

public enum VoiceEdits {
    public static func apply(_ command: String, to transcript: String) -> String? {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = value.lowercased()
        if lower.hasPrefix("sayso replace "), let range = lower.range(of: " with ") {
            let source = String(value[value.index(value.startIndex, offsetBy: 14)..<range.lowerBound])
            let replacement = String(value[range.upperBound...])
            guard !source.isEmpty, !replacement.isEmpty else { return nil }
            return transcript.replacingOccurrences(of: source, with: replacement, options: [.caseInsensitive])
        }
        if lower.hasPrefix("sayso delete ") {
            let source = String(value.dropFirst(13)).trimmingCharacters(in: .whitespaces)
            guard !source.isEmpty else { return nil }
            return transcript.replacingOccurrences(of: source, with: "", options: [.caseInsensitive])
        }
        return nil
    }
}

public enum SaysoError: LocalizedError, Equatable, Sendable {
    case permissionDenied(String)
    case unavailable(String)
    case protectedTarget
    case staleTarget
    case invalidAction(String)

    public var errorDescription: String? {
        switch self {
        case let .permissionDenied(name): "Permission denied: \(name)"
        case let .unavailable(name): "Unavailable: \(name)"
        case .protectedTarget: "Sayso will not operate protected fields"
        case .staleTarget: "Target changed. Sayso did not act."
        case let .invalidAction(message): message
        }
    }
}
