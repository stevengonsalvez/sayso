import Foundation

/// Typed platform event; feature modules coordinate only through these, never by importing each other.
public protocol SaysoEvent: Sendable {}

public final class SaysoSubscription: @unchecked Sendable {
    private let onCancel: @Sendable () -> Void
    private let lock = NSLock()
    private var cancelled = false

    init(onCancel: @escaping @Sendable () -> Void) { self.onCancel = onCancel }

    /// Safe to call more than once.
    public func cancel() {
        lock.lock()
        let first = !cancelled
        cancelled = true
        lock.unlock()
        if first { onCancel() }
    }
}

/// Synchronous in-process bus; handlers run on the publishing thread in subscription order.
public final class SaysoEventBus: @unchecked Sendable {
    private struct Entry {
        let token: UInt64
        let type: ObjectIdentifier
        let handler: (any SaysoEvent) -> Void
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var nextToken: UInt64 = 0

    public init() {}

    public var subscriberCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    public func subscribe<E: SaysoEvent>(_ type: E.Type, handler: @escaping @Sendable (E) -> Void) -> SaysoSubscription {
        lock.lock()
        nextToken += 1
        let token = nextToken
        entries.append(Entry(token: token, type: ObjectIdentifier(type)) { event in
            if let event = event as? E { handler(event) }
        })
        lock.unlock()
        return SaysoSubscription { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.entries.removeAll { $0.token == token }
            self.lock.unlock()
        }
    }

    public func publish<E: SaysoEvent>(_ event: E) {
        lock.lock()
        let targets = entries.filter { $0.type == ObjectIdentifier(E.self) }
        lock.unlock()
        for target in targets { target.handler(event) }
    }
}
