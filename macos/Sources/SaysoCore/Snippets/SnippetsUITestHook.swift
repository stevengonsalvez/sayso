import Foundation

/// UI test hook: `--ui-test-clipboard <text>`, honoured only together with `--ui-test-fresh-settings`, swaps both
/// clipboard ports for one in-memory board holding `text`, so a UI test never reads or writes the user's clipboard.
public enum SnippetsUITestHook {
    /// The fake board for a UI test launch, or nil to use the real clipboard. A missing value gives an empty board,
    /// never the real one.
    public static func board(arguments: [String]) -> SnippetsUITestBoard? {
        guard arguments.contains("--ui-test-fresh-settings"), let flag = arguments.firstIndex(of: "--ui-test-clipboard")
        else { return nil }
        return SnippetsUITestBoard(text: arguments.indices.contains(flag + 1) ? arguments[flag + 1] : nil)
    }
}

/// An in-memory clipboard: reads return its text, and a write replaces the text and is recorded.
public final class SnippetsUITestBoard: SnippetsClipboardReading, CalculatorPasteboardPort, @unchecked Sendable {
    private let lock = NSLock()
    private var text: String?
    private var writes: [String] = []

    init(text: String?) { self.text = text }

    public var written: [String] { lock.withLock { writes } }

    public func readText() -> String? { lock.withLock { text } }

    public func write(_ text: String) -> Bool {
        lock.withLock {
            self.text = text
            writes.append(text)
            return true
        }
    }
}
