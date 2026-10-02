import AppKit

/// NSPasteboard adapter. Not wired into the app yet; reads are cheap `changeCount` checks plus one snapshot per change.
public struct PasteboardClipboardPort: ClipboardPort, @unchecked Sendable {
    // ponytail: NSPasteboard is thread-safe for these calls; revisit if the module ever polls off the main queue.
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    public var changeCount: Int { pasteboard.changeCount }

    public func snapshot() -> ClipboardSnapshot {
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        return ClipboardSnapshot(
            changeCount: pasteboard.changeCount,
            types: types,
            text: pasteboard.string(forType: .string),
            sourceApp: NSWorkspace.shared.frontmostApplication?.localizedName
        )
    }

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
