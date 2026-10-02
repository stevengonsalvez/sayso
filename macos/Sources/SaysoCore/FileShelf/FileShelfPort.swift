import Foundation

public struct FileShelfFile: Equatable, Sendable {
    public let name: String
    public let byteCount: Int64
    public let isDirectory: Bool
    public init(name: String, byteCount: Int64, isDirectory: Bool) {
        self.name = name
        self.byteCount = byteCount
        self.isDirectory = isDirectory
    }
}

/// Holds the right to read a staged file (a security-scoped grant in the real adapter) until released.
public final class FileShelfAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var onRelease: (@Sendable () -> Void)?

    public init(_ onRelease: @escaping @Sendable () -> Void) { self.onRelease = onRelease }

    /// Safe to call more than once.
    public func release() {
        let work = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { onRelease = nil }
            return onRelease
        }
        work?()
    }

    deinit { release() }
}

/// Boundary to the file system and Finder; the app adapter owns security scope and NSWorkspace.
public protocol FileShelfPort: Sendable {
    /// Attributes of an existing file or folder, nil when it is gone.
    func resolve(_ url: URL) -> FileShelfFile?
    /// nil when the system will not grant access; the file is then not staged.
    func acquire(_ url: URL) -> FileShelfAccess?
    func open(_ url: URL)
    func reveal(_ url: URL)
}
