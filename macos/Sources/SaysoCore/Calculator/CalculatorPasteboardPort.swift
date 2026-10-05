import AppKit

/// Write-only: the calculator copies a result out and has no way to read what is on the pasteboard.
public protocol CalculatorPasteboardPort: Sendable {
    /// Replaces the pasteboard with plain text; false when the write was refused.
    func write(_ text: String) -> Bool
}

/// Writes to `NSPasteboard`, the general one in the app. Called only when the user presses Copy.
public struct PasteboardCalculatorPort: CalculatorPasteboardPort, @unchecked Sendable {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    public func write(_ text: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
