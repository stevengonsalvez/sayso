import Foundation

/// Categories for pronunciation entries, matching Android Sayso developer workflows.
public enum PronunciationCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case technical = "Technical"
    case names = "Names"
    case acronyms = "Acronyms"
    case symbols = "Symbols"
    case brands = "Brands"
    case medical = "Medical"
    case custom = "Custom"

    public var id: String { rawValue }
    public var displayName: String { rawValue }

    public static func from(string: String?) -> PronunciationCategory {
        guard let string = string?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else {
            return .custom
        }
        return PronunciationCategory.allCases.first {
            $0.rawValue.caseInsensitiveCompare(string) == .orderedSame ||
            $0.displayName.caseInsensitiveCompare(string) == .orderedSame
        } ?? .custom
    }
}

/// Custom pronunciation and technical dictionary entry.
/// Matches the Android Sayso PronunciationEntry schema.
public struct SaysoPronunciationEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var word: String
    public var pronunciation: String
    public var replacement: String?
    public var category: PronunciationCategory
    public var isRegex: Bool
    public var caseSensitive: Bool

    public init(
        id: String = UUID().uuidString,
        word: String,
        pronunciation: String,
        replacement: String? = nil,
        category: PronunciationCategory = .technical,
        isRegex: Bool = false,
        caseSensitive: Bool = false
    ) {
        self.id = id
        self.word = word
        self.pronunciation = pronunciation
        self.replacement = replacement
        self.category = category
        self.isRegex = isRegex
        self.caseSensitive = caseSensitive
    }

    enum CodingKeys: String, CodingKey {
        case id
        case word
        case pronunciation
        case replacement
        case category
        case isRegex
        case caseSensitive
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.word = try container.decode(String.self, forKey: .word)
        self.pronunciation = try container.decodeIfPresent(String.self, forKey: .pronunciation) ?? ""
        self.replacement = try container.decodeIfPresent(String.self, forKey: .replacement)
        if let categoryString = try container.decodeIfPresent(String.self, forKey: .category) {
            self.category = PronunciationCategory.from(string: categoryString)
        } else {
            self.category = .technical
        }
        self.isRegex = try container.decodeIfPresent(Bool.self, forKey: .isRegex) ?? false
        self.caseSensitive = try container.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(word, forKey: .word)
        try container.encode(pronunciation, forKey: .pronunciation)
        try container.encodeIfPresent(replacement, forKey: .replacement)
        try container.encode(category.displayName, forKey: .category)
        try container.encode(isRegex, forKey: .isRegex)
        try container.encode(caseSensitive, forKey: .caseSensitive)
    }

    /// Spoken trigger to search for when applying dictionary replacements.
    public var spokenTrigger: String {
        let trimmed = pronunciation.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? word : trimmed
    }

    /// Effective replacement text to produce in cleaned output.
    public var effectiveReplacement: String {
        if let replacement = replacement?.trimmingCharacters(in: .whitespacesAndNewlines), !replacement.isEmpty {
            return replacement
        }
        return word
    }
}


/// JSON Import/Export codec compatible with Android Sayso Lexicon.encodePronunciations format.
public enum PronunciationJsonCodec {
    public static func encode(_ entries: [SaysoPronunciationEntry]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        guard let string = String(data: data, encoding: .utf8) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: "Failed to encode UTF-8 string"))
        }
        return string
    }

    public static func decode(_ json: String) throws -> [SaysoPronunciationEntry] {
        guard let data = json.data(using: .utf8) else { return [] }
        if let standard = try? JSONDecoder().decode([SaysoPronunciationEntry].self, from: data) {
            return standard
        }

        // Fallback for legacy format with canonical and aliases
        struct LegacyRule: Decodable {
            let canonical: String
            let aliases: [String]?
        }

        if let legacy = try? JSONDecoder().decode([LegacyRule].self, from: data) {
            return legacy.map { rule in
                SaysoPronunciationEntry(
                    word: rule.canonical,
                    pronunciation: rule.aliases?.first ?? "",
                    replacement: rule.canonical,
                    category: .technical
                )
            }
        }

        return []
    }
}

/// Pre-populated technical vocabulary matching Android Sayso defaults.
public enum PronunciationDefaults {
    public static let standard: [SaysoPronunciationEntry] = [
        SaysoPronunciationEntry(word: "iOS", pronunciation: "eye OS", replacement: "iOS", category: .technical),
        SaysoPronunciationEntry(word: "macOS", pronunciation: "mac OS", replacement: "macOS", category: .technical),
        SaysoPronunciationEntry(word: "CLI", pronunciation: "C L I", replacement: "CLI", category: .technical),
        SaysoPronunciationEntry(word: "GUI", pronunciation: "gooey", replacement: "GUI", category: .technical),
        SaysoPronunciationEntry(word: "JSON", pronunciation: "jay-son", replacement: "JSON", category: .technical),
        SaysoPronunciationEntry(word: "YAML", pronunciation: "yam-el", replacement: "YAML", category: .technical),
        SaysoPronunciationEntry(word: "nginx", pronunciation: "engine-x", replacement: "nginx", category: .technical),
        SaysoPronunciationEntry(word: "kubectl", pronunciation: "cube-control", replacement: "kubectl", category: .technical),
        SaysoPronunciationEntry(word: "Kubernetes", pronunciation: "koo-ber-net-ees", replacement: "Kubernetes", category: .names),
        SaysoPronunciationEntry(word: "PostgreSQL", pronunciation: "post-gres-Q-L", replacement: "PostgreSQL", category: .names),
        SaysoPronunciationEntry(word: "MySQL", pronunciation: "my-S-Q-L", replacement: "MySQL", category: .names),
        SaysoPronunciationEntry(word: "Xcode", pronunciation: "ex-code", replacement: "Xcode", category: .names),
        SaysoPronunciationEntry(word: "URL", pronunciation: "U R L", replacement: "URL", category: .acronyms),
        SaysoPronunciationEntry(word: "HTTP", pronunciation: "H T T P", replacement: "HTTP", category: .acronyms),
        SaysoPronunciationEntry(word: "HTTPS", pronunciation: "H T T P S", replacement: "HTTPS", category: .acronyms),
        SaysoPronunciationEntry(word: "HTML", pronunciation: "H T M L", replacement: "HTML", category: .acronyms),
        SaysoPronunciationEntry(word: "CSS", pronunciation: "C S S", replacement: "CSS", category: .acronyms),
        SaysoPronunciationEntry(word: "AWS", pronunciation: "A W S", replacement: "AWS", category: .acronyms),
        SaysoPronunciationEntry(word: "GCP", pronunciation: "G C P", replacement: "GCP", category: .acronyms),
        SaysoPronunciationEntry(word: "@", pronunciation: "at sign", replacement: "@", category: .symbols),
        SaysoPronunciationEntry(word: "#", pronunciation: "hashtag", replacement: "#", category: .symbols),
        SaysoPronunciationEntry(word: "&", pronunciation: "ampersand", replacement: "&", category: .symbols),
        SaysoPronunciationEntry(word: "->", pronunciation: "arrow", replacement: "->", category: .symbols),
        SaysoPronunciationEntry(word: "=>", pronunciation: "fat arrow", replacement: "=>", category: .symbols),
        SaysoPronunciationEntry(word: "!=", pronunciation: "not equal", replacement: "!=", category: .symbols),
        SaysoPronunciationEntry(word: "==", pronunciation: "double equals", replacement: "==", category: .symbols),
        SaysoPronunciationEntry(word: "GitHub", pronunciation: "git-hub", replacement: "GitHub", category: .brands),
        SaysoPronunciationEntry(word: "GitLab", pronunciation: "git-lab", replacement: "GitLab", category: .brands),
        SaysoPronunciationEntry(word: "OpenAI", pronunciation: "open A I", replacement: "OpenAI", category: .brands),
    ]
}
