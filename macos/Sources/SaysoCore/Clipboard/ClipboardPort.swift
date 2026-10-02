import Foundation

/// Boundary to NSPasteboard; the adapter lives in the app target so core stays deterministic.
public protocol ClipboardPort: Sendable {
    var changeCount: Int { get }
    func snapshot() -> ClipboardSnapshot
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
