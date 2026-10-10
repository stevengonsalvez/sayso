import Foundation

/// A named piece of text the user keeps. Names are unique ignoring case; the body may hold placeholders.
public struct Snippet: Codable, Equatable, Sendable {
    public let name: String
    public let body: String

    public init(name: String, body: String) {
        self.name = name
        self.body = body
    }
}

/// What one Copy produced; kept only while its notice shows.
public struct SnippetCopy: Equatable, Sendable {
    public let name: String
    public let text: String
    public let warnings: [SnippetsWarning]

    public init(name: String, text: String, warnings: [SnippetsWarning]) {
        self.name = name
        self.text = text
        self.warnings = warnings
    }
}

public enum SnippetsError: Error, Equatable, Sendable {
    case off
    case emptyName
    case nameTooLong
    case nameNotOneLine
    case emptyBody
    case bodyTooLong
    /// Carries the name already taken, as it is stored.
    case duplicateName(String)
    case full
    case notFound(String)
    case writeFailed(String)

    public var message: String {
        switch self {
        case .off: "Snippets are off. Turn them on in Settings."
        case .emptyName: "Give the snippet a name."
        case .nameTooLong: "A name can be at most \(SnippetsModule.nameLimit) characters."
        case .nameNotOneLine: "A name must fit on one line."
        case .emptyBody: "The snippet has no text."
        case .bodyTooLong: "Snippet text can be at most 10,000 characters."
        case let .duplicateName(name): "A snippet named \(name) already exists."
        case .full: "You can keep at most \(SnippetsModule.maxSnippets) snippets. Delete one to add another."
        case let .notFound(name): "There is no snippet named \(name)."
        case let .writeFailed(name): "Could not copy \(name) to the clipboard."
        }
    }
}
