import Foundation

public struct FileShelfItem: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let url: URL
    public let name: String
    public let byteCount: Int64
    public let isDirectory: Bool
    public let addedAt: Date
}

public final class FileShelfModule: SaysoModule, @unchecked Sendable {
    public static let supportedLimits = [10, 20, 50]
    public static let defaultLimit = 20
    static let checkInterval: TimeInterval = 5
    static let addedNoticeSeconds: TimeInterval = 2

    public let descriptor = SaysoModuleDescriptor(
        id: "file-shelf", title: "File shelf", capabilities: [.files],
        surfaces: [.compact, .peek, .expanded, .detail, .settings]
    )
    private let port: FileShelfPort
    private let scheduler: SaysoScheduling
    private let now: @Sendable () -> Date
    private let itemLifetime: TimeInterval?
    private let lock = NSLock()
    private var runtime: Runtime?
    private var limit = defaultLimit

    public init(
        port: FileShelfPort,
        scheduler: SaysoScheduling,
        now: @escaping @Sendable () -> Date = { Date() },
        itemLifetime: TimeInterval? = nil
    ) {
        self.port = port
        self.scheduler = scheduler
        self.now = now
        self.itemLifetime = itemLifetime
    }

    public var items: [FileShelfItem] { lock.withLock { runtime }?.items ?? [] }

    /// Stages dropped files; returns how many were accepted. Zero while the module is disabled.
    @discardableResult
    public func add(_ urls: [URL]) -> Int { lock.withLock { runtime }?.add(urls) ?? 0 }

    public func setLimit(_ newLimit: Int) {
        guard Self.supportedLimits.contains(newLimit) else { return }
        lock.withLock { limit = newLimit }
        lock.withLock { runtime }?.trim()
    }

    @discardableResult
    public func open(id: FileShelfItem.ID) -> Bool { lock.withLock { runtime }?.perform(id: id) { port.open($0) } ?? false }

    @discardableResult
    public func reveal(id: FileShelfItem.ID) -> Bool { lock.withLock { runtime }?.perform(id: id) { port.reveal($0) } ?? false }

    @discardableResult
    public func remove(id: FileShelfItem.ID) -> Bool { lock.withLock { runtime }?.remove(id: id) ?? false }

    public func clear() { lock.withLock { runtime }?.clear() }

    /// URLs for a drag out of the shelf; items whose file has disappeared are pruned instead of returned.
    public func urlsForDrag(ids: [FileShelfItem.ID]) -> [URL] { lock.withLock { runtime }?.urlsForDrag(ids: ids) ?? [] }

    public func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        let runtime = Runtime(module: self, context: context)
        lock.withLock { self.runtime = runtime }
        return runtime
    }

    private var currentLimit: Int { lock.withLock { limit } }

    /// Forgets a stopped runtime so later calls are no-ops instead of reaching a dead shelf.
    fileprivate func detach(_ stopped: Runtime) {
        lock.withLock { if runtime === stopped { runtime = nil } }
    }

    fileprivate final class Runtime: SaysoModuleRuntime, SaysoResourceAccounting, @unchecked Sendable {
        private struct Held { var item: FileShelfItem; let access: FileShelfAccess }

        unowned let module: FileShelfModule
        let context: SaysoModuleContext
        private let lock = NSLock()
        private var held: [Held] = []
        private var job: SaysoSubscription?
        private var running = false

        init(module: FileShelfModule, context: SaysoModuleContext) {
            self.module = module
            self.context = context
        }

        var items: [FileShelfItem] { lock.withLock { held.map(\.item) } }
        var retainedResources: Int { lock.withLock { held.count + (job == nil ? 0 : 1) } }

        func start() { lock.withLock { running = true } }

        func stop() {
            let (pending, made) = lock.withLock { () -> ([Held], SaysoSubscription?) in
                running = false
                defer { held = []; job = nil }
                return (held, job)
            }
            made?.cancel()
            pending.forEach { $0.access.release() }
            module.detach(self)
        }

        func handle(stackID: String, actionID: String) {
            if stackID == "shelf", actionID == "clear" { clear() }
        }

        func add(_ urls: [URL]) -> Int {
            guard lock.withLock({ running }) else { return 0 }
            var accepted = 0
            for url in urls {
                guard let file = module.port.resolve(url) else { continue }
                let path = url.standardizedFileURL.path
                let moved = lock.withLock { () -> Bool in
                    guard let index = held.firstIndex(where: { $0.item.url.standardizedFileURL.path == path }) else { return false }
                    var existing = held.remove(at: index)
                    existing.item = FileShelfItem(
                        id: existing.item.id, url: existing.item.url, name: file.name, byteCount: file.byteCount,
                        isDirectory: file.isDirectory, addedAt: module.now()
                    )
                    held.insert(existing, at: 0)
                    return true
                }
                if moved { accepted += 1; continue }
                guard let access = module.port.acquire(url) else { continue }
                let item = FileShelfItem(
                    id: UUID(), url: url, name: file.name, byteCount: file.byteCount,
                    isDirectory: file.isDirectory, addedAt: module.now()
                )
                let inserted = lock.withLock { () -> Bool in
                    guard running else { return false }
                    held.insert(Held(item: item, access: access), at: 0)
                    return true
                }
                // A stop that landed while this file was being resolved must not leave a grant behind.
                guard inserted else { access.release(); break }
                accepted += 1
            }
            trim()
            if accepted > 0 {
                context.publish(
                    stackID: "added", kind: .completion, title: "Added \(Self.noun(accepted))",
                    expiresAfter: FileShelfModule.addedNoticeSeconds
                )
            }
            refresh()
            return accepted
        }

        func trim() {
            let dropped = lock.withLock { () -> [Held] in
                let limit = module.currentLimit
                guard held.count > limit else { return [] }
                defer { held.removeLast(held.count - limit) }
                return Array(held.suffix(held.count - limit))
            }
            dropped.forEach { $0.access.release() }
            if !dropped.isEmpty { refresh() }
        }

        func perform(id: FileShelfItem.ID, _ work: (URL) -> Void) -> Bool {
            guard let item = items.first(where: { $0.id == id }) else { return false }
            guard module.port.resolve(item.url) != nil else {
                _ = remove(id: id)
                return false
            }
            work(item.url)
            return true
        }

        func remove(id: FileShelfItem.ID) -> Bool { remove(id: id, refreshing: true) }

        private func remove(id: FileShelfItem.ID, refreshing: Bool) -> Bool {
            let removed = lock.withLock { () -> Held? in
                guard let index = held.firstIndex(where: { $0.item.id == id }) else { return nil }
                return held.remove(at: index)
            }
            removed?.access.release()
            if removed != nil, refreshing { refresh() }
            return removed != nil
        }

        func clear() {
            let all = lock.withLock { () -> [Held] in
                defer { held = [] }
                return held
            }
            all.forEach { $0.access.release() }
            refresh()
        }

        func urlsForDrag(ids: [FileShelfItem.ID]) -> [URL] {
            var urls: [URL] = []
            for id in ids {
                guard let item = items.first(where: { $0.id == id }) else { continue }
                if module.port.resolve(item.url) != nil { urls.append(item.url) } else { _ = remove(id: id) }
            }
            return urls
        }

        private func prune() {
            let current = items
            let cutoff = module.itemLifetime.map { module.now().addingTimeInterval(-$0) }
            for item in current {
                let expired = cutoff.map { item.addedAt <= $0 } ?? false
                if expired || module.port.resolve(item.url) == nil { _ = remove(id: item.id, refreshing: false) }
            }
        }

        /// Keeps the shelf activity and the single check timer in step with the items.
        private func refresh() {
            // Count, running state and timer decision are read in one critical section so they cannot disagree.
            let state = lock.withLock { () -> (count: Int, arm: Bool, cancel: SaysoSubscription?)? in
                guard running else { return nil }
                if held.isEmpty {
                    defer { job = nil }
                    return (0, false, job)
                }
                return (held.count, job == nil, nil)
            }
            guard let state else { return }
            state.cancel?.cancel()
            if state.count == 0 {
                context.dismiss(stackID: "shelf")
                return
            }
            context.publish(
                stackID: "shelf", kind: .ambient, title: "File shelf · \(Self.noun(state.count))",
                actions: [SaysoAction(id: "clear", title: "Clear")]
            )
            if state.arm { arm() }
        }

        private func arm() {
            let next = module.now().addingTimeInterval(FileShelfModule.checkInterval)
            let scheduled = module.scheduler.schedule(at: next) { [weak self] in
                guard let self else { return }
                self.lock.withLock { self.job = nil }
                self.prune()
                self.refresh()
            }
            let accepted = lock.withLock { () -> Bool in
                guard running, job == nil else { return false }
                job = scheduled
                return true
            }
            if !accepted { scheduled.cancel() }
        }

        private static func noun(_ count: Int) -> String { count == 1 ? "1 file" : "\(count) files" }
    }
}
