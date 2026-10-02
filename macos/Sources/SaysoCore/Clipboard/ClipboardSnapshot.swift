import Foundation

/// What the pasteboard held at one change count; the port fills it so core never touches AppKit.
public struct ClipboardSnapshot: Equatable, Sendable {
    public let changeCount: Int
    public let types: Set<String>
    public let text: String?
    public let sourceApp: String?
    public let sourceBundleID: String?

    public init(changeCount: Int, types: Set<String>, text: String?, sourceApp: String?, sourceBundleID: String? = nil) {
        self.changeCount = changeCount
        self.types = types
        self.text = text
        self.sourceApp = sourceApp
        self.sourceBundleID = sourceBundleID
    }
}
