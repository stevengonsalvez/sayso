import Foundation

public enum SaysoMode: String, Codable, CaseIterable, Sendable {
    case dictation
    case control
}

public enum OverlayPresentation: String, Codable, CaseIterable, Identifiable, Sendable {
    case notch
    case floating

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .notch: "Notch"
        case .floating: "Floating"
        }
    }
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

    public var supportsDictation: Bool { self != .byok }

    public static var dictationRoutes: [ProviderRoute] { [.local, .appleSpeech] }
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
    public var overlayPresentation: OverlayPresentation = .notch
    public var language: DictationLanguage = .english
    public var route: ProviderRoute = .local
    public var translationEnabled = false
    public var outputLanguage: DictationLanguage = .english
    public var autoInsert = true
    public var restoreClipboardAfterPaste = true
    public var handsFree = false
    public var soundCues = true
    public var onboardingCompleted = false
    public var cloudConsentGranted = false
    public var desktopControlEnabled = false
    public var byokBaseURL = "https://api.openai.com/v1"
    public var byokTranslationModel = "gpt-4.1-mini"
    public var lexicon: [String: String] = [:]
    public var dictationProfile: DictationProfile = .default

    public init() {}

    public mutating func applyFirstRunDefaults() {
        guard !onboardingCompleted, language == .automatic else { return }
        language = .english
    }

    private enum CodingKeys: String, CodingKey {
        case mode, overlayPresentation, language, route, translationEnabled, outputLanguage
        case autoInsert, restoreClipboardAfterPaste, handsFree, soundCues, onboardingCompleted
        case cloudConsentGranted, desktopControlEnabled, byokBaseURL, byokTranslationModel
        case lexicon, dictationProfile
    }

    public init(from decoder: any Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func decoded<Value: Decodable>(_ type: Value.Type, _ key: CodingKeys, fallback: Value) -> Value {
            (try? values.decodeIfPresent(type, forKey: key)) ?? fallback
        }
        mode = decoded(SaysoMode.self, .mode, fallback: mode)
        overlayPresentation = decoded(OverlayPresentation.self, .overlayPresentation, fallback: overlayPresentation)
        language = decoded(DictationLanguage.self, .language, fallback: language)
        route = decoded(ProviderRoute.self, .route, fallback: route)
        translationEnabled = decoded(Bool.self, .translationEnabled, fallback: translationEnabled)
        outputLanguage = decoded(DictationLanguage.self, .outputLanguage, fallback: outputLanguage)
        autoInsert = decoded(Bool.self, .autoInsert, fallback: autoInsert)
        restoreClipboardAfterPaste = decoded(Bool.self, .restoreClipboardAfterPaste, fallback: restoreClipboardAfterPaste)
        handsFree = decoded(Bool.self, .handsFree, fallback: handsFree)
        soundCues = decoded(Bool.self, .soundCues, fallback: soundCues)
        onboardingCompleted = decoded(Bool.self, .onboardingCompleted, fallback: onboardingCompleted)
        cloudConsentGranted = decoded(Bool.self, .cloudConsentGranted, fallback: cloudConsentGranted)
        desktopControlEnabled = decoded(Bool.self, .desktopControlEnabled, fallback: desktopControlEnabled)
        byokBaseURL = decoded(String.self, .byokBaseURL, fallback: byokBaseURL)
        byokTranslationModel = decoded(String.self, .byokTranslationModel, fallback: byokTranslationModel)
        lexicon = decoded([String: String].self, .lexicon, fallback: lexicon)
        dictationProfile = decoded(DictationProfile.self, .dictationProfile, fallback: dictationProfile)
    }
}

public enum LexiconCorrections {
    public static func apply(_ text: String, replacements: [String: String]) -> String {
        let corrections = replacements
            .sorted {
                $0.key.count == $1.key.count
                    ? $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
                    : $0.key.count > $1.key.count
            }
            .map { DictationCorrection(source: $0.key, replacement: $0.value) }
        return DictationProfile(name: "Lexicon", corrections: corrections).postProcess(text)
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
