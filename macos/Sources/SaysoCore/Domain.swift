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

public enum OnboardingReadiness {
    public static func engineIsReady(
        route: ProviderRoute,
        language: DictationLanguage,
        hasLocalModel: Bool,
        cloudConsentGranted: Bool
    ) -> Bool {
        switch route {
        case .local:
            language != .automatic && hasLocalModel
        case .appleSpeech:
            cloudConsentGranted
        case .byok:
            false
        }
    }

    public static func hasRequiredPermissions(
        route: ProviderRoute,
        microphoneGranted: Bool,
        speechRecognitionGranted: Bool
    ) -> Bool {
        microphoneGranted && (route != .appleSpeech || speechRecognitionGranted)
    }
}

public struct Transcript: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var text: String
    public var translatedText: String?
    public var language: DictationLanguage
    public var route: ProviderRoute
    public var isFinal: Bool
    public var audioFileURL: URL?

    public init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        text: String,
        translatedText: String? = nil,
        language: DictationLanguage,
        route: ProviderRoute,
        isFinal: Bool,
        audioFileURL: URL? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.translatedText = translatedText
        self.language = language
        self.route = route
        self.isFinal = isFinal
        self.audioFileURL = audioFileURL
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
    public var saveSessionAudio = false
    public var soundCues = true
    public var onboardingCompleted = false
    public var cloudConsentGranted = false
    public var voiceEditCloudConsent = false
    public var desktopControlEnabled = false
    public var byokBaseURL = "https://api.openai.com/v1"
    public var byokTranslationModel = "gpt-4.1-mini"
    public var byokRewriteModel = "gpt-4.1-mini"
    public var lexicon: [String: String] = [:]
    public var dictationProfile: DictationProfile = .default

    public init() {}

    public mutating func applyFirstRunDefaults() {
        guard !onboardingCompleted, language == .automatic else { return }
        language = .english
    }

    private enum CodingKeys: String, CodingKey {
        case mode, overlayPresentation, language, route, translationEnabled, outputLanguage
        case autoInsert, restoreClipboardAfterPaste, handsFree, saveSessionAudio, soundCues, onboardingCompleted
        case cloudConsentGranted, voiceEditCloudConsent, desktopControlEnabled
        case byokBaseURL, byokTranslationModel, byokRewriteModel
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
        saveSessionAudio = decoded(Bool.self, .saveSessionAudio, fallback: saveSessionAudio)
        soundCues = decoded(Bool.self, .soundCues, fallback: soundCues)
        onboardingCompleted = decoded(Bool.self, .onboardingCompleted, fallback: onboardingCompleted)
        cloudConsentGranted = decoded(Bool.self, .cloudConsentGranted, fallback: cloudConsentGranted)
        voiceEditCloudConsent = decoded(Bool.self, .voiceEditCloudConsent, fallback: voiceEditCloudConsent)
        desktopControlEnabled = decoded(Bool.self, .desktopControlEnabled, fallback: desktopControlEnabled)
        byokBaseURL = decoded(String.self, .byokBaseURL, fallback: byokBaseURL)
        byokTranslationModel = decoded(String.self, .byokTranslationModel, fallback: byokTranslationModel)
        byokRewriteModel = decoded(String.self, .byokRewriteModel, fallback: byokRewriteModel)
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
    public enum Outcome: Equatable {
        case notCommand
        case targetNotFound
        case applied(String)
    }

    public static func outcome(_ command: String, to transcript: String) -> Outcome {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if let source = commandPart(after: "sayso replace ", in: value),
           let divider = source.range(of: " with ", options: .caseInsensitive) {
            let target = String(source[..<divider.lowerBound]).trimmingCharacters(in: .whitespaces)
            let replacement = String(source[divider.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty, !replacement.isEmpty else { return .notCommand }
            let matches = tokenMatches(of: target, in: transcript)
            guard !matches.isEmpty else { return .targetNotFound }
            return .applied(replacing(matches, in: transcript, with: replacement))
        }
        if let source = commandPart(after: "sayso delete ", in: value) {
            let target = source.trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { return .notCommand }
            let matches = tokenMatches(of: target, in: transcript)
            guard !matches.isEmpty else { return .targetNotFound }
            return .applied(deleting(matches, from: transcript))
        }
        return .notCommand
    }

    public static func apply(_ command: String, to transcript: String) -> String? {
        guard case let .applied(edited) = outcome(command, to: transcript) else { return nil }
        return edited
    }

    /// All case-insensitive whole-token occurrences of `target`, so "cat"
    /// never edits "concatenate".
    private static func tokenMatches(of target: String, in transcript: String) -> [Range<String.Index>] {
        var matches: [Range<String.Index>] = []
        var searchRange = transcript.startIndex ..< transcript.endIndex
        while let match = transcript.range(of: target, options: .caseInsensitive, range: searchRange) {
            let startsOnBoundary = match.lowerBound == transcript.startIndex
                || !isWordCharacter(transcript[transcript.index(before: match.lowerBound)])
            let endsOnBoundary = match.upperBound == transcript.endIndex
                || !isWordCharacter(transcript[match.upperBound])
            if startsOnBoundary, endsOnBoundary {
                matches.append(match)
                searchRange = match.upperBound ..< transcript.endIndex
            } else {
                searchRange = transcript.index(after: match.lowerBound) ..< transcript.endIndex
            }
        }
        return matches
    }

    private static func replacing(
        _ matches: [Range<String.Index>], in transcript: String, with replacement: String
    ) -> String {
        var result = ""
        var cursor = transcript.startIndex
        for match in matches {
            result += transcript[cursor..<match.lowerBound]
            result += replacement
            cursor = match.upperBound
        }
        result += transcript[cursor...]
        return result
    }

    /// Removes matches and one adjoining space at each deletion seam, preserving all other spacing.
    private static func deleting(_ matches: [Range<String.Index>], from transcript: String) -> String {
        var result = ""
        var cursor = transcript.startIndex
        for range in deletionRanges(for: matches, in: transcript) {
            if cursor < range.lowerBound { result += transcript[cursor..<range.lowerBound] }
            if cursor < range.upperBound { cursor = range.upperBound }
        }
        result += transcript[cursor...]
        return result
    }

    private static func deletionRanges(
        for matches: [Range<String.Index>], in transcript: String
    ) -> [Range<String.Index>] {
        guard var cluster = matches.first else { return [] }
        var ranges: [Range<String.Index>] = []
        for match in matches.dropFirst() {
            let gap = transcript[cluster.upperBound..<match.lowerBound]
            if !gap.isEmpty, gap.allSatisfy({ $0 == " " }) {
                cluster = cluster.lowerBound ..< match.upperBound
            } else {
                ranges.append(deletionRange(for: cluster, in: transcript))
                cluster = match
            }
        }
        ranges.append(deletionRange(for: cluster, in: transcript))
        return ranges
    }

    private static func deletionRange(for match: Range<String.Index>, in transcript: String) -> Range<String.Index> {
        var range = match
        if range.upperBound < transcript.endIndex, transcript[range.upperBound] == " ",
           range.lowerBound == transcript.startIndex || transcript[transcript.index(before: range.lowerBound)] == " " {
            range = range.lowerBound ..< transcript.index(after: range.upperBound)
        } else if range.lowerBound > transcript.startIndex, transcript[transcript.index(before: range.lowerBound)] == " " {
            range = transcript.index(before: range.lowerBound) ..< range.upperBound
        }
        return range
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "'" || character == "’"
    }

    private static func commandPart(after prefix: String, in value: String) -> Substring? {
        guard let range = value.range(of: prefix, options: [.anchored, .caseInsensitive]) else { return nil }
        return value[range.upperBound...]
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
