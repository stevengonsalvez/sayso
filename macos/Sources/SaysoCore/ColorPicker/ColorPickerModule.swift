import Foundation

/// One picked colour, kept in history.
public struct ColorPick: Equatable, Sendable, Identifiable {
    public let id: Int
    public let color: ColorPickerColor
}

/// Picks a colour from the screen through the injected sampler, keeps the last `historyLimit` picks in memory and
/// copies one format of a pick through a write-only pasteboard port. Picks are purged on disable.
public final class ColorPickerModule: SaysoModule, @unchecked Sendable {
    public static let historyLimit = 10
    /// As long as the Calculator, Timer and Caffeine completion notices.
    public static let noticeSeconds: TimeInterval = 10
    static let stackID = "color-picker-pick"

    public let descriptor = SaysoModuleDescriptor(
        id: "color-picker", title: "Colour picker", surfaces: [.compact, .expanded, .settings]
    )
    private let sampler: ColorSamplingPort
    private let pasteboard: CalculatorPasteboardPort
    private let scheduler: SaysoScheduling
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var runtime: Runtime?
    /// Set while the sampler is on screen, across off and on: it cannot be closed from code, so a second one must
    /// never open until it returns.
    private var sampling = false
    /// Kept across sessions, so an id from before off and on never names a pick of the new session.
    private var nextID = 1

    public init(
        sampler: ColorSamplingPort,
        pasteboard: CalculatorPasteboardPort,
        scheduler: SaysoScheduling,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sampler = sampler
        self.pasteboard = pasteboard
        self.scheduler = scheduler
        self.now = now
    }

    /// Newest first; empty while disabled.
    public var history: [ColorPick] { current?.history ?? [] }

    /// True while the sampler is on screen.
    public var isPicking: Bool { lock.withLock { sampling } }

    /// Shows the sampler and keeps the clicked colour. Nil when the user cancels, the module is off, a pick is
    /// already open, or the module was turned off while the sampler was open.
    public func pick() async -> ColorPick? {
        guard let runtime = current, lock.withLock({ () -> Bool in
            guard !sampling else { return false }
            sampling = true
            return true
        }) else { return nil }
        defer { lock.withLock { sampling = false } }
        guard runtime.beginPick() else { return nil }
        return runtime.finishPick(await sampler.pick())
    }

    /// Writes one format of the pick with this id; false when it is gone, the module is off or the write failed.
    @discardableResult
    public func copy(_ format: ColorPickerFormat, of id: ColorPick.ID) -> Bool {
        guard let color = current?.history.first(where: { $0.id == id })?.color else { return false }
        return pasteboard.write(color.text(format))
    }

    public func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        let runtime = Runtime(module: self, context: context)
        lock.withLock { self.runtime = runtime }
        return runtime
    }

    private var current: Runtime? { lock.withLock { runtime } }

    /// Called under the runtime's lock; the module lock is never held while taking a runtime's lock.
    fileprivate func takeID() -> Int {
        lock.withLock {
            defer { nextID += 1 }
            return nextID
        }
    }

    /// Forgets a stopped runtime so later calls are refused instead of reaching a dead runtime.
    fileprivate func detach(_ stopped: Runtime) {
        lock.withLock { if runtime === stopped { runtime = nil } }
    }

    fileprivate final class Runtime: SaysoModuleRuntime, SaysoResourceAccounting, @unchecked Sendable {
        unowned let module: ColorPickerModule
        let context: SaysoModuleContext
        private let lock = NSLock()
        private var picks: [ColorPick] = []
        private var pending = false
        private var job: SaysoSubscription?
        /// Bumped for every new notice, so a timer callback already under way for an older one changes nothing.
        private var notice = 0
        private var running = false

        init(module: ColorPickerModule, context: SaysoModuleContext) {
            self.module = module
            self.context = context
        }

        /// Picks, the notice's expiry job and a pick waiting on the sampler, so a purge that misses one is visible.
        var retainedResources: Int { lock.withLock { picks.count + (job == nil ? 0 : 1) + (pending ? 1 : 0) } }

        var history: [ColorPick] { lock.withLock { picks } }

        func start() { lock.withLock { running = true } }

        func stop() {
            lock.withLock {
                running = false
                pending = false
                job?.cancel()
                job = nil
                picks = []
            }
            module.detach(self)
        }

        func handle(stackID: String, actionID: String) {
            guard stackID == ColorPickerModule.stackID, actionID == "dismiss" else { return }
            let dismissed = lock.withLock { () -> Bool in
                guard running else { return false }
                job?.cancel()
                job = nil
                return true
            }
            if dismissed { context.dismiss(stackID: ColorPickerModule.stackID) }
        }

        func beginPick() -> Bool {
            lock.withLock {
                guard running else { return false }
                pending = true
                return true
            }
        }

        /// Keeps `color` unless it repeats the last pick, and shows the notice. Nil for a cancel or once stopped.
        /// Publishes outside the lock: publishing takes the host lock, and the host calls into this runtime while
        /// holding that lock.
        func finishPick(_ color: ColorPickerColor?) -> ColorPick? {
            let kept = lock.withLock { () -> ColorPick? in
                guard running, pending else { return nil }
                pending = false
                guard let color else { return nil }
                let pick: ColorPick
                if let last = picks.first, last.color == color {
                    pick = last
                } else {
                    pick = ColorPick(id: module.takeID(), color: color)
                    picks = Array(([pick] + picks).prefix(ColorPickerModule.historyLimit))
                }
                job?.cancel()
                notice += 1
                let due = module.now().addingTimeInterval(ColorPickerModule.noticeSeconds)
                job = module.scheduler.schedule(at: due) { [weak self, notice] in self?.expire(notice) }
                return pick
            }
            guard let kept else { return nil }
            context.publish(
                stackID: ColorPickerModule.stackID, kind: .completion, title: "Picked \(kept.color.hex)",
                expiresAfter: ColorPickerModule.noticeSeconds, actions: [SaysoAction(id: "dismiss", title: "Dismiss")]
            )
            return kept
        }

        private func expire(_ expiring: Int) {
            let due = lock.withLock { () -> Bool in
                guard running, job != nil, notice == expiring else { return false }
                job = nil
                return true
            }
            if due { context.dismiss(stackID: ColorPickerModule.stackID) }
        }
    }
}
