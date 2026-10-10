import AppKit

/// Read side of the clipboard, used only to fill `{clipboard}` at the moment the user copies a snippet.
public protocol SnippetsClipboardReading: Sendable {
    /// The clipboard's plain text, or nil when it holds none.
    func readText() -> String?
}

/// Reads plain text from `NSPasteboard`, the general one in the app. Called only when the user copies a snippet that
/// holds `{clipboard}`; it never writes.
public struct PasteboardSnippetsClipboardReader: SnippetsClipboardReading, @unchecked Sendable {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    public func readText() -> String? { pasteboard.string(forType: .string) }
}
