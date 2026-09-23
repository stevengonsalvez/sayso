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
        cleaned = cleaned.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(
            of: #"(?<!\d)([,;!?])(?!\d)([^\s\]\)"'])"#,
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
}
