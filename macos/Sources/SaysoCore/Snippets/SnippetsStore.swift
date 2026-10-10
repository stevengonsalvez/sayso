import Foundation

/// Where snippets are kept between launches. The module saves only when the user adds, renames, edits or deletes.
public protocol SnippetsStore: Sendable {
    func load() -> [Snippet]
    func save(_ snippets: [Snippet])
}
