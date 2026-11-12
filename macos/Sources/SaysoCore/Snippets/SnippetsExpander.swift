import Foundation

/// Something the user may want to know about a snippet; never a reason to refuse it.
public enum SnippetsWarning: Equatable, Sendable {
    /// A placeholder-shaped word in braces that Sayso does not know, kept as typed.
    case unknownPlaceholder(String)
    /// `{clipboard}` was asked for but the clipboard held no text.
    case clipboardHasNoText

    public var message: String {
        switch self {
        case let .unknownPlaceholder(token): "\(token) is not a placeholder, so it was left as typed."
        case .clipboardHasNoText: "The clipboard had no text, so {clipboard} was left empty."
        }
    }
}

public struct SnippetsExpansion: Equatable, Sendable {
    public let text: String
    public let warnings: [SnippetsWarning]
}

/// Replaces `{date}`, `{time}` and `{clipboard}` in one pass, so text that a placeholder inserts is never read as
/// placeholders again. Only a letter followed by up to 31 letters, digits, `_` or `-` inside braces is a placeholder;
/// other braces (`{}`, `{ x }`, `{0}`, JSON) are plain text. Names ignore case.
public struct SnippetsExpander: Sendable {
    static let nameLimit = 32
    private let locale: Locale
    private let timeZone: TimeZone

    public init(locale: Locale, timeZone: TimeZone) {
        self.locale = locale
        self.timeZone = timeZone
    }

    /// `clipboard` is called at most once, and only when the body holds `{clipboard}`.
    public func expand(_ body: String, at date: Date, clipboard: () -> String?) -> SnippetsExpansion {
        var text = ""
        var warnings: [SnippetsWarning] = []
        var pasted: String??
        for piece in Self.pieces(of: body) {
            switch piece {
            case let .plain(plain):
                text += plain
            case let .placeholder(token, name):
                switch name.lowercased() {
                case "date": text += format(date, date: .medium, time: .none)
                case "time": text += format(date, date: .none, time: .short)
                case "clipboard":
                    if pasted == nil { pasted = .some(clipboard()) }
                    if let value = pasted ?? nil, !value.isEmpty {
                        text += value
                    } else if !warnings.contains(.clipboardHasNoText) {
                        warnings.append(.clipboardHasNoText)
                    }
                default:
                    text += token
                    let warning = SnippetsWarning.unknownPlaceholder(token)
                    if !warnings.contains(warning) { warnings.append(warning) }
                }
            }
        }
        return SnippetsExpansion(text: text, warnings: warnings)
    }

    /// Unknown placeholders in `body`, found without expanding anything or reading the clipboard.
    public static func warnings(in body: String) -> [SnippetsWarning] {
        var warnings: [SnippetsWarning] = []
        for case let .placeholder(token, name) in pieces(of: body) where !known.contains(name.lowercased()) {
            let warning = SnippetsWarning.unknownPlaceholder(token)
            if !warnings.contains(warning) { warnings.append(warning) }
        }
        return warnings
    }

    private static let known: Set<String> = ["date", "time", "clipboard"]

    private enum Piece {
        case plain(String)
        /// The token as typed, braces included, and the name inside.
        case placeholder(String, String)
    }

    private static func pieces(of body: String) -> [Piece] {
        var pieces: [Piece] = []
        var plain = ""
        var index = body.startIndex
        while index < body.endIndex {
            if body[index] == "{", let close = placeholderEnd(in: body, openingAt: index) {
                if !plain.isEmpty { pieces.append(.plain(plain)); plain = "" }
                let name = String(body[body.index(after: index)..<close])
                pieces.append(.placeholder("{\(name)}", name))
                index = body.index(after: close)
            } else {
                plain.append(body[index])
                index = body.index(after: index)
            }
        }
        if !plain.isEmpty { pieces.append(.plain(plain)) }
        return pieces
    }

    /// The index of the closing brace when a placeholder-shaped name follows `open`, else nil.
    private static func placeholderEnd(in body: String, openingAt open: String.Index) -> String.Index? {
        var index = body.index(after: open)
        var length = 0
        while index < body.endIndex, length <= nameLimit {
            let character = body[index]
            if character == "}" { return length > 0 ? index : nil }
            let allowed = length == 0
                ? character.isASCII && character.isLetter
                : character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-")
            guard allowed else { return nil }
            length += 1
            index = body.index(after: index)
        }
        return nil
    }

    private func format(_ date: Date, date dateStyle: DateFormatter.Style, time timeStyle: DateFormatter.Style) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter.string(from: date)
    }
}
