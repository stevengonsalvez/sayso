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

    /// Dictation fallback: puts `text` on the clipboard, runs the paste, then restores the previous clipboard
    /// only when the paste succeeded and nobody else copied meanwhile. A failed paste leaves `text` available.
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
        private var cleanedLink: String?
        private var stopped = true

        init(module: ClipboardModule, context: SaysoModuleContext) {
            self.module = module
            self.context = context
        }

        var retainedResources: Int { lock.withLock { job == nil ? 0 : 1 } }

        func start() {
            lock.withLock {
                stopped = false
                lastChange = module.port.changeCount
            }
            arm()
        }

        func stop() {
            let pending = lock.withLock { () -> SaysoSubscription? in
                stopped = true
                defer { job = nil }
                return job
            }
            pending?.cancel()
        }

        func handle(stackID: String, actionID: String) {
            guard stackID == "clean-link", actionID == "clean",
                  let cleaned = lock.withLock({ cleanedLink }) else { return }
            context.dismiss(stackID: "clean-link")
            _ = ownWrite(cleaned, concealed: false, recordAs: cleaned)
        }

        var isRunning: Bool { lock.withLock { !stopped } }

        func ownWrite(_ text: String, concealed: Bool, recordAs recorded: String?) -> Bool {
            guard isRunning, module.port.write(text: text, concealed: concealed) else { return false }
            lock.withLock { lastChange = module.port.changeCount }
            if let recorded { _ = module.record(recorded, at: module.now()) }
            return true
        }

        func pasteTemporarily(_ text: String, perform: () -> Bool) -> Bool {
            guard isRunning else { return false }
            let previous = module.port.snapshot()
            guard module.port.write(text: text, concealed: false) else { return false }
            let afterWrite = module.port.changeCount
            lock.withLock { lastChange = afterWrite }
            let pasted = perform()
            guard pasted else { return false }
            if module.port.changeCount == afterWrite, let old = previous.text {
                let concealed = !previous.types.isDisjoint(with: ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"])
                _ = module.port.write(text: old, concealed: concealed)
                lock.withLock { lastChange = module.port.changeCount }
            }
            return true
        }

        private func arm() {
            let next = module.now().addingTimeInterval(ClipboardModule.pollInterval)
            let made = module.scheduler.schedule(at: next) { [weak self] in self?.poll() }
            let accepted = lock.withLock { () -> Bool in
                guard !stopped else { return false }
                job = made
                return true
            }
            if !accepted { made.cancel() }
        }

        private func poll() {
            guard !lock.withLock({ stopped }) else { return }
            let count = module.port.changeCount
            let changed = lock.withLock { () -> Bool in
                guard count != lastChange else { return false }
                lastChange = count
                return true
            }
            if changed { observe(module.port.snapshot()) }
            arm()
        }

        private func observe(_ snapshot: ClipboardSnapshot) {
            guard ClipboardPrivacy.shouldRecord(snapshot), let text = snapshot.text,
                  let entry = module.record(text, at: module.now()) else { return }
            context.emit(ClipboardItemRecorded(id: entry.id, text: text, sourceApp: snapshot.sourceApp))
            if let cleaned = ClipboardLinkCleaner.cleaned(text) {
                lock.withLock { cleanedLink = cleaned }
                context.publish(
                    stackID: "clean-link", kind: .ambient, title: "Clean link",
                    expiresAfter: ClipboardModule.cleanOfferSeconds,
                    actions: [SaysoAction(id: "clean", title: "Clean")]
                )
            }
        }
    }
}
