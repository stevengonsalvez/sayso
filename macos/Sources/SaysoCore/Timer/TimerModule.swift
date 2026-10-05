import Foundation

/// Handle for one running countdown.
public struct TimerID: Hashable, Sendable {
    private let raw = UUID()

    public init() {}

    var stackID: String { "timer-\(raw.uuidString)" }
}

public struct TimerSnapshot: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case countdown(duration: TimeInterval)
    }

    public let id: TimerID
    public let kind: Kind
    public let elapsed: TimeInterval
    public let remaining: TimeInterval?
    public let isPaused: Bool
}

/// Countdowns whose time is always read from the injected clock; ticks only refresh the label,
/// so a late or missed tick never makes a timer drift.
public final class TimerModule: SaysoModule, @unchecked Sendable {
    public static let defaultMaxTimers = 5

    public let descriptor = SaysoModuleDescriptor(
        id: "timer", title: "Timers", surfaces: [.compact, .peek, .expanded, .settings]
    )
    private let scheduler: SaysoScheduling
    private let now: @Sendable () -> Date
    private let maxTimers: Int
    private let lock = NSLock()
    private var runtime: Runtime?

    public init(
        scheduler: SaysoScheduling,
        now: @escaping @Sendable () -> Date = { Date() },
        maxTimers: Int = defaultMaxTimers
    ) {
        self.scheduler = scheduler
        self.now = now
        self.maxTimers = maxTimers
    }

    public var timers: [TimerSnapshot] { current?.snapshots ?? [] }

    /// Nil while the module is disabled or when the duration is not a positive number of seconds.
    @discardableResult
    public func startCountdown(_ duration: TimeInterval) -> TimerID? {
        guard duration.isFinite, duration > 0 else { return nil }
        return current?.start(.countdown(duration: duration))
    }

    @discardableResult
    public func pause(_ id: TimerID) -> Bool { current?.pause(id) ?? false }

    @discardableResult
    public func resume(_ id: TimerID) -> Bool { current?.resume(id) ?? false }

    @discardableResult
    public func cancel(_ id: TimerID) -> Bool { current?.cancel(id) ?? false }

    /// "m:ss", or "h:mm:ss" from one hour; fractions are dropped.
    public static func clockLabel(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? Int(max(0, seconds.rounded(.down))) : 0
        let (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    public func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        let runtime = Runtime(module: self, context: context)
        lock.withLock { self.runtime = runtime }
        return runtime
    }

    private var current: Runtime? { lock.withLock { runtime } }

    /// Forgets a stopped runtime so later calls are no-ops instead of reaching a dead runtime.
    fileprivate func detach(_ stopped: Runtime) {
        lock.withLock { if runtime === stopped { runtime = nil } }
    }

    fileprivate final class Runtime: SaysoModuleRuntime, @unchecked Sendable {
        private struct Entry {
            let id: TimerID
            var kind: TimerSnapshot.Kind
            var accumulated: TimeInterval = 0
            /// Nil while paused.
            var runningSince: Date?

            func elapsed(at now: Date) -> TimeInterval {
                accumulated + (runningSince.map { now.timeIntervalSince($0) } ?? 0)
            }

            func remaining(at now: Date) -> TimeInterval? {
                switch kind {
                case .countdown(let duration): duration - elapsed(at: now)
                }
            }
        }

        private enum Effect {
            case publish(stackID: String, kind: SaysoActivityKind, title: String, actions: [SaysoAction], progress: Double?)
            case dismiss(stackID: String)
        }

        unowned let module: TimerModule
        let context: SaysoModuleContext
        private let lock = NSLock()
        private var entries: [Entry] = []
        private var job: SaysoSubscription?
        private var running = false

        init(module: TimerModule, context: SaysoModuleContext) {
            self.module = module
            self.context = context
        }

        var snapshots: [TimerSnapshot] {
            lock.withLock {
                let now = module.now()
                return entries.map {
                    TimerSnapshot(
                        id: $0.id, kind: $0.kind, elapsed: $0.elapsed(at: now),
                        remaining: $0.remaining(at: now), isPaused: $0.runningSince == nil
                    )
                }
            }
        }

        func start() { lock.withLock { running = true } }

        func stop() {
            let pending = lock.withLock { () -> SaysoSubscription? in
                running = false
                defer { job = nil }
                return job
            }
            pending?.cancel()
            module.detach(self)
        }

        func handle(stackID: String, actionID: String) {
            guard let id = lock.withLock({ entries.first { $0.id.stackID == stackID }?.id }) else { return }
            switch actionID {
            case "pause": pause(id)
            case "resume": resume(id)
            case "cancel": cancel(id)
            default: break
            }
        }

        func start(_ kind: TimerSnapshot.Kind) -> TimerID? {
            update { entries, now in
                let entry = Entry(id: TimerID(), kind: kind, runningSince: now)
                entries.append(entry)
                return (entry.id, [Self.show(entry, at: now)])
            }
        }

        @discardableResult
        func pause(_ id: TimerID) -> Bool {
            update { entries, now in
                guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].runningSince != nil
                else { return nil }
                entries[index].accumulated = entries[index].elapsed(at: now)
                entries[index].runningSince = nil
                return (true, [Self.show(entries[index], at: now)])
            } ?? false
        }

        @discardableResult
        func resume(_ id: TimerID) -> Bool {
            update { entries, now in
                guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].runningSince == nil
                else { return nil }
                entries[index].runningSince = now
                return (true, [Self.show(entries[index], at: now)])
            } ?? false
        }

        @discardableResult
        func cancel(_ id: TimerID) -> Bool {
            update { entries, _ in
                guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
                let removed = entries.remove(at: index)
                return (true, [.dismiss(stackID: removed.id.stackID)])
            } ?? false
        }

        private func tick() {
            _ = update { entries, now in
                ((), entries.filter { $0.runningSince != nil }.map { Self.show($0, at: now) })
            }
        }

        /// Changes state under the lock and re-arms the single tick, then publishes outside it:
        /// publishing takes the host lock, and the host calls into this runtime while holding that lock.
        private func update<T>(_ change: (inout [Entry], Date) -> (T, [Effect])?) -> T? {
            let outcome = lock.withLock { () -> (T, [Effect])? in
                guard running else { return nil }
                let now = module.now()
                guard let outcome = change(&entries, now) else { return nil }
                rearm(at: now)
                return outcome
            }
            guard let outcome else { return nil }
            for effect in outcome.1 {
                switch effect {
                case let .publish(stackID, kind, title, actions, progress):
                    context.publish(stackID: stackID, kind: kind, title: title, actions: actions, progress: progress)
                case let .dismiss(stackID):
                    context.dismiss(stackID: stackID)
                }
            }
            return outcome.0
        }

        /// One job for the whole module, due when the soonest visible label changes; none while nothing runs.
        private func rearm(at now: Date) {
            job?.cancel()
            job = nil
            guard let delay = entries.compactMap({ Self.nextLabelChange($0, at: now) }).min() else { return }
            job = module.scheduler.schedule(at: now.addingTimeInterval(delay)) { [weak self] in self?.tick() }
        }

        private static func nextLabelChange(_ entry: Entry, at now: Date) -> TimeInterval? {
            guard entry.runningSince != nil, let remaining = entry.remaining(at: now), remaining > 0 else { return nil }
            // The label shows whole seconds rounded up, so it changes when `remaining` reaches the next integer below.
            return remaining - (remaining.rounded(.up) - 1)
        }

        private static func show(_ entry: Entry, at now: Date) -> Effect {
            let paused = entry.runningSince == nil
            let elapsed = entry.elapsed(at: now)
            switch entry.kind {
            case .countdown(let duration):
                let label = TimerModule.clockLabel((duration - elapsed).rounded(.up))
                return .publish(
                    stackID: entry.id.stackID, kind: .activeTask,
                    title: "Timer \(label)" + (paused ? " (paused)" : ""),
                    actions: [
                        paused ? SaysoAction(id: "resume", title: "Resume") : SaysoAction(id: "pause", title: "Pause"),
                        SaysoAction(id: "cancel", title: "Cancel"),
                    ],
                    progress: elapsed / duration
                )
            }
        }
    }
}
