import AppKit

/// Read side of the clipboard, used only to fill `{clipboard}` at the moment the user copies a snippet.
public protocol SnippetsClipboardReading: Sendable {
    /// The clipboard's plain text, or nil when it holds none.
    func readText() -> String?
}

/// Reads plain text from `NSPasteboard`, the general one in the app. Called only when the user copies a snippet that
/// holds `{clipboard}`; it never writes. Text the copying app marked as a secret (a password manager, or a transient or
/// concealed item, the same markers the Clipboard module honours) reads as no text, so it is never filled into a plain
/// clipboard write or shown on screen.
public struct PasteboardSnippetsClipboardReader: SnippetsClipboardReading, @unchecked Sendable {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    public func readText() -> String? {
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        guard !ClipboardPrivacy.isSensitive(types: types, sourceBundleID: nil) else { return nil }
        return pasteboard.string(forType: .string)
    }
}
