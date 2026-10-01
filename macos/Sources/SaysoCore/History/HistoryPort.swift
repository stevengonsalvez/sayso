import Foundation

/// Boundary to persistence; `HistoryStore` adapts to it so tests never touch disk.
public protocol HistoryPort: Sendable {
    func append(_ transcript: Transcript) async -> HistoryAppendResult
}

extension HistoryStore: HistoryPort {
    public func append(_ transcript: Transcript) async -> HistoryAppendResult {
        appendResult(transcript)
    }
}
