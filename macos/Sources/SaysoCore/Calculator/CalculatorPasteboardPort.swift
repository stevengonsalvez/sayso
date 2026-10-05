import Foundation

/// Write-only: the calculator copies a result out and has no way to read what is on the pasteboard.
public protocol CalculatorPasteboardPort: Sendable {
    /// Replaces the pasteboard with plain text; false when the write was refused.
    func write(_ text: String) -> Bool
}
