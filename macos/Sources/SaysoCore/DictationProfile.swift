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

    public init(
        id: String = UUID().uuidString,
        name: String,
        corrections: [DictationCorrection] = [],
        normalizesWhitespace: Bool = false,
        capitalizesSentences: Bool = false
    ) {
        self.id = id
        self.name = name
        self.corrections = corrections
        self.normalizesWhitespace = normalizesWhitespace
        self.capitalizesSentences = capitalizesSentences
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
