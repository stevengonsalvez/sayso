import Foundation

/// Where snippets are kept between launches. The module saves only when the user adds, renames, edits or deletes.
public protocol SnippetsStore: Sendable {
    func load() -> [Snippet]
    func save(_ snippets: [Snippet])
}

/// Keeps the list as JSON under one key. Missing, wrongly typed or unreadable data reads as an empty list, and an
/// unreadable entry is skipped rather than losing the rest. Loading never writes, so damaged data stays as it was
/// until the user's next edit replaces it.
public final class UserDefaultsSnippetsStore: SnippetsStore, @unchecked Sendable {
    public static let key = "ai.sayso.notch.snippets.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [Snippet] {
        guard let data = defaults.data(forKey: Self.key),
              let entries = try? JSONDecoder().decode([Lenient].self, from: data) else { return [] }
        return entries.compactMap(\.snippet)
    }

    public func save(_ snippets: [Snippet]) {
        guard let data = try? JSONEncoder().encode(snippets) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private struct Lenient: Decodable {
        let snippet: Snippet?
        init(from decoder: Decoder) throws { snippet = try? Snippet(from: decoder) }
    }
}
