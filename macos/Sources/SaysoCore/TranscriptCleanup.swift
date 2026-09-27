import Foundation

public enum TranscriptCleanup {
    public static func processLocally(_ text: String, capitalizesFirstLetter: Bool = true) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        var cleaned = trimmed.replacingOccurrences(
            of: #"(?i)\s*\[blank_audio\]\s*"#,
            with: " ",
            options: .regularExpression
        )

        // Spoken punctuation replacements
        cleaned = cleaned.replacingOccurrences(of: #"(?i)\s*\b(?:period|full stop)\b"#, with: ".", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"(?i)\s*\bcomma\b"#, with: ",", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"(?i)\s*\bquestion mark\b"#, with: "?", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"(?i)\s*\b(?:exclamation mark|exclamation point)\b"#, with: "!", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"(?i)\s*\bcolon\b"#, with: ":", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"(?i)\s*\b(?:semicolon|semi colon)\b"#, with: ";", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"(?i)\s*\b(?:new line|newline)\b"#, with: "\n", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"(?i)\s*\bnew paragraph\b"#, with: "\n\n", options: .regularExpression)

        cleaned = cleaned.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\s+(,)"#, with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(
            of: #"(?<!\d)([,;!?])(?![\d!?.,;:=])([^\s\]\)"'])"#,
            with: "$1 $2",
            options: .regularExpression
        )
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        guard capitalizesFirstLetter else { return cleaned }
        guard let first = cleaned.first else { return cleaned }
        let uppercase = String(first).uppercased()
        if String(first) != uppercase {
            cleaned.replaceSubrange(cleaned.startIndex...cleaned.startIndex, with: uppercase)
        }

        return cleaned
    }

    public static func smartFormat(
        _ text: String,
        capitalizesFirstLetter: Bool = true,
        capitalizesSentences: Bool = true,
        addsTerminalPunctuation: Bool = true
    ) -> String {
        var cleaned = processLocally(text, capitalizesFirstLetter: capitalizesFirstLetter)
        guard !cleaned.isEmpty else { return cleaned }

        if capitalizesSentences {
            let sentencePattern = #"(?<=\.\s)([a-z])|(?<=\?\s)([a-z])|(?<=\!\s)([a-z])|(?<=\n)([a-z])"#
            if let regex = try? NSRegularExpression(pattern: sentencePattern) {
                let nsString = cleaned as NSString
                let matches = regex.matches(in: cleaned, range: NSRange(location: 0, length: nsString.length))
                for match in matches.reversed() {
                    let range = match.range
                    let char = nsString.substring(with: range).uppercased()
                    cleaned = (cleaned as NSString).replacingCharacters(in: range, with: char)
                }
            }
        }

        if addsTerminalPunctuation, let last = cleaned.last, last.isLetter {
            cleaned.append(".")
        }

        return cleaned
    }
}
