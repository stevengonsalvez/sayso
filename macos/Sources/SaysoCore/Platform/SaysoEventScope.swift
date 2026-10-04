import Foundation

/// One runtime's view of the bus: tracks its subscriptions and goes inert when the runtime stops.
public final class SaysoEventScope: @unchecked Sendable {
    private let bus: SaysoEventBus
    private let lock = NSLock()
    private var subscriptions: [SaysoSubscription] = []
    private var active = true

    public init(bus: SaysoEventBus) { self.bus = bus }

    public func emit<E: SaysoEvent>(_ event: E) {
        lock.lock()
        let isActive = active
        lock.unlock()
        if isActive { bus.publish(event) }
    }

    @discardableResult
    public func subscribe<E: SaysoEvent>(_ type: E.Type, handler: @escaping @Sendable (E) -> Void) -> SaysoSubscription? {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return nil }
        let subscription = bus.subscribe(type, handler: handler)
        subscriptions.append(subscription)
        return subscription
    }

    /// Cancels every subscription and ignores later emits and subscribes.
    public func close() {
        lock.lock()
        active = false
        let pending = subscriptions
        subscriptions = []
        lock.unlock()
        pending.forEach { $0.cancel() }
    }
}
