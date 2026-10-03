import Foundation

/// One-shot timers, injected so expiry is deterministic in tests.
public protocol SaysoScheduling: Sendable {
    /// Runs `action` once at `date`; cancelling the subscription cancels the job.
    func schedule(at date: Date, _ action: @escaping @Sendable () -> Void) -> SaysoSubscription
}

/// Keeps at most one timer, armed only while some activity will expire; no polling when idle.
public final class SaysoExpiryTicker: @unchecked Sendable {
    private let host: SaysoModuleHost
    private let scheduler: SaysoScheduling
    private let lock = NSRecursiveLock()
    private var job: SaysoSubscription?
    private var scheduledFor: Date?

    public init(host: SaysoModuleHost, scheduler: SaysoScheduling) {
        self.host = host
        self.scheduler = scheduler
        let previous = host.onActivitiesChanged
        host.onActivitiesChanged = { [weak self] in
            previous?()
            self?.reschedule()
        }
    }

    private func reschedule() {
        lock.lock()
        defer { lock.unlock() }
        let next = host.nextExpiry
        guard next != scheduledFor else { return }
        job?.cancel()
        job = nil
        scheduledFor = next
        guard let next else { return }
        job = scheduler.schedule(at: next) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.job = nil
            self.scheduledFor = nil
            self.lock.unlock()
            self.host.tick()
        }
    }
}
