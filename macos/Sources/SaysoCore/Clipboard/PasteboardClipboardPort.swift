import AppKit

/// NSPasteboard adapter. Not wired into the app yet; reads are cheap `changeCount` checks plus one snapshot per change.
public struct PasteboardClipboardPort: ClipboardPort, @unchecked Sendable {
    // ponytail: NSPasteboard is thread-safe for these calls; revisit if the module ever polls off the main queue.
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    public var changeCount: Int { pasteboard.changeCount }

    /// Reads count, types and text as one consistent view: if the board changes mid-read the read is retried.
    public func snapshot() -> ClipboardSnapshot {
        var result = read()
        for _ in 0..<2 where result.changeCount != pasteboard.changeCount { result = read() }
        return result
    }

    private func read() -> ClipboardSnapshot {
        let count = pasteboard.changeCount
        let front = NSWorkspace.shared.frontmostApplication
        return ClipboardSnapshot(
            changeCount: count,
            types: Set((pasteboard.types ?? []).map(\.rawValue)),
            text: pasteboard.string(forType: .string),
            sourceApp: front?.localizedName,
            sourceBundleID: front?.bundleIdentifier
        )
    }

    public func captureContents() -> ClipboardContents {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type -> ClipboardRepresentation? in
                item.data(forType: type).map { ClipboardRepresentation(type: type.rawValue, data: $0) }
            }
        }
        return ClipboardContents(changeCount: pasteboard.changeCount, items: items.filter { !$0.isEmpty })
    }

    @discardableResult
    public func restore(_ contents: ClipboardContents) -> Bool {
        pasteboard.clearContents()
        guard !contents.items.isEmpty else { return true }
        let items = contents.items.map { representations -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for representation in representations {
                item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
            }
            return item
        }
        return pasteboard.writeObjects(items)
    }

    public func clear() { pasteboard.clearContents() }

    @discardableResult
    public func write(text: String, concealed: Bool) -> Bool {
        pasteboard.clearContents()
        var ok = pasteboard.setString(text, forType: .string)
        if concealed {
            ok = pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) && ok
        }
        return ok
    }
}
