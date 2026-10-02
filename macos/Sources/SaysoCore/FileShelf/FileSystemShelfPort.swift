import AppKit

/// FileManager and NSWorkspace adapter for the shelf. Staged files are referenced in place, not copied.
// ponytail: FileManager.default is documented thread-safe for these calls; custom managers must be too.
public struct FileSystemShelfPort: FileShelfPort, @unchecked Sendable {
    private let fileManager: FileManager
    private let openHandler: @Sendable (URL) -> Void
    private let revealHandler: @Sendable (URL) -> Void

    public init(
        fileManager: FileManager = .default,
        open: @escaping @Sendable (URL) -> Void = { NSWorkspace.shared.open($0) },
        reveal: @escaping @Sendable (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    ) {
        self.fileManager = fileManager
        self.openHandler = open
        self.revealHandler = reveal
    }

    public func resolve(_ url: URL) -> FileShelfFile? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return FileShelfFile(name: url.lastPathComponent, byteCount: size, isDirectory: isDirectory.boolValue)
    }

    /// Takes a security-scoped grant when the URL carries one; plain URLs are accepted only if readable.
    public func acquire(_ url: URL) -> FileShelfAccess? {
        let scoped = url.startAccessingSecurityScopedResource()
        guard fileManager.isReadableFile(atPath: url.path) else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            return nil
        }
        return FileShelfAccess { if scoped { url.stopAccessingSecurityScopedResource() } }
    }

    public func open(_ url: URL) { openHandler(url) }

    public func reveal(_ url: URL) { revealHandler(url) }
}
