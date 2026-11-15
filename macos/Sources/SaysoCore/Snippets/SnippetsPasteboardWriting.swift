import AppKit

/// Write side of the clipboard for Snippets. `concealed` marks the text so clipboard managers skip it; a copy that
/// filled in `{clipboard}` text is always written concealed, because that text may come from a password manager that
/// sets no marker.
public protocol SnippetsPasteboardWriting: Sendable {
    /// Replaces the pasteboard with plain text; false when the write was refused.
    func write(_ text: String, concealed: Bool) -> Bool
}

/// Writes to `NSPasteboard`, the general one in the app, through the Clipboard module's own writer so the concealed
/// marker is set in one place. Called only when the user presses Copy.
public struct PasteboardSnippetsWriter: SnippetsPasteboardWriting, @unchecked Sendable {
    private let port: PasteboardClipboardPort

    public init(pasteboard: NSPasteboard = .general) { port = PasteboardClipboardPort(pasteboard: pasteboard) }

    public func write(_ text: String, concealed: Bool) -> Bool { port.write(text: text, concealed: concealed) }
}
