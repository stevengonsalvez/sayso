import Foundation

/// One pasteboard flavour of one item, kept verbatim so a restore returns exactly what the user had.
public struct ClipboardRepresentation: Equatable, Sendable {
    public let type: String
    public let data: Data
    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

/// Every item and flavour on the pasteboard (images, file URLs, rich text, marker types), not just text.
public struct ClipboardContents: Equatable, Sendable {
    public let changeCount: Int
    public let items: [[ClipboardRepresentation]]

    public init(changeCount: Int, items: [[ClipboardRepresentation]]) {
        self.changeCount = changeCount
        self.items = items
    }

    public var types: Set<String> { Set(items.flatMap { $0.map(\.type) }) }
}
