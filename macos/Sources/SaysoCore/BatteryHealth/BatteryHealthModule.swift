import Foundation

/// Read-only health of this Mac's battery (capacity against design, cycles, temperature, power) and the level of any
/// other battery the system reports, sampled by one scheduled job. A notch line appears only while the battery is
/// worn (health below 60%) or hot (45 °C and above), never as a permanent line.
///
/// Lines rank `.ambient`, like System stats lines: worth a glance, not an interruption. Every higher kind (active
/// task, completion, failure, confirmation) is drawn over them, so they can never hide a running timer, the privacy
/// line, a notice or an approval; they tie with other ambient offers in publish order and Dismiss removes them.
///
/// Every read happens inside the job, so with a scheduler on its own queue the reads never run on the caller's
/// thread, the main thread or under the host lock.
public final class BatteryHealthModule: SaysoModule, @unchecked Sendable {
    /// Between samples while the Studio pane shows the battery.
    public static let observedIntervalSeconds: TimeInterval = 10
    /// Between samples otherwise: health and cycles move over weeks, temperature over minutes.
    public static let idleIntervalSeconds: TimeInterval = 60
    /// After a failed read the registry is left alone this long, watched or not.
    public static let failureBackoffSeconds: TimeInterval = 120
    /// At most one failure is reported in this window, the host's quarantine window, so reads that fail now and then
    /// mark the module degraded without ever quarantining it.
    public static let failureReportWindowSeconds: TimeInterval = 300
    /// A worn line clears once health reads at least this again.
    public static let wornRecoveredPercent = BatteryHealthAlert.wornRecoveredPercent
    public static let wornStackID = BatteryHealthAlert.worn.stackID
    public static let hotStackID = BatteryHealthAlert.hot.stackID

    public let descriptor = SaysoModuleDescriptor(
        id: "battery-health", title: "Battery", surfaces: [.compact, .expanded, .settings]
    )
    fileprivate let port: BatteryHealthPort
    fileprivate let scheduler: SaysoScheduling
    fileprivate let now: @Sendable () -> Date
    private let lock = NSLock()
    private var runtime: Runtime?
    private var watched = false

    public init(port: BatteryHealthPort, scheduler: SaysoScheduling, now: @escaping @Sendable () -> Date = { Date() }) {
        self.port = port
        self.scheduler = scheduler
        self.now = now
    }

    public func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        let runtime = Runtime(module: self, context: context)
        lock.withLock { self.runtime = runtime }
        return runtime
    }

    /// The latest read; nil while disabled, before the first read or after a failed one. Its `battery` is nil on a
    /// Mac with no battery.
    public var snapshot: BatteryHealthSnapshot? { current?.snapshot }

    /// Whether the Studio pane shows the battery. Kept across disable and enable: it describes the UI, not the runtime.
    public func setObserved(_ observed: Bool) {
        let changed = lock.withLock { () -> Bool in
            defer { watched = observed }
            return watched != observed
        }
        if changed { current?.cadenceChanged() }
    }

    /// Call after the system clock changes: the pending sample was set against the old time.
    public func clockChanged() { current?.clockChanged() }

    fileprivate var isWatched: Bool { lock.withLock { watched } }

    private var current: Runtime? { lock.withLock { runtime } }

    /// Forgets a stopped runtime so later calls are refused instead of reaching a dead runtime.
    fileprivate func detach(_ stopped: Runtime) {
        lock.withLock { if runtime === stopped { runtime = nil } }
    }

    fileprivate final class Runtime: SaysoModuleRuntime, SaysoResourceAccounting, @unchecked Sendable {
        private enum Effect {
            case show(BatteryHealthAlert, String)
            case clear(BatteryHealthAlert)
        }

        unowned let module: BatteryHealthModule
        let context: SaysoModuleContext
        private let lock = NSLock()
        private var running = false
        private var job: SaysoSubscription?
        private var latest: BatteryHealthSnapshot?
        private var lastSampleAt: Date?
        /// Conditions entered and not yet cleared; kept across a failed read, which cannot say they cleared.
        private var active: Set<BatteryHealthAlert> = []
        /// Dismissed from the notch. Hot stays hidden until it cools; worn until it clears or reads worse.
        private var hidden: Set<BatteryHealthAlert> = []
        /// Health when the worn line was dismissed; only a lower figure brings it back, so a one point wobble never does.
        private var wornDismissedAt: Int?
        /// The lines last published, so an unchanged line is never published again.
        private var shown: [BatteryHealthAlert: String] = [:]
        /// The last read failed, so the next read waits for the backoff.
        private var failing = false
        private var lastReport: Date?
        /// The next job reads even if a sample is not yet due: set on start and after a clock change.
        private var sampleNow = false
        /// A dismissal waits for the next job to clear its line.
        private var repaintNow = false

        init(module: BatteryHealthModule, context: SaysoModuleContext) {
            self.module = module
            self.context = context
        }

        var retainedResources: Int { lock.withLock { job == nil ? 0 : 1 } }

        var snapshot: BatteryHealthSnapshot? { lock.withLock { latest } }

        /// The first sample is a scheduled job, so turning the module on never waits on a read.
        func start() {
            lock.withLock {
                running = true
                sampleNow = true
                rearm(at: module.now())
            }
        }

        func stop() {
            lock.withLock {
                running = false
                job?.cancel()
                job = nil
                latest = nil
                lastSampleAt = nil
                active = []
                hidden = []
                wornDismissedAt = nil
                shown = [:]
                failing = false
                lastReport = nil
                sampleNow = false
                repaintNow = false
            }
            module.detach(self)
        }

        /// Only records the dismissal and asks for the job now: the job is the one place lines are published, so a
        /// dismiss can never land between a sample deciding to repaint a line and the repaint.
        func handle(stackID: String, actionID: String) {
            guard actionID == "dismiss", let alert = BatteryHealthAlert(stackID: stackID) else { return }
            lock.withLock {
                guard running, shown[alert] != nil else { return }
                hidden.insert(alert)
                if alert == .worn { wornDismissedAt = latest?.healthPercent }
                repaintNow = true
                rearm(at: module.now())
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
                rearm(at: now)
            }
        }

        func cadenceChanged() {
            lock.withLock {
                guard running else { return }
                rearm(at: module.now())
            }
        }

        /// The one job. Reads the registry, when a sample is due, outside the lock; folds the reading in, works out
        /// the lines and re-arms under it; then reports and publishes outside it: publishing takes the host lock, and
        /// the host calls into this runtime while holding that lock. A job that only repaints (after a dismiss) does
        /// not read.
        private func run() {
            guard let due = lock.withLock({ () -> Bool? in
                guard running else { return nil }
                defer { (sampleNow, repaintNow) = (false, false) }
                return sampleNow || lastSampleAt.map { module.now() >= $0.addingTimeInterval(interval) } ?? true
            }) else { return }
            let reading = due ? Result { () throws(BatteryHealthPortError) in try module.port.read() } : nil
            let (effects, report) = lock.withLock { () -> ([Effect], Bool) in
                guard running else { return ([], false) }
                let now = module.now()
                var report = false
                if let reading {
                    let wasFailing = failing
                    switch reading {
                    case let .success(reading):
                        let snapshot = BatteryHealthSnapshot(battery: reading.battery, devices: reading.devices, sampledAt: now)
                        latest = snapshot
                        failing = false
                        updateAlerts(snapshot)
                    case .failure:
                        // Old figures and lines cannot be vouched for; the entered conditions and dismissals are kept.
                        latest = nil
                        failing = true
                    }
                    // A run of failed reads is one failure: a lasting fault is reported once, not on every sample.
                    report = failing && !wasFailing && shouldReport(at: now)
                    lastSampleAt = now
                }
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
        private func updateAlerts(_ snapshot: BatteryHealthSnapshot) {
            for alert in BatteryHealthAlert.allCases {
                switch alert.verdict(for: snapshot) {
                case true?: active.insert(alert)
                case false?:
                    active.remove(alert)
                    hidden.remove(alert)
                case nil: break
                }
            }
            if !hidden.contains(.worn) {
                wornDismissedAt = nil
            } else if let percent = snapshot.healthPercent, let dismissedAt = wornDismissedAt, percent < dismissedAt {
                hidden.remove(.worn)
                wornDismissedAt = nil
            }
        }

        /// The lines that differ from what was last published. Call with the lock held.
        private func lineChanges() -> [Effect] {
            var effects: [Effect] = []
            for alert in BatteryHealthAlert.allCases {
                let title = latest.flatMap { active.contains(alert) && !hidden.contains(alert) ? alert.title(for: $0) : nil }
                guard title != shown[alert] else { continue }
                shown[alert] = title
                effects.append(title.map { .show(alert, $0) } ?? .clear(alert))
            }
            return effects
        }

        /// At most one report per window. Call with the lock held.
        private func shouldReport(at now: Date) -> Bool {
            if let lastReport, now.timeIntervalSince(lastReport) < BatteryHealthModule.failureReportWindowSeconds { return false }
            lastReport = now
            return true
        }

        /// One job: at once while a forced sample or a dismissal waits, so no later re-arm can push either back;
        /// otherwise one interval after the last sample, or at once if that is already past. None for a non-finite
        /// clock, which a real timer would fire at once. Call with the lock held.
        private func rearm(at now: Date) {
            job?.cancel()
            job = nil
            guard running, now.timeIntervalSince1970.isFinite else { return }
            let due = sampleNow || repaintNow ? now : max(now, lastSampleAt.map { $0.addingTimeInterval(interval) } ?? now)
            job = module.scheduler.schedule(at: due) { [weak self] in self?.run() }
        }

        /// Between samples now. Call with the lock held.
        private var interval: TimeInterval {
            failing ? BatteryHealthModule.failureBackoffSeconds
                : module.isWatched ? BatteryHealthModule.observedIntervalSeconds : BatteryHealthModule.idleIntervalSeconds
        }
    }
}
