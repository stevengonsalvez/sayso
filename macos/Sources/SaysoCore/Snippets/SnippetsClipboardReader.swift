import Foundation

/// Read side of the clipboard, used only to fill `{clipboard}` at the moment the user copies a snippet.
public protocol SnippetsClipboardReading: Sendable {
    /// The clipboard's plain text, or nil when it holds none.
    func readText() -> String?
}
