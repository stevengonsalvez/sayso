import Foundation

public final class ClipboardModule: SaysoModule, @unchecked Sendable {
    public let descriptor = SaysoModuleDescriptor(
        id: "clipboard", title: "Clipboard", capabilities: [.clipboard],
        surfaces: [.compact, .peek, .expanded, .detail, .settings]
    )
    static let pollInterval: TimeInterval = 0.5
    static let cleanOfferSeconds: TimeInterval = 8

    private let port: ClipboardPort
    private let scheduler: SaysoScheduling
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var history = ClipboardHistory()
    private var runtime: Runtime?

    public init(port: ClipboardPort, scheduler: SaysoScheduling, now: @escaping @Sendable () -> Date = { Date() }) {
        self.port = port
        self.scheduler = scheduler
        self.now = now
    }

    public var entries: [ClipboardHistory.Entry] { lock.withLock { history.entries } }

    public func setLimit(_ limit: Int) { lock.withLock { history.setLimit(limit) } }

    public func clearHistory() { lock.withLock { history.clear() } }

    public func remove(id: ClipboardHistory.Entry.ID) { lock.withLock { history.remove(id: id) } }

    public func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        let runtime = Runtime(module: self, context: context)
        lock.withLock { self.runtime = runtime }
        return runtime
    }

    /// Writes a history entry back as plain text; the module's own write is not recorded again.
    @discardableResult
    public func copyBack(id: ClipboardHistory.Entry.ID) -> Bool {
        guard let entry = entries.first(where: { $0.id == id }), let runtime = lock.withLock({ runtime }) else { return false }
        return runtime.ownWrite(entry.text, concealed: false, recordAs: entry.text)
    }

    /// Dictation fallback: puts `text` on the clipboard, runs `perform`, then puts the user's previous clipboard
    /// back exactly (every item and flavour). The previous contents are cleared instead of restored when they
    /// were sensitive, and left alone when someone else copied meanwhile.
    ///
    /// Contract: `perform` must return true only after the target has really received the text (for example by
    /// reading the field value back through Accessibility). A synthetic Cmd+V that returns before the target reads
    /// the pasteboard would let the restore land first and paste the old clipboard. A false return leaves `text`
    /// on the clipboard so the user can paste it by hand.
    public func pasteTemporarily(_ text: String, perform: () -> Bool) -> Bool {
        guard let runtime = lock.withLock({ runtime }) else { return false }
        return runtime.pasteTemporarily(text, perform: perform)
    }

    fileprivate func record(_ text: String, at date: Date) -> ClipboardHistory.Entry? {
        lock.withLock {
            history.add(text, at: date)
            return history.entries.first
        }
    }

    private final class Runtime: SaysoModuleRuntime, SaysoResourceAccounting, @unchecked Sendable {
        unowned let module: ClipboardModule
        let context: SaysoModuleContext
        private let lock = NSLock()
        private var job: SaysoSubscription?
        private var lastChange = 0
        private var offer: (change: Int, link: String)?
        private var running = false
        /// Bumped on every start and stop so a poll scheduled by an older run can never act or re-arm.
        private var generation = 0

        init(module: ClipboardModule, context: SaysoModuleContext) {
            self.module = module
            self.context = context
        }

        var retainedResources: Int { lock.withLock { job == nil ? 0 : 1 } }
        var isRunning: Bool { lock.withLock { running } }

        func start() {
            let current = lock.withLock { () -> Int in
                running = true
                generation += 1
                lastChange = module.port.changeCount
                return generation
            }
            arm(current)
        }

        func stop() {
            let pending = lock.withLock { () -> SaysoSubscription? in
                running = false
                generation += 1
                offer = nil
                defer { job = nil }
                return job
            }
            pending?.cancel()
            // Off means purged: copied text must not outlive the opt-in.
            module.clearHistory()
        }

        func handle(stackID: String, actionID: String) {
            guard stackID == "clean-link", actionID == "clean" else { return }
            let pending = lock.withLock { () -> (change: Int, link: String)? in
                defer { offer = nil }
                return offer
            }
            context.dismiss(stackID: "clean-link")
            // The offer belongs to one specific copy; if anything was copied since, writing now would overwrite it.
            guard let pending, module.port.changeCount == pending.change else { return }
            _ = ownWrite(pending.link, concealed: false, recordAs: pending.link)
        }

        func ownWrite(_ text: String, concealed: Bool, recordAs recorded: String?) -> Bool {
            guard isRunning else { return false }
            drain()
            guard module.port.write(text: text, concealed: concealed) else { return false }
            lock.withLock { lastChange = module.port.changeCount }
            if let recorded { _ = module.record(recorded, at: module.now()) }
            return true
        }

        func pasteTemporarily(_ text: String, perform: () -> Bool) -> Bool {
            guard isRunning else { return false }
            drain()
            let previous = module.port.captureContents()
            guard module.port.write(text: text, concealed: false) else { return false }
            let afterWrite = module.port.changeCount
            lock.withLock { lastChange = afterWrite }
            guard perform() else { return false }
            if module.port.changeCount == afterWrite {
                if ClipboardPrivacy.isSensitive(types: previous.types, sourceBundleID: nil) {
                    module.port.clear()
                } else {
                    module.port.restore(previous)
                }
                lock.withLock { lastChange = module.port.changeCount }
            }
            return true
        }

        private func arm(_ expected: Int) {
            let next = module.now().addingTimeInterval(ClipboardModule.pollInterval)
            let made = module.scheduler.schedule(at: next) { [weak self] in self?.poll(expected) }
            let accepted = lock.withLock { () -> Bool in
                guard running, generation == expected else { return false }
                job?.cancel()
                job = made
                return true
            }
            if !accepted { made.cancel() }
        }

        private func poll(_ expected: Int) {
            guard lock.withLock({ running && generation == expected }) else { return }
            drain()
            arm(expected)
        }

        /// Records a pending copy now, so our own write never hides something copied a moment earlier.
        private func drain() {
            guard module.port.changeCount != lock.withLock({ lastChange }) else { return }
            let snapshot = module.port.snapshot()
            lock.withLock { lastChange = snapshot.changeCount }
            observe(snapshot)
        }

        private func observe(_ snapshot: ClipboardSnapshot) {
            // Any newer copy invalidates an earlier clean-link offer.
            lock.withLock { offer = nil }
            context.dismiss(stackID: "clean-link")
            guard ClipboardPrivacy.shouldRecord(snapshot), let text = snapshot.text,
                  let entry = module.record(text, at: module.now()) else { return }
            context.emit(ClipboardItemRecorded(id: entry.id, text: text, sourceApp: snapshot.sourceApp))
            if let cleaned = ClipboardLinkCleaner.cleaned(text) {
                lock.withLock { offer = (snapshot.changeCount, cleaned) }
                context.publish(
                    stackID: "clean-link", kind: .ambient, title: "Clean link",
                    expiresAfter: ClipboardModule.cleanOfferSeconds,
                    actions: [SaysoAction(id: "clean", title: "Clean")]
                )
            }
        }
    }
}
