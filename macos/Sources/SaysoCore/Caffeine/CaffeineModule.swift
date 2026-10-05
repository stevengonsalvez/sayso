import Foundation

/// How long Caffeine keeps the Mac awake.
public enum CaffeineDuration: Equatable, Sendable {
    case timed(TimeInterval)
    case indefinite

    public static let fifteenMinutes = CaffeineDuration.timed(15 * 60)
    public static let oneHour = CaffeineDuration.timed(3600)
}

public struct CaffeineSession: Equatable, Sendable {
    /// The label the notch shows, for example "Awake · 15 min left", so every surface agrees.
    public let title: String
    /// Nil for an indefinite session.
    public let deadline: Date?
}

/// Keeps the Mac awake on demand with at most one power assertion. Timed sessions end at their deadline read
/// from the injected clock; ticks only refresh the minute label, so a late tick never extends a session.
public final class CaffeineModule: SaysoModule, @unchecked Sendable {
    public static let assertionName = "Sayso Caffeine"
    /// Longest timed session, one day; longer needs are what an indefinite session is for.
    public static let maxTimedSeconds: TimeInterval = 24 * 3600
    public static let completionNoticeSeconds: TimeInterval = 10
    static let stackID = "caffeine"
    static let noticeStackID = "caffeine-done"

    public let descriptor = SaysoModuleDescriptor(
        id: "caffeine", title: "Caffeine", surfaces: [.compact, .peek, .expanded, .settings]
    )
    private let port: PowerAssertionPort
    private let scheduler: SaysoScheduling
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var runtime: Runtime?

    public init(port: PowerAssertionPort, scheduler: SaysoScheduling, now: @escaping @Sendable () -> Date = { Date() }) {
        self.port = port
        self.scheduler = scheduler
        self.now = now
    }

    public var session: CaffeineSession? { current?.session }

    /// Replaces any running session. False while the module is disabled or for a duration outside
    /// 0 < seconds <= `maxTimedSeconds`.
    @discardableResult
    public func start(_ duration: CaffeineDuration) -> Bool {
        if case let .timed(seconds) = duration, !(seconds > 0 && seconds <= Self.maxTimedSeconds) { return false }
        return current?.begin(duration) ?? false
    }

    /// False when nothing was running.
    @discardableResult
    public func stop() -> Bool { current?.end() ?? false }

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

    /// "Awake · 15 min left", "Awake · 1 h left", "Awake · 1 h 5 min left", or "Awake · ∞" without a deadline.
    /// Minutes round up, so the label never claims less time than is left.
    static func title(remaining: TimeInterval?) -> String {
        guard let remaining else { return "Awake · ∞" }
        let minutes = max(1, Int((min(remaining, maxTimedSeconds) / 60).rounded(.up)))
        let (hours, rest) = (minutes / 60, minutes % 60)
        let left = hours == 0 ? "\(rest) min" : rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
        return "Awake · \(left) left"
    }

    fileprivate final class Runtime: SaysoModuleRuntime, SaysoResourceAccounting, @unchecked Sendable {
        private struct Held {
            let assertion: PowerAssertion
            let deadline: Date?
        }

        private enum Effect {
            case show(title: String)
            case dismiss
            case ended
            case clearEnded
        }

        unowned let module: CaffeineModule
        let context: SaysoModuleContext
        private let lock = NSLock()
        private var held: Held?
        private var job: SaysoSubscription?
        private var running = false

        init(module: CaffeineModule, context: SaysoModuleContext) {
            self.module = module
            self.context = context
        }

        var retainedResources: Int { lock.withLock { (held == nil ? 0 : 1) + (job == nil ? 0 : 1) } }

        var session: CaffeineSession? {
            lock.withLock {
                held.map { CaffeineSession(title: title(of: $0, at: module.now()), deadline: $0.deadline) }
            }
        }

        func start() { lock.withLock { running = true } }

        func stop() {
            lock.withLock {
                running = false
                release()
            }
            module.detach(self)
        }

        func handle(stackID: String, actionID: String) {
            // Dismissing from the notch ends the session: hiding it would keep the Mac awake unseen.
            guard stackID == CaffeineModule.stackID, actionID == "stop" || actionID == "dismiss" else { return }
            end()
        }

        func begin(_ duration: CaffeineDuration) -> Bool {
            update { now in
                // Release first so two assertions are never held, even for a moment.
                release()
                guard let assertion = module.port.createAssertion(named: CaffeineModule.assertionName) else {
                    return (false, [.dismiss, .clearEnded])
                }
                let deadline: Date? = if case let .timed(seconds) = duration { now.addingTimeInterval(seconds) } else { nil }
                let session = Held(assertion: assertion, deadline: deadline)
                held = session
                return (true, [.clearEnded, .show(title: title(of: session, at: now))])
            } ?? false
        }

        @discardableResult
        func end() -> Bool {
            update { _ in
                guard held != nil else { return nil }
                release()
                return (true, [.dismiss])
            } ?? false
        }

        private func tick() {
            _ = update { now in ((), held.map { [.show(title: title(of: $0, at: now))] } ?? []) }
        }

        /// Ends a timed session whose deadline passed by `now`, however late this runs. Call with the lock held.
        private func settle(at now: Date) -> [Effect] {
            guard let deadline = held?.deadline, now >= deadline else { return [] }
            release()
            return [.dismiss, .ended]
        }

        /// Settles a missed deadline, applies `change` and re-arms the single tick under the lock, then publishes
        /// outside it: publishing takes the host lock, and the host calls into this runtime while holding that lock.
        private func update<T>(_ change: (Date) -> (T, [Effect])?) -> T? {
            let (result, effects) = lock.withLock { () -> (T?, [Effect]) in
                guard running else { return (nil, []) }
                let now = module.now()
                let settled = settle(at: now)
                let outcome = change(now)
                rearm(at: now)
                return (outcome?.0, settled + (outcome?.1 ?? []))
            }
            for effect in effects {
                switch effect {
                case let .show(title):
                    context.publish(
                        stackID: CaffeineModule.stackID, kind: .activeTask, title: title,
                        actions: [SaysoAction(id: "stop", title: "Stop"), SaysoAction(id: "dismiss", title: "Dismiss")]
                    )
                case .dismiss:
                    context.dismiss(stackID: CaffeineModule.stackID)
                case .ended:
                    context.publish(
                        stackID: CaffeineModule.noticeStackID, kind: .completion, title: "Caffeine off · Mac can sleep",
                        expiresAfter: CaffeineModule.completionNoticeSeconds
                    )
                case .clearEnded:
                    context.dismiss(stackID: CaffeineModule.noticeStackID)
                }
            }
            return result
        }

        /// Call with the lock held.
        private func release() {
            job?.cancel()
            job = nil
            held?.assertion.release()
            held = nil
        }

        /// One job, due when the minute label next changes; none for an indefinite session.
        private func rearm(at now: Date) {
            job?.cancel()
            job = nil
            guard let deadline = held?.deadline, deadline > now else { return }
            // The label shows whole minutes rounded up, so it changes each time the time left crosses a minute.
            var minutesAfterChange = Int((deadline.timeIntervalSince(now) / 60).rounded(.up)) - 1
            var due = deadline.addingTimeInterval(-Double(minutesAfterChange) * 60)
            while due <= now, minutesAfterChange > 0 {
                minutesAfterChange -= 1
                due = deadline.addingTimeInterval(-Double(minutesAfterChange) * 60)
            }
            job = module.scheduler.schedule(at: due) { [weak self] in self?.tick() }
        }

        private func title(of session: Held, at now: Date) -> String {
            CaffeineModule.title(remaining: session.deadline.map { $0.timeIntervalSince(now) })
        }
    }
}
