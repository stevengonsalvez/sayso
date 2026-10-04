import Foundation

/// Boundary to NSPasteboard; the adapter lives in the app target so core stays deterministic.
public protocol ClipboardPort: Sendable {
    var changeCount: Int { get }
    /// Light read of the types and plain text; the change count is re-read after so the parts belong together.
    func snapshot() -> ClipboardSnapshot
    /// Heavy read of every item and flavour, used only to restore the clipboard after a temporary paste.
    func captureContents() -> ClipboardContents
    /// Replaces the pasteboard with `contents` verbatim; empty contents clear it.
    @discardableResult
    func restore(_ contents: ClipboardContents) -> Bool
    func clear()
    /// Writes plain text only; `concealed` marks it so clipboard managers skip it.
    @discardableResult
    func write(text: String, concealed: Bool) -> Bool
}

/// Emitted for every recorded copy so other modules (smart actions, rewrite) can react without importing this one.
public struct ClipboardItemRecorded: SaysoEvent, Equatable {
    public let id: UUID
    public let text: String
    public let sourceApp: String?
    public init(id: UUID, text: String, sourceApp: String?) {
        self.id = id
        self.text = text
        self.sourceApp = sourceApp
    }
}
