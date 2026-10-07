import Foundation

/// Reads the paths a user typed and proposes output names that never replace a file.
public enum FileToolsPaths {
    /// How far `outputNames` counts before giving up: "Archive.zip" up to "Archive 1000.zip".
    public static let maxOutputNames = 1000

    /// One path per line. A line is split at commas only when every piece is itself a full path, so a file name
    /// with a comma in it ("Invoice, March.pdf") stays whole. `~` means the home folder; anything else must start
    /// with `/`. Blank lines are skipped.
    public static func parse(_ text: String) throws -> [URL] {
        var paths: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let whole = line.trimmingCharacters(in: .whitespaces)
            guard !whole.isEmpty else { continue }
            let pieces = whole.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let isList = pieces.count > 1 && pieces.allSatisfy { $0.hasPrefix("/") || $0.hasPrefix("~") }
            paths += isList ? pieces : [whole]
        }
        return try paths.map { path in
            let expanded = (path as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { throw FileToolsError.relativePath(path) }
            return URL(fileURLWithPath: expanded)
        }
    }

    /// "Archive.zip", "Archive 2.zip", "Archive 3.zip" and so on; the number goes before the last extension.
    public static func outputNames(for name: String) -> [String] {
        let dot = name.lastIndex(of: ".").flatMap { $0 == name.startIndex ? nil : $0 }
        let stem = dot.map { String(name[..<$0]) } ?? name
        let suffix = dot.map { String(name[$0...]) } ?? ""
        return [name] + (2...maxOutputNames).map { "\(stem) \($0)\(suffix)" }
    }
}
