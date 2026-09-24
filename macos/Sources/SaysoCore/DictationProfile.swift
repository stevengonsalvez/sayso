import Foundation

public struct DictationCorrection: Codable, Equatable, Identifiable, Sendable {
    public let source: String
    public let replacement: String

    public var id: String { source.lowercased() }

    public init(source: String, replacement: String) {
        self.source = source
        self.replacement = replacement
    }
}

public struct DictationProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var corrections: [DictationCorrection]
    public var normalizesWhitespace: Bool
    public var capitalizesSentences: Bool
    /// Per-session language. `nil` keeps the normal Sayso language setting.
    public var languageOverride: DictationLanguage?
    /// Per-session speech route. `nil` keeps the normal Sayso route.
    public var routeOverride: ProviderRoute?
    /// Per-session transcription model override (for BYOK route). `nil` keeps the normal Sayso setting.
    public var transcriptionModelOverride: String?
    /// Per-session translation switch. `nil` keeps the normal Sayso setting.
    public var translationEnabledOverride: Bool?
    /// Per-session translation destination. `nil` keeps the normal Sayso setting.
    public var outputLanguageOverride: DictationLanguage?
    /// Per-session transcript cleanup switch. `nil` keeps the normal Sayso setting.
    public var cleanupEnabledOverride: Bool?
    /// Per-session cleanup model override (for BYOK cleanup). `nil` keeps the normal Sayso setting.
    public var cleanupModelOverride: String?
    /// Per-session cleanup directives (e.g. custom formatting rules).
    public var cleanupDirectives: [String]

    public init(
        id: String = UUID().uuidString,
        name: String,
        corrections: [DictationCorrection] = [],
        normalizesWhitespace: Bool = false,
        capitalizesSentences: Bool = false,
        languageOverride: DictationLanguage? = nil,
        routeOverride: ProviderRoute? = nil,
        transcriptionModelOverride: String? = nil,
        translationEnabledOverride: Bool? = nil,
        outputLanguageOverride: DictationLanguage? = nil,
        cleanupEnabledOverride: Bool? = nil,
        cleanupModelOverride: String? = nil,
        cleanupDirectives: [String] = []
    ) {
        self.id = id
        self.name = name
        self.corrections = corrections
        self.normalizesWhitespace = normalizesWhitespace
        self.capitalizesSentences = capitalizesSentences
        self.languageOverride = languageOverride
        self.routeOverride = routeOverride
        self.transcriptionModelOverride = transcriptionModelOverride
        self.translationEnabledOverride = translationEnabledOverride
        self.outputLanguageOverride = outputLanguageOverride
        self.cleanupEnabledOverride = cleanupEnabledOverride
        self.cleanupModelOverride = cleanupModelOverride
        self.cleanupDirectives = cleanupDirectives
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, corrections, normalizesWhitespace, capitalizesSentences
        case languageOverride, routeOverride, transcriptionModelOverride
        case translationEnabledOverride, outputLanguageOverride
        case cleanupEnabledOverride, cleanupModelOverride, cleanupDirectives
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        corrections = (try? container.decodeIfPresent([DictationCorrection].self, forKey: .corrections)) ?? []
        normalizesWhitespace = (try? container.decodeIfPresent(Bool.self, forKey: .normalizesWhitespace)) ?? false
        capitalizesSentences = (try? container.decodeIfPresent(Bool.self, forKey: .capitalizesSentences)) ?? false
        languageOverride = try? container.decodeIfPresent(DictationLanguage.self, forKey: .languageOverride)
        routeOverride = try? container.decodeIfPresent(ProviderRoute.self, forKey: .routeOverride)
        transcriptionModelOverride = try? container.decodeIfPresent(String.self, forKey: .transcriptionModelOverride)
        translationEnabledOverride = try? container.decodeIfPresent(Bool.self, forKey: .translationEnabledOverride)
        outputLanguageOverride = try? container.decodeIfPresent(DictationLanguage.self, forKey: .outputLanguageOverride)
        cleanupEnabledOverride = try? container.decodeIfPresent(Bool.self, forKey: .cleanupEnabledOverride)
        cleanupModelOverride = try? container.decodeIfPresent(String.self, forKey: .cleanupModelOverride)
        cleanupDirectives = (try? container.decodeIfPresent([String].self, forKey: .cleanupDirectives)) ?? []
    }

    public static let `default` = DictationProfile(id: "default", name: "Default")

    /// Longest phrases win, then original profile order breaks ties deterministically.
    public var orderedCorrections: [DictationCorrection] {
        corrections.enumerated()
            .filter { !$0.element.source.isEmpty }
            .sorted {
                $0.element.source.count == $1.element.source.count
                    ? $0.offset < $1.offset
                    : $0.element.source.count > $1.element.source.count
            }
            .map(\.element)
    }

    public func postProcess(_ text: String) -> String {
        var result = applyCorrections(to: text)
        if normalizesWhitespace {
            result = result
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        return capitalizesSentences ? capitalizeSentences(in: result) : result
    }

    private func applyCorrections(to text: String) -> String {
        let corrections = orderedCorrections
        guard !corrections.isEmpty else { return text }

        var cursor = text.startIndex
        var output = ""
        while cursor < text.endIndex {
            if let correction = corrections.first(where: { correction in
                guard let range = text.range(
                    of: correction.source,
                    options: [.caseInsensitive],
                    range: cursor..<text.endIndex
                ) else {
                    return false
                }
                return range.lowerBound == cursor
            }) {
                output += correction.replacement
                cursor = text.index(cursor, offsetBy: correction.source.count)
            } else {
                output.append(text[cursor])
                cursor = text.index(after: cursor)
            }
        }
        return output
    }

    private func capitalizeSentences(in text: String) -> String {
        var output = ""
        var shouldCapitalize = true
        for character in text {
            if shouldCapitalize, character.isLetter {
                output += String(character).uppercased()
                shouldCapitalize = false
            } else {
                output.append(character)
            }
            if character == "." || character == "!" || character == "?" {
                shouldCapitalize = true
            }
        }
        return output
    }
}

/// An app-specific profile that takes precedence only for its exact bundle identifier.
/// The profile itself stays unchanged, so normal dictation remains the fallback.
public struct DictationProfileBundleOverride: Codable, Equatable, Sendable {
    public var bundleIdentifier: String
    public var profile: DictationProfile

    public init(bundleIdentifier: String, profile: DictationProfile) {
        self.bundleIdentifier = bundleIdentifier
        self.profile = profile
    }
}

/// Resolves a dictation profile without mutating stored defaults or app overrides.
/// The first matching override in user order wins.
public struct DictationProfileResolver: Sendable {
    public let fallback: DictationProfile
    public let overrides: [DictationProfileBundleOverride]

    public init(fallback: DictationProfile, overrides: [DictationProfileBundleOverride]) {
        self.fallback = fallback
        self.overrides = overrides
    }

    public func resolve(forBundleIdentifier bundleIdentifier: String?) -> DictationProfile {
        guard let target = Self.normalizedBundleIdentifier(bundleIdentifier) else {
            return fallback
        }

        return overrides.first { override in
            Self.normalizedBundleIdentifier(override.bundleIdentifier) == target
        }?.profile ?? fallback
    }

    private static func normalizedBundleIdentifier(_ raw: String?) -> String? {
        guard let normalized = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !normalized.isEmpty else {
            return nil
        }
        return normalized
    }
}
