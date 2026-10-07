import Foundation

/// Tells the user when a microphone or a camera is switched on by any process, from the system's own device
/// properties. It never opens a device and never names the app using it: the system does not say, and this module
/// does not guess.
///
/// Sayso's own dictation and Control listening are not a special case: they switch the microphone on, so they show
/// like any other app. The host may say Sayso is listening (`isSaysoCapturing`), and then a microphone line adds
/// that Sayso may be the one using it; the line is never hidden for it.
///
/// One line at most (`stackID`), ranked `.activeTask`: above ambient offers, media and clocks, so none of those can
/// hide it; below completion, failure and confirmation, so it never hides a finished timer, an error or an approval.
/// It ties with other active tasks in publish order, and Dismiss hides it, so it never sits over them for good.
///
/// Every read happens inside one scheduled job, so with a scheduler on its own queue the reads never run on the
/// caller's thread, the main thread or under the host lock.
public final class PrivacyGuardModule: SaysoModule, @unchecked Sendable {
    /// Between samples while a line shows or the Studio pane is watched.
    public static let watchedIntervalSeconds: TimeInterval = 2
    /// Between samples otherwise.
    public static let idleIntervalSeconds: TimeInterval = 5
    /// A device must read the other way on this many samples in a row before its state changes, so a brief probe
    /// never shows and a short gap never clears.
    public static let samplesToChange = 2
    /// After a failed read the system is left alone this long, watched or not.
    public static let failureBackoffSeconds: TimeInterval = 30
    /// At most one failure is reported in this window, the host's quarantine window, so reads that fail now and then
    /// mark the module degraded without ever quarantining it.
    public static let failureReportWindowSeconds: TimeInterval = 300
    /// Device names are cut to this many characters in the line.
    public static let nameLimit = 48
    public static let stackID = "privacy-guard"

    public let descriptor = SaysoModuleDescriptor(
        id: "privacy-guard", title: "Privacy", surfaces: [.compact, .expanded, .settings]
    )
    fileprivate let port: PrivacyDevicePort
    fileprivate let scheduler: SaysoScheduling
    fileprivate let now: @Sendable () -> Date
    fileprivate let isSaysoCapturing: @Sendable () -> Bool
    private let lock = NSLock()
    private var runtime: Runtime?
    private var watched = false

    public init(
        port: PrivacyDevicePort,
        scheduler: SaysoScheduling,
        now: @escaping @Sendable () -> Date = { Date() },
        isSaysoCapturing: @escaping @Sendable () -> Bool = { false }
    ) {
        self.port = port
        self.scheduler = scheduler
        self.now = now
        self.isSaysoCapturing = isSaysoCapturing
    }

    public func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        let runtime = Runtime(module: self, context: context)
        lock.withLock { self.runtime = runtime }
        return runtime
    }

    /// The latest read; nil while disabled, before the first read or after a failed one.
    public var snapshot: PrivacyGuardSnapshot? { current?.snapshot }

    /// Whether the Studio pane shows the rows. Kept across disable and enable: it describes the UI, not the runtime.
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

    /// `Microphone in use`, `Camera in use` or `Camera and microphone in use`, the device's name when exactly one is
    /// on, and the Sayso note when the microphone is on while Sayso listens.
    static func title(kinds: Set<PrivacyDeviceKind>, names: [String], saysoCapturing: Bool) -> String {
        var parts = [
            kinds == [.microphone] ? "Microphone in use" : kinds == [.camera] ? "Camera in use" : "Camera and microphone in use",
        ]
        if names.count == 1, let name = displayName(names[0]) { parts.append(name) }
        if saysoCapturing, kinds.contains(.microphone) { parts.append("Sayso may be the one using it") }
        return parts.joined(separator: " · ")
    }

    /// One line of text, at most `nameLimit` characters; nil when nothing readable is left.
    static func displayName(_ name: String) -> String? {
        let words = name.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard !words.isEmpty else { return nil }
        return words.count <= nameLimit ? words : String(words.prefix(nameLimit - 1)) + "…"
    }

    private struct DeviceKey: Hashable {
        let kind: PrivacyDeviceKind
        let id: String
    }

    /// One listed device and its debounced state.
    private struct Track {
        var name: String
        /// On, as far as the line and rows are concerned.
        var confirmed = false
        /// Samples in a row that read the other way.
        var streak = 0
    }

    fileprivate final class Runtime: SaysoModuleRuntime, SaysoResourceAccounting, @unchecked Sendable {
        private enum Effect {
            case show(String)
            case clear
        }

        unowned let module: PrivacyGuardModule
        let context: SaysoModuleContext
        private let lock = NSLock()
        private var running = false
        private var job: SaysoSubscription?
        /// Devices in the last successful list; one that leaves the list is forgotten at once.
        private var tracks: [DeviceKey: Track] = [:]
        private var latest: PrivacyGuardSnapshot?
        private var lastSampleAt: Date?
        /// Kinds on when the user dismissed the line; each leaves the set once it is off.
        private var hidden: Set<PrivacyDeviceKind> = []
        /// The line last published, so an unchanged line is never published again.
        private var shown: String?
        /// The last read failed, so the next read waits for the backoff.
        private var failing = false
        private var lastReport: Date?
        /// The next job reads even if a sample is not yet due: set on start and after a clock change.
        private var sampleNow = false
        /// A dismissal waits for the next job to clear the line.
        private var repaintNow = false

        init(module: PrivacyGuardModule, context: SaysoModuleContext) {
            self.module = module
            self.context = context
        }

        var retainedResources: Int { lock.withLock { job == nil ? 0 : 1 } }

        var snapshot: PrivacyGuardSnapshot? { lock.withLock { latest } }

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
                tracks = [:]
                latest = nil
                lastSampleAt = nil
                hidden = []
                shown = nil
                failing = false
                lastReport = nil
                sampleNow = false
                repaintNow = false
            }
            module.detach(self)
        }

        /// Only records the dismissal and asks for the job now: the job is the one place the line is published, so a
        /// dismiss can never land between a sample deciding to repaint the line and the repaint.
        func handle(stackID: String, actionID: String) {
            guard actionID == "dismiss", stackID == PrivacyGuardModule.stackID else { return }
            lock.withLock {
                guard running, shown != nil else { return }
                hidden = confirmedKinds
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

        /// The one job. Reads the devices, when a sample is due, outside the lock; folds the list in, works out the
        /// line and re-arms under it; then reports and publishes outside it: publishing takes the host lock, and the
        /// host calls into this runtime while holding that lock. A job that only repaints (after a dismiss) does not
        /// read.
        private func run() {
            guard let due = lock.withLock({ () -> Bool? in
                guard running else { return nil }
                defer { (sampleNow, repaintNow) = (false, false) }
                return sampleNow || lastSampleAt.map { module.now() >= $0.addingTimeInterval(interval) } ?? true
            }) else { return }
            let reading = due ? Result { () throws(PrivacyDevicePortError) in try module.port.devices() } : nil
            let saysoCapturing = module.isSaysoCapturing()
            let (effect, report) = lock.withLock { () -> (Effect?, Bool) in
                guard running else { return (nil, false) }
                let now = module.now()
                var report = false
                if let reading {
                    let wasFailing = failing
                    switch reading {
                    case let .success(devices):
                        fold(devices)
                        failing = false
                        latest = PrivacyGuardSnapshot(microphone: use(of: .microphone), camera: use(of: .camera), sampledAt: now)
                    case .failure:
                        // A failed read cannot vouch for anything, and it breaks every streak; what was confirmed
                        // and dismissed is kept for the next good read.
                        for key in tracks.keys { tracks[key]?.streak = 0 }
                        failing = true
                        latest = nil
                    }
                    // A run of failed reads is one failure: a lasting fault is reported once, not on every sample.
                    report = failing && !wasFailing && shouldReport(at: now)
                    lastSampleAt = now
                }
                let effect = lineChange(saysoCapturing: saysoCapturing)
                rearm(at: now)
                return (effect, report)
            }
            if report { context.reportFailure() }
            switch effect {
            case let .show(title)?:
                context.publish(
                    stackID: PrivacyGuardModule.stackID, kind: .activeTask, title: title,
                    actions: [SaysoAction(id: "dismiss", title: "Dismiss")]
                )
            case .clear?:
                context.dismiss(stackID: PrivacyGuardModule.stackID)
            case nil:
                break
            }
        }

        /// A device changes state only after reading the other way on `samplesToChange` samples in a row. A device
        /// that is no longer listed is dropped, so nothing waits on a device that is gone. Call with the lock held.
        private func fold(_ devices: [PrivacyDevice]) {
            var next: [DeviceKey: Track] = [:]
            for device in devices {
                let key = DeviceKey(kind: device.kind, id: device.id)
                var track = tracks[key] ?? Track(name: device.name)
                track.name = device.name
                if device.isRunning == track.confirmed {
                    track.streak = 0
                } else {
                    track.streak += 1
                    if track.streak >= PrivacyGuardModule.samplesToChange {
                        track.confirmed = device.isRunning
                        track.streak = 0
                    }
                }
                next[key] = track
            }
            tracks = next
            // A kind that is off is no longer dismissed, so it shows again the next time it comes on.
            hidden.formIntersection(confirmedKinds)
        }

        private var confirmedKinds: Set<PrivacyDeviceKind> {
            Set(tracks.filter { $0.value.confirmed }.map(\.key.kind))
        }

        /// Call with the lock held.
        private func use(of kind: PrivacyDeviceKind) -> PrivacyDeviceUse {
            let ofKind = tracks.filter { $0.key.kind == kind }
            if ofKind.isEmpty { return .noneFound }
            return ofKind.contains { $0.value.confirmed } ? .inUse : .notInUse
        }

        /// The line, if it differs from what was last published. Call with the lock held.
        private func lineChange(saysoCapturing: Bool) -> Effect? {
            let kinds = confirmedKinds
            var title: String?
            if latest != nil, !kinds.isEmpty, !kinds.isSubset(of: hidden) {
                let names = tracks.values.filter(\.confirmed).map(\.name)
                title = PrivacyGuardModule.title(kinds: kinds, names: names, saysoCapturing: saysoCapturing)
            }
            guard title != shown else { return nil }
            shown = title
            return title.map { .show($0) } ?? .clear
        }

        /// At most one report per window. Call with the lock held.
        private func shouldReport(at now: Date) -> Bool {
            if let lastReport, now.timeIntervalSince(lastReport) < PrivacyGuardModule.failureReportWindowSeconds { return false }
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
            failing ? PrivacyGuardModule.failureBackoffSeconds
                : shown != nil || module.isWatched ? PrivacyGuardModule.watchedIntervalSeconds
                : PrivacyGuardModule.idleIntervalSeconds
        }
    }
}
