import Foundation
import Testing
@testable import SaysoCore

@Test func pronunciationCategoriesHaveValidDisplayNames() {
    let categories = PronunciationCategory.allCases
    #expect(categories.count == 7)

    #expect(PronunciationCategory.technical.displayName == "Technical")
    #expect(PronunciationCategory.names.displayName == "Names")
    #expect(PronunciationCategory.acronyms.displayName == "Acronyms")
    #expect(PronunciationCategory.symbols.displayName == "Symbols")
    #expect(PronunciationCategory.brands.displayName == "Brands")
    #expect(PronunciationCategory.medical.displayName == "Medical")
    #expect(PronunciationCategory.custom.displayName == "Custom")

    #expect(PronunciationCategory.from(string: "Technical") == .technical)
    #expect(PronunciationCategory.from(string: "technical") == .technical)
    #expect(PronunciationCategory.from(string: "unknown_category") == .custom)
    #expect(PronunciationCategory.from(string: nil) == .custom)
}

@Test func pronunciationEntryCodableRoundtrip() throws {
    let entry = SaysoPronunciationEntry(
        id: "test-id-123",
        word: "Kubernetes",
        pronunciation: "koo-ber-net-ees",
        replacement: "Kubernetes",
        category: .names,
        isRegex: false,
        caseSensitive: true
    )

    let data = try JSONEncoder().encode(entry)
    let decoded = try JSONDecoder().decode(SaysoPronunciationEntry.self, from: data)

    #expect(decoded.id == entry.id)
    #expect(decoded.word == entry.word)
    #expect(decoded.pronunciation == entry.pronunciation)
    #expect(decoded.replacement == entry.replacement)
    #expect(decoded.category == entry.category)
    #expect(decoded.isRegex == entry.isRegex)
    #expect(decoded.caseSensitive == entry.caseSensitive)
}

@Test func androidJsonCompatibility() throws {
    // Verbatim format produced by Android Sayso Lexicon.encodePronunciations
    let androidJson = """
    [
      {
        "id": "abc-123",
        "word": "iOS",
        "pronunciation": "eye OS",
        "replacement": "iOS",
        "category": "Technical",
        "isRegex": false,
        "caseSensitive": false
      },
      {
        "id": "def-456",
        "word": "!=",
        "pronunciation": "not equal",
        "category": "Symbols",
        "isRegex": false,
        "caseSensitive": false
      }
    ]
    """

    let decoded = try PronunciationJsonCodec.decode(androidJson)
    #expect(decoded.count == 2)

    #expect(decoded[0].word == "iOS")
    #expect(decoded[0].pronunciation == "eye OS")
    #expect(decoded[0].replacement == "iOS")
    #expect(decoded[0].category == .technical)

    #expect(decoded[1].word == "!=")
    #expect(decoded[1].pronunciation == "not equal")
    #expect(decoded[1].category == .symbols)
    #expect(decoded[1].effectiveReplacement == "!=")
}

@Test func pronunciationDefaultsArePopulated() {
    let defaults = PronunciationDefaults.standard
    #expect(defaults.count >= 20)

    let words = defaults.map(\.word)
    #expect(words.contains("iOS"))
    #expect(words.contains("macOS"))
    #expect(words.contains("CLI"))
    #expect(words.contains("kubectl"))
    #expect(words.contains("Kubernetes"))
    #expect(words.contains("PostgreSQL"))
}

@Test func lexiconCorrectionsApplyPronunciations() {
    let pronunciations: [SaysoPronunciationEntry] = [
        SaysoPronunciationEntry(word: "kubectl", pronunciation: "cube control", replacement: "kubectl", category: .technical),
        SaysoPronunciationEntry(word: "macOS", pronunciation: "mac OS", replacement: "macOS", category: .technical),
        SaysoPronunciationEntry(word: "!=", pronunciation: "not equal", replacement: "!=", category: .symbols)
    ]

    let text = "run cube control apply on mac OS when status is not equal true"
    let corrected = LexiconCorrections.apply(text, pronunciations: pronunciations)

    #expect(corrected.contains("kubectl"))
    #expect(corrected.contains("macOS"))
    #expect(corrected.contains("!="))
}

@Test func pipelineSettingsPresetAndPolicy() {
    #expect(CleanupPreset.allCases.count == 5)
    #expect(CleanupMode.allCases.count == 3)

    let standardPrompt = CleanupPolicy.resolvePrompt(preset: .standard, customPrompt: nil)
    #expect(standardPrompt.contains("transcription formatter"))
    #expect(standardPrompt.contains("Hard constraints"))

    let customPrompt = CleanupPolicy.resolvePrompt(preset: .custom, customPrompt: "Custom user prompt instructions")
    #expect(customPrompt == "Custom user prompt instructions")

    #expect(AppContextCategory.from(bundleIdentifier: "com.tinyspeck.slackmacgap") == .chat)
    #expect(AppContextCategory.from(bundleIdentifier: "com.apple.mail") == .email)
    #expect(AppContextCategory.from(bundleIdentifier: "com.apple.Terminal") == .codeTerminal)
    #expect(AppContextCategory.from(bundleIdentifier: "com.apple.Notes") == .docsNotes)
    #expect(AppContextCategory.from(bundleIdentifier: "com.unknown.app") == .general)
}

@Test func saysoSettingsPipelineRoundtrip() throws {
    var settings = SaysoSettings()
    settings.hints = ["GraphQL", "protobuf", "gRPC"]
    settings.autoLanguageRouting = true
    settings.transliterateIndicToLatin = true
    settings.silenceTimeoutSeconds = 2.0
    settings.maxRecordingSeconds = 180.0
    settings.audioDuckingEnabled = true
    settings.cleanupMode = .cloudLLM
    settings.cleanupPreset = .developer
    settings.customCleanupPrompt = "Special prompt"
    settings.appContextAwarenessEnabled = true
    settings.pronunciations = [
        SaysoPronunciationEntry(word: "Neovim", pronunciation: "neo vim", replacement: "Neovim", category: .technical)
    ]

    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(SaysoSettings.self, from: data)

    #expect(decoded.hints == ["GraphQL", "protobuf", "gRPC"])
    #expect(decoded.autoLanguageRouting == true)
    #expect(decoded.transliterateIndicToLatin == true)
    #expect(decoded.silenceTimeoutSeconds == 2.0)
    #expect(decoded.maxRecordingSeconds == 180.0)
    #expect(decoded.audioDuckingEnabled == true)
    #expect(decoded.cleanupMode == .cloudLLM)
    #expect(decoded.cleanupPreset == .developer)
    #expect(decoded.customCleanupPrompt == "Special prompt")
    #expect(decoded.appContextAwarenessEnabled == true)
    #expect(decoded.pronunciations.count == 1)
    #expect(decoded.pronunciations.first?.word == "Neovim")
}
