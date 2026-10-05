import Foundation

/// Who is looking at the stats; while anyone is, samples come faster.
public enum SystemStatsViewer: Hashable, Sendable {
    case studio
    case notch
}

/// Read-only CPU, memory, battery and disk figures, sampled by one scheduled job.
///
/// Every read of the machine happens inside that job, so with a scheduler on its own queue the reads never run on
/// the caller's thread, the main thread or under the host lock.
public final class SystemStatsModule: SaysoModule, @unchecked Sendable {
    /// Between samples while the Studio pane or the open notch shows the stats.
    public static let observedIntervalSeconds: TimeInterval = 5
    /// Between samples while nobody looks.
    public static let idleIntervalSeconds: TimeInterval = 60

    public let descriptor = SaysoModuleDescriptor(
        id: "system-stats", title: "System", surfaces: [.compact, .expanded, .settings]
    )
    fileprivate let port: SystemStatsPort
    fileprivate let scheduler: SaysoScheduling
    fileprivate let now: @Sendable () -> Date
    private let lock = NSLock()
    private var runtime: Runtime?
    private var viewers: Set<SystemStatsViewer> = []

    public init(port: SystemStatsPort, scheduler: SaysoScheduling, now: @escaping @Sendable () -> Date = { Date() }) {
        self.port = port
        self.scheduler = scheduler
        self.now = now
    }

    public func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        let runtime = Runtime(module: self, context: context)
        lock.withLock { self.runtime = runtime }
        return runtime
    }

    /// The latest sample; nil while disabled or before the first sample.
    public var snapshot: SystemStatsSnapshot? { current?.snapshot }

    /// Kept across disable and enable: it describes the UI, not the runtime.
    public func setObserved(_ viewer: SystemStatsViewer, _ observed: Bool) {
        let changed = lock.withLock { observed ? viewers.insert(viewer).inserted : viewers.remove(viewer) != nil }
        if changed { current?.cadenceChanged() }
    }

    public func clockChanged() {}

    fileprivate var isObserved: Bool { lock.withLock { !viewers.isEmpty } }

    private var current: Runtime? { lock.withLock { runtime } }

    /// Forgets a stopped runtime so later calls are refused instead of reaching a dead runtime.
    fileprivate func detach(_ stopped: Runtime) {
        lock.withLock { if runtime === stopped { runtime = nil } }
    }

    /// Busy share of the ticks between two readings. Wrapping subtraction keeps a counter that passed
    /// `UInt32.max` right; no ticks at all gives nil, never a made-up number.
    static func cpuLoad(from previous: SystemCPUTicks, to current: SystemCPUTicks) -> Double? {
        let busy = UInt64(current.user &- previous.user) + UInt64(current.system &- previous.system)
            + UInt64(current.nice &- previous.nice)
        let total = busy + UInt64(current.idle &- previous.idle)
        guard total > 0 else { return nil }
        return Double(busy) / Double(total)
    }

    fileprivate final class Runtime: SaysoModuleRuntime, SaysoResourceAccounting, @unchecked Sendable {
        unowned let module: SystemStatsModule
        let context: SaysoModuleContext
        private let lock = NSLock()
        private var running = false
        private var job: SaysoSubscription?
        private var latest: SystemStatsSnapshot?
        private var lastTicks: SystemCPUTicks?
        private var lastSampleAt: Date?

        init(module: SystemStatsModule, context: SaysoModuleContext) {
            self.module = module
            self.context = context
        }

        var retainedResources: Int { lock.withLock { job == nil ? 0 : 1 } }

        var snapshot: SystemStatsSnapshot? { lock.withLock { latest } }

        /// The first sample is a scheduled job, so turning the module on never waits on a read.
        func start() {
            lock.withLock {
                running = true
                rearm(at: module.now(), soon: true)
            }
        }

        func stop() {
            lock.withLock {
                running = false
                job?.cancel()
                job = nil
                latest = nil
                lastTicks = nil
                lastSampleAt = nil
            }
            module.detach(self)
        }

        func cadenceChanged() {
            lock.withLock {
                guard running else { return }
                rearm(at: module.now())
            }
        }

        /// Reads the machine outside the lock, then folds the reading in.
        private func sample() {
            guard lock.withLock({ running }) else { return }
            let reading = Result { () throws(SystemStatsPortError) in try module.port.read() }
            lock.withLock {
                guard running else { return }
                let now = module.now()
                if case let .success(reading) = reading {
                    latest = SystemStatsSnapshot(
                        cpuLoad: lastTicks.flatMap { SystemStatsModule.cpuLoad(from: $0, to: reading.cpuTicks) },
                        memoryUsedFraction: reading.memoryUsedFraction,
                        memoryPressure: reading.memoryPressure,
                        batteryFraction: reading.batteryFraction,
                        isPluggedIn: reading.isPluggedIn,
                        diskFreeBytes: reading.diskFreeBytes,
                        sampledAt: now
                    )
                    lastTicks = reading.cpuTicks
                } else {
                    latest = nil
                }
                lastSampleAt = now
                rearm(at: now)
            }
        }

        /// One job: due one interval after the last sample, at once if that is already past (`soon` forces now).
        /// None for a non-finite clock, which a real timer would fire at once. Call with the lock held.
        private func rearm(at now: Date, soon: Bool = false) {
            job?.cancel()
            job = nil
            guard running, now.timeIntervalSince1970.isFinite else { return }
            let interval = module.isObserved ? SystemStatsModule.observedIntervalSeconds : SystemStatsModule.idleIntervalSeconds
            let due = soon ? now : max(now, lastSampleAt.map { $0.addingTimeInterval(interval) } ?? now)
            job = module.scheduler.schedule(at: due) { [weak self] in self?.sample() }
        }
    }
}
