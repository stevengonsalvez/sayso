import Foundation

/// Handle for one running countdown, stopwatch or Pomodoro.
public struct TimerID: Hashable, Sendable {
    private let raw = UUID()

    public init() {}

    var stackID: String { "timer-\(raw.uuidString)" }
}

public struct TimerSnapshot: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case countdown(duration: TimeInterval)
        case stopwatch
        case pomodoro(phase: TimerPhase, completedFocusSessions: Int)
    }

    public let id: TimerID
    public let kind: Kind
    /// For a Pomodoro, time spent in the current phase.
    public let elapsed: TimeInterval
    /// Nil for a stopwatch, which has no end.
    public let remaining: TimeInterval?
    public let isPaused: Bool
    /// Stopwatch lap lengths, oldest first.
    public let laps: [TimeInterval]
}

/// Countdowns, stopwatches and a Pomodoro whose time is always read from the injected clock; ticks only refresh
/// the label, so a late or missed tick never makes a timer drift.
public final class TimerModule: SaysoModule, @unchecked Sendable {
    public static let defaultMaxTimers = 5
    public static let completionNoticeSeconds: TimeInterval = 10
    public static let maxLaps = 99

    public let descriptor = SaysoModuleDescriptor(
        id: "timer", title: "Timers", surfaces: [.compact, .peek, .expanded, .settings]
    )
    private let scheduler: SaysoScheduling
    private let now: @Sendable () -> Date
    private let maxTimers: Int
    private let plan: PomodoroPlan
    private let lock = NSLock()
    private var runtime: Runtime?

    public init(
        scheduler: SaysoScheduling,
        now: @escaping @Sendable () -> Date = { Date() },
        maxTimers: Int = defaultMaxTimers,
        pomodoro: PomodoroPlan = .standard
    ) {
        self.scheduler = scheduler
        self.now = now
        self.maxTimers = maxTimers
        self.plan = pomodoro
    }

    public var timers: [TimerSnapshot] { current?.snapshots ?? [] }

    /// Nil while the module is disabled or when the duration is not a positive number of seconds.
    @discardableResult
    public func startCountdown(_ duration: TimeInterval) -> TimerID? {
        guard duration.isFinite, duration > 0 else { return nil }
        return current?.start(.countdown(duration: duration), duration: duration)
    }

    /// Nil while the module is disabled or when timers and stopwatches already fill the cap.
    @discardableResult
    public func startStopwatch() -> TimerID? { current?.start(.stopwatch, duration: nil) }

    /// Records a lap and returns its length; nil unless the stopwatch is running and has room for another lap.
    @discardableResult
    public func lap(_ id: TimerID) -> TimeInterval? { current?.lap(id) }

    /// Starts at focus; nil while the module is disabled or while another Pomodoro exists, running or paused.
    @discardableResult
    public func startPomodoro() -> TimerID? {
        current?.start(.pomodoro(phase: .focus, completedFocusSessions: 0), duration: plan.duration(of: .focus))
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
            /// Length of the countdown or current Pomodoro phase; nil for a stopwatch.
            var duration: TimeInterval?
            var accumulated: TimeInterval = 0
            /// Nil while paused.
            var runningSince: Date?
            var laps: [TimeInterval] = []

            var isPomodoro: Bool {
                if case .pomodoro = kind { return true }
                return false
            }

            var noticeStackID: String { id.stackID + "-done" }

            func elapsed(at now: Date) -> TimeInterval {
                accumulated + (runningSince.map { now.timeIntervalSince($0) } ?? 0)
            }

            func remaining(at now: Date) -> TimeInterval? { duration.map { $0 - elapsed(at: now) } }

            func hasEnded(at now: Date) -> Bool { remaining(at: now).map { $0 <= 0 } ?? false }
        }

        private enum Effect {
            case publish(
                stackID: String, kind: SaysoActivityKind, title: String,
                expiresAfter: TimeInterval? = nil, actions: [SaysoAction] = [], progress: Double? = nil
            )
            case dismiss(stackID: String)
            case ping(TimerPing)
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
                        remaining: $0.remaining(at: now), isPaused: $0.runningSince == nil, laps: $0.laps
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

        func start(_ kind: TimerSnapshot.Kind, duration: TimeInterval?) -> TimerID? {
            update { entries, now in
                let entry = Entry(id: TimerID(), kind: kind, duration: duration, runningSince: now)
                if entry.isPomodoro {
                    guard !entries.contains(where: \.isPomodoro) else { return nil }
                } else {
                    guard entries.filter({ !$0.isPomodoro }).count < module.maxTimers else { return nil }
                }
                entries.append(entry)
                return (entry.id, [show(entry, at: now)])
            }
        }

        @discardableResult
        func pause(_ id: TimerID) -> Bool {
            update { entries, now in
                guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].runningSince != nil
                else { return nil }
                entries[index].accumulated = entries[index].elapsed(at: now)
                entries[index].runningSince = nil
                return (true, [show(entries[index], at: now)])
            } ?? false
        }

        @discardableResult
        func resume(_ id: TimerID) -> Bool {
            update { entries, now in
                guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].runningSince == nil
                else { return nil }
                entries[index].runningSince = now
                return (true, [show(entries[index], at: now)])
            } ?? false
        }

        func lap(_ id: TimerID) -> TimeInterval? {
            update { entries, now in
                guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].kind == .stopwatch,
                      entries[index].runningSince != nil, entries[index].laps.count < TimerModule.maxLaps
                else { return nil }
                let length = entries[index].elapsed(at: now) - entries[index].laps.reduce(0, +)
                entries[index].laps.append(length)
                return (length, [])
            }
        }

        @discardableResult
        func cancel(_ id: TimerID) -> Bool {
            update { entries, _ in
                guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
                let removed = entries.remove(at: index)
                return (true, [.dismiss(stackID: removed.id.stackID), .dismiss(stackID: removed.noticeStackID)])
            } ?? false
        }

        /// Settles whatever reached its deadline by `now`, however late the tick fired, and refreshes the rest.
        private func tick() {
            _ = update { entries, now in
                var effects: [Effect] = []
                entries = entries.compactMap { entry in
                    guard entry.runningSince != nil else { return entry }
                    guard entry.hasEnded(at: now) else {
                        effects.append(show(entry, at: now))
                        return entry
                    }
                    switch entry.kind {
                    case .countdown(let duration):
                        effects += [
                            .dismiss(stackID: entry.id.stackID),
                            .publish(
                                stackID: entry.noticeStackID, kind: .completion,
                                title: "Timer done · \(TimerModule.clockLabel(duration))",
                                expiresAfter: TimerModule.completionNoticeSeconds
                            ),
                            .ping(TimerPing(timerID: entry.id, reason: .finished)),
                        ]
                        return nil
                    case .pomodoro:
                        let (next, transition) = advance(entry, to: now)
                        effects += [show(next, at: now)] + transition
                        return next
                    case .stopwatch:
                        return entry
                    }
                }
                return ((), effects)
            }
        }

        /// Moves a Pomodoro through every phase that ended by `now`. Each phase starts at the instant the
        /// previous one ended, so a late tick never shifts the schedule. Only the last transition is announced,
        /// so waking from sleep does not replay a burst of pings.
        private func advance(_ entry: Entry, to now: Date) -> (Entry, [Effect]) {
            var entry = entry
            var ended: TimerPhase?
            while case let .pomodoro(phase, completed) = entry.kind, let remaining = entry.remaining(at: now), remaining <= 0 {
                let done = phase == .focus ? completed + 1 : completed
                let next = module.plan.phase(after: phase, completedFocusSessions: done)
                entry.runningSince = now.addingTimeInterval(remaining)
                entry.accumulated = 0
                entry.duration = module.plan.duration(of: next)
                entry.kind = .pomodoro(phase: next, completedFocusSessions: done)
                ended = phase
            }
            guard let ended, case let .pomodoro(started, _) = entry.kind else { return (entry, []) }
            return (entry, [
                .publish(
                    stackID: entry.noticeStackID, kind: .completion, title: "\(ended.title) done · \(started.title)",
                    expiresAfter: TimerModule.completionNoticeSeconds
                ),
                .ping(TimerPing(timerID: entry.id, reason: .phaseStarted(started))),
            ])
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
                case let .publish(stackID, kind, title, expiresAfter, actions, progress):
                    context.publish(
                        stackID: stackID, kind: kind, title: title,
                        expiresAfter: expiresAfter, actions: actions, progress: progress
                    )
                case let .dismiss(stackID):
                    context.dismiss(stackID: stackID)
                case let .ping(ping):
                    context.emit(ping)
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
            guard entry.runningSince != nil else { return nil }
            guard let remaining = entry.remaining(at: now) else {
                // A stopwatch label shows whole elapsed seconds, so it changes at the next whole second.
                let elapsed = entry.elapsed(at: now)
                return elapsed.rounded(.down) + 1 - elapsed
            }
            guard remaining > 0 else { return nil }
            // A countdown label shows whole seconds rounded up, so it changes when `remaining` reaches the next integer below.
            return remaining - (remaining.rounded(.up) - 1)
        }

        private func show(_ entry: Entry, at now: Date) -> Effect {
            let paused = entry.runningSince == nil
            let elapsed = entry.elapsed(at: now)
            let name = switch entry.kind {
            case .countdown: "Timer"
            case .stopwatch: "Stopwatch"
            case .pomodoro(let phase, _): phase.title
            }
            let shown = entry.remaining(at: now).map { $0.rounded(.up) } ?? elapsed
            return .publish(
                stackID: entry.id.stackID, kind: .activeTask,
                title: "\(name) \(TimerModule.clockLabel(shown))" + (paused ? " (paused)" : ""),
                actions: [
                    paused ? SaysoAction(id: "resume", title: "Resume") : SaysoAction(id: "pause", title: "Pause"),
                    SaysoAction(id: "cancel", title: "Cancel"),
                ],
                progress: entry.duration.map { elapsed / $0 }
            )
        }
    }
}
