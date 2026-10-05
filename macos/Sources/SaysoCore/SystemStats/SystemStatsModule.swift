import Foundation

/// Who is looking at the stats; while anyone is, samples come faster.
public enum SystemStatsViewer: Hashable, Sendable {
    case studio
    case notch
}

/// Read-only CPU, memory, battery and disk figures, sampled by one scheduled job. A notch line appears only while
/// something is notable (see `SystemStatsAlert`), never as a permanent line.
///
/// Every read of the machine happens inside that job, so with a scheduler on its own queue the reads never run on
/// the caller's thread, the main thread or under the host lock.
public final class SystemStatsModule: SaysoModule, @unchecked Sendable {
    /// Between samples while the Studio pane or the open notch shows the stats.
    public static let observedIntervalSeconds: TimeInterval = 5
    /// Between samples while nobody looks.
    public static let idleIntervalSeconds: TimeInterval = 60
    /// After a failed read the machine is left alone this long, observed or not.
    public static let failureBackoffSeconds: TimeInterval = 60
    /// At most one failure is reported in this window, the host's quarantine window, so reads that fail now and
    /// then mark the module degraded without ever quarantining it.
    public static let failureReportWindowSeconds: TimeInterval = 300

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

    /// Call after the system clock changes or the Mac wakes: the pending sample was set against the old time.
    public func clockChanged() { current?.clockChanged() }

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
        private enum Effect {
            case show(SystemStatsAlert, String)
            case clear(SystemStatsAlert)
        }

        unowned let module: SystemStatsModule
        let context: SaysoModuleContext
        private let lock = NSLock()
        private var running = false
        private var job: SaysoSubscription?
        private var latest: SystemStatsSnapshot?
        private var lastTicks: SystemCPUTicks?
        private var lastSampleAt: Date?
        /// Conditions entered and not yet cleared; kept across a failed read, which cannot say they cleared.
        private var active: Set<SystemStatsAlert> = []
        /// Dismissed from the notch; each stays hidden until its condition clears.
        private var hidden: Set<SystemStatsAlert> = []
        /// The lines last published, so an unchanged line is never published again.
        private var shown: [SystemStatsAlert: String] = [:]
        /// The last read failed, so the next read waits for the backoff.
        private var failing = false
        private var lastReport: Date?
        /// The next job reads the machine even if a sample is not yet due: set on start and after a clock change.
        private var sampleNow = false

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
                sampleNow = true
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
                active = []
                hidden = []
                shown = [:]
                failing = false
                lastReport = nil
                sampleNow = false
            }
            module.detach(self)
        }

        /// Only records the dismissal and asks for the job now: the job is the one place lines are published, so a
        /// dismiss can never land between a sample deciding to repaint a line and the repaint.
        func handle(stackID: String, actionID: String) {
            guard actionID == "dismiss", let alert = SystemStatsAlert(stackID: stackID) else { return }
            lock.withLock {
                guard running, shown[alert] != nil else { return }
                hidden.insert(alert)
                rearm(at: module.now(), soon: true)
            }
        }

        /// Samples at once and pulls times recorded against the old clock back to the new one.
        func clockChanged() {
            lock.withLock {
                guard running else { return }
                let now = module.now()
                lastSampleAt = lastSampleAt.map { min($0, now) }
                lastReport = lastReport.map { min($0, now) }
                sampleNow = true
                rearm(at: now, soon: true)
            }
        }

        func cadenceChanged() {
            lock.withLock {
                guard running else { return }
                rearm(at: module.now())
            }
        }

        /// The one job. Reads the machine, when a sample is due, outside the lock; folds the reading in, works out
        /// the lines and re-arms under it; then reports and publishes outside it: publishing takes the host lock, and
        /// the host calls into this runtime while holding that lock. A job that only repaints (after a dismiss) does
        /// not read, so the CPU load is never taken over a few milliseconds.
        private func run() {
            guard let due = lock.withLock({ () -> Bool? in
                guard running else { return nil }
                defer { sampleNow = false }
                return sampleNow || lastSampleAt.map { module.now() >= $0.addingTimeInterval(interval) } ?? true
            }) else { return }
            let reading = due ? Result { () throws(SystemStatsPortError) in try module.port.read() } : nil
            let (effects, report) = lock.withLock { () -> ([Effect], Bool) in
                guard running else { return ([], false) }
                let now = module.now()
                guard let reading else {
                    rearm(at: now)
                    return (lineChanges(), false)
                }
                let wasFailing = failing
                switch reading {
                case let .success(reading):
                    let stats = SystemStatsSnapshot(
                        cpuLoad: lastTicks.flatMap { SystemStatsModule.cpuLoad(from: $0, to: reading.cpuTicks) },
                        memoryUsedFraction: reading.memoryUsedFraction,
                        memoryPressure: reading.memoryPressure,
                        batteryFraction: reading.batteryFraction,
                        isPluggedIn: reading.isPluggedIn,
                        diskFreeBytes: reading.diskFreeBytes,
                        sampledAt: now
                    )
                    latest = stats
                    lastTicks = reading.cpuTicks
                    failing = false
                    updateAlerts(stats)
                case .failure:
                    // Old figures and lines cannot be vouched for; the entered conditions and dismissals are kept.
                    latest = nil
                    failing = true
                }
                // A run of failed reads is one failure: a lasting fault is reported once, not on every sample.
                let report = failing && !wasFailing && shouldReport(at: now)
                lastSampleAt = now
                rearm(at: now)
                return (lineChanges(), report)
            }
            if report { context.reportFailure() }
            for effect in effects {
                switch effect {
                case let .show(alert, title):
                    context.publish(
                        stackID: alert.stackID, kind: .ambient, title: title,
                        actions: [SaysoAction(id: "dismiss", title: "Dismiss")]
                    )
                case let .clear(alert):
                    context.dismiss(stackID: alert.stackID)
                }
            }
        }

        /// Call with the lock held.
        private func updateAlerts(_ stats: SystemStatsSnapshot) {
            for alert in SystemStatsAlert.allCases {
                switch alert.verdict(for: stats) {
                case true?: active.insert(alert)
                case false?:
                    active.remove(alert)
                    hidden.remove(alert)
                case nil: break
                }
            }
        }

        /// The lines that differ from what was last published. Call with the lock held.
        private func lineChanges() -> [Effect] {
            var effects: [Effect] = []
            for alert in SystemStatsAlert.allCases {
                let title = latest.flatMap { active.contains(alert) && !hidden.contains(alert) ? alert.title(for: $0) : nil }
                guard title != shown[alert] else { continue }
                shown[alert] = title
                effects.append(title.map { .show(alert, $0) } ?? .clear(alert))
            }
            return effects
        }

        /// At most one report per window. Call with the lock held.
        private func shouldReport(at now: Date) -> Bool {
            if let lastReport, now.timeIntervalSince(lastReport) < SystemStatsModule.failureReportWindowSeconds { return false }
            lastReport = now
            return true
        }

        /// One job: due one interval after the last sample, at once if that is already past (`soon` forces now).
        /// None for a non-finite clock, which a real timer would fire at once. Call with the lock held.
        private func rearm(at now: Date, soon: Bool = false) {
            job?.cancel()
            job = nil
            guard running, now.timeIntervalSince1970.isFinite else { return }
            let due = soon ? now : max(now, lastSampleAt.map { $0.addingTimeInterval(interval) } ?? now)
            job = module.scheduler.schedule(at: due) { [weak self] in self?.run() }
        }

        /// Between samples now. Call with the lock held.
        private var interval: TimeInterval {
            failing ? SystemStatsModule.failureBackoffSeconds
                : module.isObserved ? SystemStatsModule.observedIntervalSeconds : SystemStatsModule.idleIntervalSeconds
        }
    }
}
