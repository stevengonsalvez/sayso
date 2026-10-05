import Foundation
@preconcurrency import AVFoundation

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

public enum DictationHotKeyActivation: String, Codable, CaseIterable, Identifiable, Sendable {
    case tapToToggle
    case pressAndHold
    case both

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .tapToToggle: "Tap to toggle"
        case .pressAndHold: "Press and hold"
        case .both: "Tap and hold"
        }
    }

    public var usesTapToggle: Bool { self != .pressAndHold }
    public var usesPressAndHold: Bool { self != .tapToToggle }
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

    public var languageCode: String {
        switch self {
        case .hindi: "hi"
        case .tamil: "ta"
        case .malayalam: "ml"
        case .bengali: "bn"
        case .gujarati: "gu"
        case .kannada: "kn"
        case .marathi: "mr"
        case .punjabi: "pa"
        case .telugu: "te"
        case .urdu: "ur"
        case .english: "en"
        case .automatic: "auto"
        }
    }

    public var isIndic: Bool {
        switch self {
        case .hindi, .tamil, .malayalam, .bengali, .gujarati, .kannada, .marathi, .punjabi, .telugu, .urdu:
            true
        default:
            false
        }
    }

    public var transliterationTarget: String {
        switch self {
        case .hindi: "Hinglish"
        case .malayalam: "Manglish"
        case .tamil: "Tanglish"
        default: "Tanglish / Hinglish"
        }
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

    public var supportsDictation: Bool { true }

    public static var dictationRoutes: [ProviderRoute] { [.local, .appleSpeech, .byok] }
}

public enum OnboardingReadiness {
    public static func engineIsReady(
        route: ProviderRoute,
        language: DictationLanguage,
        hasLocalModel: Bool,
        routeConsentGranted: Bool,
        byokConfigured: Bool = false
    ) -> Bool {
        switch route {
        case .local:
            language != .automatic && hasLocalModel
        case .appleSpeech:
            routeConsentGranted
        case .byok:
            routeConsentGranted && byokConfigured
        }
    }

    public static func hasRequiredPermissions(
        route: ProviderRoute,
        microphoneGranted: Bool,
        speechRecognitionGranted: Bool,
        requiresSpeechRecognition: Bool? = nil
    ) -> Bool {
        let needsSpeech = requiresSpeechRecognition ?? (route == .appleSpeech)
        return microphoneGranted && (!needsSpeech || speechRecognitionGranted)
    }

    public static func isBYOKConfigured(
        baseURLString: String,
        transcriptionModel: String,
        hasAPIKey: Bool
    ) -> Bool {
        guard hasAPIKey,
              SaysoSettings.normalizedBaseURL(baseURLString) != nil else {
            return false
        }
        return !transcriptionModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct Transcript: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var text: String
    public var translatedText: String?
    public var translatedLanguage: DictationLanguage?
    public var language: DictationLanguage
    public var route: ProviderRoute
    public var isFinal: Bool
    public var audioFileURL: URL?
    public var duration: Double?

    public var effectiveDuration: Double? {
        if let duration, duration > 0 {
            return duration
        }
        if let audioFileURL,
           let file = try? AVAudioFile(forReading: audioFileURL),
           file.processingFormat.sampleRate > 0 {
            let fileDuration = Double(file.length) / file.processingFormat.sampleRate
            return fileDuration > 0 ? fileDuration : nil
        }
        return nil
    }

    public var hasTranslation: Bool {
        !(translatedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var displayText: String {
        hasTranslation ? translatedText! : text
    }

    public func spokenLanguage(outputLanguage: DictationLanguage) -> DictationLanguage {
        hasTranslation ? (translatedLanguage ?? outputLanguage) : language
    }

    public init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        text: String,
        translatedText: String? = nil,
        translatedLanguage: DictationLanguage? = nil,
        language: DictationLanguage,
        route: ProviderRoute,
        isFinal: Bool,
        audioFileURL: URL? = nil,
        duration: Double? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.translatedText = translatedText
        self.translatedLanguage = translatedLanguage
        self.language = language
        self.route = route
        self.isFinal = isFinal
        self.audioFileURL = audioFileURL
        self.duration = duration
    }
}

public enum TranscriptionExecutionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case streaming = "streaming"
    case batch = "batch"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .streaming: "Streaming"
        case .batch: "Batch"
        }
    }

    public var description: String {
        switch self {
        case .streaming: "Transcribes live as you speak. Instant feedback in notch."
        case .batch: "Transcribes finished audio in one pass on stop. Highest accuracy and punctuation."
        }
    }
}

public struct SaysoSettings: Codable, Equatable, Sendable {
    public var mode: SaysoMode = .dictation
    public var overlayPresentation: OverlayPresentation = .notch
    public var language: DictationLanguage = .english
    public var route: ProviderRoute = .local
    public var transcriptionExecutionMode: TranscriptionExecutionMode = .streaming
    public var translationEnabled = false
    public var outputLanguage: DictationLanguage = .english
    public var speechLanguage: DictationLanguage = .english
    public var speechVoiceIdentifier: String?
    public var speechRate: Double = 0.5
    public var autoInsert = true
    public var livePartialInsertion = false
    public var restoreClipboardAfterPaste = true
    public var handsFree = false
    public var handsFreeContinuous = false
    public var handsFreeSilenceSeconds = 1.2
    public var handsFreeMaximumDurationSeconds = 900.0
    public var handsFreeMaximumSessionDurationSeconds = 900.0
    public var hotKeyActivation: DictationHotKeyActivation = .tapToToggle
    public var hotKeyHoldThresholdSeconds = 0.35
    public var preferredAudioInputUID: AudioInputDeviceUID?
    public var saveSessionAudio = false
    public var soundCues = true
    public var onboardingCompleted = false
    public var cloudConsentGranted = false
    public var byokConsentGranted = false
    public var voiceEditCloudConsent = false
    public var desktopControlEnabled = false
    /// Opt-in: the clipboard module polls the pasteboard while this is on.
    public var clipboardModuleEnabled = false
    /// Opt-in: the file shelf holds read access to files the user adds while this is on.
    public var fileShelfEnabled = false
    /// Opt-in: Now Playing asks an already running Music or Spotify for its track while this is on.
    public var nowPlayingEnabled = false
    /// On unless turned off: system stats only read counters on this Mac and were always on before this setting.
    public var systemStatsEnabled = true
    /// On unless turned off: the calculator evaluates only what the user types into it and reads nothing else.
    public var calculatorEnabled = true
    public var byokBaseURL = "https://api.openai.com/v1"
    public var byokTranscriptionModel = "gpt-4o-mini-transcribe"
    public var byokTranslationModel = "gpt-4.1-mini"
    public var byokRewriteModel = "gpt-4.1-mini"
    public var cleanupEnabled = false
    public var cloudCleanupEnabled = false
    public var byokCleanupBaseURL = "https://api.groq.com/openai/v1"
    public var byokCleanupModel = "gpt-4.1-mini"
    public var lexicon: [String: String] = [:]
    public var legacyLexiconMigrated = false
    public var autoCorrectionsEnabled = false
    public var autoCorrectionsPromotionThreshold = 3
    public var dictationProfile: DictationProfile = .default
    public var dictationProfileOverrides: [DictationProfileBundleOverride] = []

    // Pre-processing pipeline settings
    public var hints: [String] = []
    public var autoLanguageRouting = false
    public var transliterateIndicToLatin = false
    public var silenceTimeoutSeconds: Double = 1.5
    public var maxRecordingSeconds: Double = 120.0
    public var audioDuckingEnabled = true

    // Post-processing pipeline settings
    public var cleanupMode: CleanupMode = .rules
    public var cleanupPreset: CleanupPreset = .standard
    public var customCleanupPrompt: String? = nil
    public var appContextAwarenessEnabled = true

    // Pronunciation & vocabulary dictionary
    public var pronunciations: [SaysoPronunciationEntry] = PronunciationDefaults.standard

    // Multi-provider and model selections
    public var selectedCloudProviderId = "groq"
    public var selectedCloudModelId = "distil-whisper-large-v3-en"
    public var selectedCloudCleanupProviderId = "groq"
    public var selectedCloudCleanupModelId = "llama-3.1-8b-instant"
    public var selectedLocalSlmModelId = "local-slm/qwen2.5-0.5b"
    public var selectedLocalAsrModelId = "sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8"

    public static func normalizedBaseURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ProviderEndpointPolicy.allows(url) else {
            return nil
        }
        return url
    }

    public var normalizedBYOKBaseURL: URL? {
        Self.normalizedBaseURL(byokBaseURL)
    }

    public var normalizedBYOKCleanupBaseURL: URL? {
        Self.normalizedBaseURL(byokCleanupBaseURL)
    }

    public func hasConsent(for route: ProviderRoute) -> Bool {
        switch route {
        case .local:
            return true
        case .appleSpeech:
            return cloudConsentGranted
        case .byok:
            return byokConsentGranted
        }
    }

    public init() {}

    public mutating func applyFirstRunDefaults() {
        guard !onboardingCompleted, language == .automatic else { return }
        language = .english
    }

    private enum CodingKeys: String, CodingKey {
        case mode, overlayPresentation, language, route, transcriptionExecutionMode, translationEnabled, outputLanguage, speechLanguage, speechVoiceIdentifier, speechRate
        case autoInsert, livePartialInsertion, restoreClipboardAfterPaste, handsFree, handsFreeContinuous, handsFreeSilenceSeconds, handsFreeMaximumDurationSeconds, handsFreeMaximumSessionDurationSeconds, hotKeyActivation, hotKeyHoldThresholdSeconds, preferredAudioInputUID, saveSessionAudio, soundCues, onboardingCompleted
        case cloudConsentGranted, byokConsentGranted, voiceEditCloudConsent, desktopControlEnabled, clipboardModuleEnabled, fileShelfEnabled, nowPlayingEnabled, systemStatsEnabled, calculatorEnabled
        case byokBaseURL, byokTranscriptionModel, byokTranslationModel, byokRewriteModel, cleanupEnabled, cloudCleanupEnabled, byokCleanupBaseURL, byokCleanupModel
        case lexicon, legacyLexiconMigrated, autoCorrectionsEnabled, autoCorrectionsPromotionThreshold
        case dictationProfile, dictationProfileOverrides
        case hints, autoLanguageRouting, transliterateIndicToLatin, silenceTimeoutSeconds, maxRecordingSeconds, audioDuckingEnabled
        case cleanupMode, cleanupPreset, customCleanupPrompt, appContextAwarenessEnabled, pronunciations
        case selectedCloudProviderId, selectedCloudModelId, selectedCloudCleanupProviderId, selectedCloudCleanupModelId
        case selectedLocalSlmModelId, selectedLocalAsrModelId
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
        transcriptionExecutionMode = decoded(TranscriptionExecutionMode.self, .transcriptionExecutionMode, fallback: transcriptionExecutionMode)
        translationEnabled = decoded(Bool.self, .translationEnabled, fallback: translationEnabled)
        outputLanguage = decoded(DictationLanguage.self, .outputLanguage, fallback: outputLanguage)
        let legacySpeechLanguage = outputLanguage == .automatic ? speechLanguage : outputLanguage
        speechLanguage = decoded(DictationLanguage.self, .speechLanguage, fallback: legacySpeechLanguage)
        if speechLanguage == .automatic { speechLanguage = .english }
        speechVoiceIdentifier = (try? values.decodeIfPresent(String.self, forKey: .speechVoiceIdentifier)) ?? speechVoiceIdentifier
        speechRate = min(max(decoded(Double.self, .speechRate, fallback: speechRate), SpeechPlan.rateRange.lowerBound), SpeechPlan.rateRange.upperBound)
        autoInsert = decoded(Bool.self, .autoInsert, fallback: autoInsert)
        livePartialInsertion = decoded(Bool.self, .livePartialInsertion, fallback: livePartialInsertion)
        restoreClipboardAfterPaste = decoded(Bool.self, .restoreClipboardAfterPaste, fallback: restoreClipboardAfterPaste)
        handsFree = decoded(Bool.self, .handsFree, fallback: handsFree)
        handsFreeContinuous = decoded(Bool.self, .handsFreeContinuous, fallback: handsFreeContinuous)
        handsFreeSilenceSeconds = min(
            max(decoded(Double.self, .handsFreeSilenceSeconds, fallback: handsFreeSilenceSeconds), 0.5),
            5
        )
        handsFreeMaximumDurationSeconds = min(
            max(decoded(Double.self, .handsFreeMaximumDurationSeconds, fallback: handsFreeMaximumDurationSeconds), 5),
            3_600
        )
        handsFreeMaximumSessionDurationSeconds = min(
            max(decoded(Double.self, .handsFreeMaximumSessionDurationSeconds, fallback: handsFreeMaximumSessionDurationSeconds), 30),
            3_600
        )
        hotKeyActivation = decoded(DictationHotKeyActivation.self, .hotKeyActivation, fallback: hotKeyActivation)
        hotKeyHoldThresholdSeconds = min(
            max(decoded(Double.self, .hotKeyHoldThresholdSeconds, fallback: hotKeyHoldThresholdSeconds), 0.2),
            1
        )
        preferredAudioInputUID = decoded(
            AudioInputDeviceUID?.self,
            .preferredAudioInputUID,
            fallback: preferredAudioInputUID
        )
        saveSessionAudio = decoded(Bool.self, .saveSessionAudio, fallback: saveSessionAudio)
        soundCues = decoded(Bool.self, .soundCues, fallback: soundCues)
        onboardingCompleted = decoded(Bool.self, .onboardingCompleted, fallback: onboardingCompleted)
        cloudConsentGranted = decoded(Bool.self, .cloudConsentGranted, fallback: cloudConsentGranted)
        // Legacy versions used cloudConsentGranted for all cloud features (Apple Speech and BYOK).
        // Carry forward cloudConsentGranted when byokConsentGranted is missing so upgrading users
        // do not lose existing BYOK dictation, translation, and cleanup without warning.
        byokConsentGranted = decoded(Bool.self, .byokConsentGranted, fallback: cloudConsentGranted)
        voiceEditCloudConsent = decoded(Bool.self, .voiceEditCloudConsent, fallback: voiceEditCloudConsent)
        desktopControlEnabled = decoded(Bool.self, .desktopControlEnabled, fallback: desktopControlEnabled)
        clipboardModuleEnabled = decoded(Bool.self, .clipboardModuleEnabled, fallback: clipboardModuleEnabled)
        fileShelfEnabled = decoded(Bool.self, .fileShelfEnabled, fallback: fileShelfEnabled)
        nowPlayingEnabled = decoded(Bool.self, .nowPlayingEnabled, fallback: nowPlayingEnabled)
        systemStatsEnabled = decoded(Bool.self, .systemStatsEnabled, fallback: systemStatsEnabled)
        calculatorEnabled = decoded(Bool.self, .calculatorEnabled, fallback: calculatorEnabled)
        byokBaseURL = decoded(String.self, .byokBaseURL, fallback: byokBaseURL)
        byokTranscriptionModel = decoded(String.self, .byokTranscriptionModel, fallback: byokTranscriptionModel)
        byokTranslationModel = decoded(String.self, .byokTranslationModel, fallback: byokTranslationModel)
        byokRewriteModel = decoded(String.self, .byokRewriteModel, fallback: byokRewriteModel)
        cleanupEnabled = decoded(Bool.self, .cleanupEnabled, fallback: cleanupEnabled)
        cloudCleanupEnabled = decoded(Bool.self, .cloudCleanupEnabled, fallback: cloudCleanupEnabled)
        byokCleanupBaseURL = decoded(String.self, .byokCleanupBaseURL, fallback: byokCleanupBaseURL)
        byokCleanupModel = decoded(String.self, .byokCleanupModel, fallback: byokCleanupModel)
        lexicon = decoded([String: String].self, .lexicon, fallback: lexicon)
        legacyLexiconMigrated = decoded(Bool.self, .legacyLexiconMigrated, fallback: legacyLexiconMigrated)
        autoCorrectionsEnabled = decoded(Bool.self, .autoCorrectionsEnabled, fallback: autoCorrectionsEnabled)
        autoCorrectionsPromotionThreshold = min(
            max(decoded(Int.self, .autoCorrectionsPromotionThreshold, fallback: autoCorrectionsPromotionThreshold), 2),
            10
        )
        dictationProfile = decoded(DictationProfile.self, .dictationProfile, fallback: dictationProfile)
        dictationProfileOverrides = decoded(
            [DictationProfileBundleOverride].self,
            .dictationProfileOverrides,
            fallback: dictationProfileOverrides
        )
        hints = decoded([String].self, .hints, fallback: hints)
        autoLanguageRouting = decoded(Bool.self, .autoLanguageRouting, fallback: autoLanguageRouting)
        transliterateIndicToLatin = decoded(Bool.self, .transliterateIndicToLatin, fallback: transliterateIndicToLatin)
        silenceTimeoutSeconds = min(max(decoded(Double.self, .silenceTimeoutSeconds, fallback: silenceTimeoutSeconds), 0.5), 5.0)
        maxRecordingSeconds = min(max(decoded(Double.self, .maxRecordingSeconds, fallback: maxRecordingSeconds), 15.0), 300.0)
        audioDuckingEnabled = decoded(Bool.self, .audioDuckingEnabled, fallback: audioDuckingEnabled)
        cleanupMode = decoded(CleanupMode.self, .cleanupMode, fallback: cleanupMode)
        cleanupPreset = decoded(CleanupPreset.self, .cleanupPreset, fallback: cleanupPreset)
        customCleanupPrompt = decoded(String?.self, .customCleanupPrompt, fallback: customCleanupPrompt)
        appContextAwarenessEnabled = decoded(Bool.self, .appContextAwarenessEnabled, fallback: appContextAwarenessEnabled)
        pronunciations = decoded([SaysoPronunciationEntry].self, .pronunciations, fallback: pronunciations)
        selectedCloudProviderId = decoded(String.self, .selectedCloudProviderId, fallback: selectedCloudProviderId)
        selectedCloudModelId = decoded(String.self, .selectedCloudModelId, fallback: selectedCloudModelId)
        selectedCloudCleanupProviderId = decoded(String.self, .selectedCloudCleanupProviderId, fallback: selectedCloudCleanupProviderId)
        selectedCloudCleanupModelId = decoded(String.self, .selectedCloudCleanupModelId, fallback: selectedCloudCleanupModelId)
        selectedLocalSlmModelId = decoded(String.self, .selectedLocalSlmModelId, fallback: selectedLocalSlmModelId)
        selectedLocalAsrModelId = decoded(String.self, .selectedLocalAsrModelId, fallback: selectedLocalAsrModelId)
    }

    public func resolvedDictationProfile(forBundleIdentifier bundleIdentifier: String?) -> DictationProfile {
        DictationProfileResolver(
            fallback: dictationProfile,
            overrides: dictationProfileOverrides
        ).resolve(forBundleIdentifier: bundleIdentifier)
    }

    /// Captures app-specific choices for one dictation session without changing
    /// the user's stored defaults.
    public func resolvedDictationSettings(forBundleIdentifier bundleIdentifier: String?) -> Self {
        let profile = resolvedDictationProfile(forBundleIdentifier: bundleIdentifier)
        var resolved = self
        resolved.dictationProfile = profile
        if let language = profile.languageOverride {
            resolved.language = language
        }
        if let route = profile.routeOverride {
            resolved.route = route
        }
        if let transcriptionModel = profile.transcriptionModelOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !transcriptionModel.isEmpty {
            resolved.byokTranscriptionModel = transcriptionModel
        }
        if let translationEnabled = profile.translationEnabledOverride {
            resolved.translationEnabled = translationEnabled
        }
        if let outputLanguage = profile.outputLanguageOverride, outputLanguage != .automatic {
            resolved.outputLanguage = outputLanguage
        }
        if let cleanupEnabled = profile.cleanupEnabledOverride {
            resolved.cleanupEnabled = cleanupEnabled
        }
        if let cleanupModel = profile.cleanupModelOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cleanupModel.isEmpty {
            resolved.byokCleanupModel = cleanupModel
        }
        return resolved
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

    public static func apply(_ text: String, pronunciations: [SaysoPronunciationEntry]) -> String {
        var map: [String: String] = [:]
        for entry in pronunciations {
            let trigger = entry.spokenTrigger
            let rep = entry.effectiveReplacement
            if !trigger.isEmpty && !rep.isEmpty && trigger.caseInsensitiveCompare(rep) != .orderedSame {
                map[trigger] = rep
            }
        }
        return apply(text, replacements: map)
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
