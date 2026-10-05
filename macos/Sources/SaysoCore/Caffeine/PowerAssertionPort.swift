import Foundation

/// A held power assertion that keeps the Mac awake until released.
public final class PowerAssertion: @unchecked Sendable {
    private let lock = NSLock()
    private var onRelease: (@Sendable () -> Void)?

    public init(_ onRelease: @escaping @Sendable () -> Void) { self.onRelease = onRelease }

    /// Safe to call more than once; only the first call releases.
    public func release() {
        let work = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { onRelease = nil }
            return onRelease
        }
        work?()
    }

    deinit { release() }
}

/// Boundary to the system power manager; the macOS adapter owns IOKit.
public protocol PowerAssertionPort: Sendable {
    /// Nil when the system refuses the assertion; nothing is held then.
    func createAssertion(named name: String) -> PowerAssertion?
}
