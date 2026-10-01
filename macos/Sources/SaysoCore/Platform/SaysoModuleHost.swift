import Foundation

/// Owns module lifecycles and the shared activity engine.
/// Every entry point takes one recursive lock, so transitions are serialized across threads.
public final class SaysoModuleHost: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var state = SaysoActivityEngine()
    public var engine: SaysoActivityEngine { locked { state } }
    private let modules: [String: SaysoModule]
    private var runtimes: [String: SaysoModuleRuntime] = [:]
    private var failures: [String: [Date]] = [:]
    private var quarantined: Set<String> = []
    private let now: @Sendable () -> Date
    private let isGranted: @Sendable (SaysoCapability) -> Bool
    private var permissionBlocked: Set<String> = []
    private var generations: [String: Int] = [:]
    private let events: SaysoEventBus
    private var scopes: [String: SaysoEventScope] = [:]

    private static let quarantineWindow: TimeInterval = 300
    private static let quarantineFailures = 3

    public var descriptors: [SaysoModuleDescriptor] { order.map(\.descriptor) }
    private let order: [SaysoModule]

    public init(
        modules: [SaysoModule],
        now: @escaping @Sendable () -> Date = { Date() },
        isGranted: @escaping @Sendable (SaysoCapability) -> Bool = { _ in true },
        events: SaysoEventBus = SaysoEventBus()
    ) {
        self.events = events
        self.now = now
        self.isGranted = isGranted
        var seen = Set<String>()
        let unique = modules.filter { seen.insert($0.descriptor.id).inserted }
        self.order = unique
        self.modules = Dictionary(uniqueKeysWithValues: unique.map { ($0.descriptor.id, $0) })
    }

    public func health(of id: String) -> SaysoModuleHealth {
        lock.lock()
        defer { lock.unlock() }
        if quarantined.contains(id) { return .quarantined }
        if permissionBlocked.contains(id) { return .permissionRequired }
        if runtimes[id] == nil { return .disabled }
        return recentFailures(id).isEmpty ? .ready : .degraded
    }

    public func enable(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        guard runtimes[id] == nil, !quarantined.contains(id), let module = modules[id] else { return }
        guard module.descriptor.capabilities.allSatisfy(isGranted) else {
            permissionBlocked.insert(id)
            return
        }
        permissionBlocked.remove(id)
        failures[id] = nil
        let generation = generations[id, default: 0] + 1
        generations[id] = generation
        let scope = SaysoEventScope(bus: events)
        scopes[id] = scope
        let context = SaysoModuleContext(
            moduleID: id,
            publish: { [weak self] in
                guard let self else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                guard self.generations[id] == generation else { return }
                self.state.publish($0, at: self.now())
            },
            reportFailure: { [weak self] in
                guard let self else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                guard self.generations[id] == generation else { return }
                self.recordFailure(id)
            },
            dismiss: { [weak self] stackID in
                guard let self else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                guard self.generations[id] == generation else { return }
                self.state.dismiss(moduleID: id, stackID: stackID)
            },
            events: scope
        )
        let runtime = module.makeRuntime(context: context)
        runtimes[id] = runtime
        runtime.start()
    }

    public func disable(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        permissionBlocked.remove(id)
        guard let runtime = runtimes.removeValue(forKey: id) else { return }
        generations[id, default: 0] += 1
        scopes.removeValue(forKey: id)?.close()
        runtime.stop()
        state.dismissAll(moduleID: id)
    }

    private func recentFailures(_ id: String) -> [Date] {
        let current = now()
        return failures[id, default: []].filter { current.timeIntervalSince($0) < Self.quarantineWindow }
    }

    private func recordFailure(_ id: String) {
        let current = now()
        let recent = recentFailures(id) + [current]
        failures[id] = recent
        if recent.count >= Self.quarantineFailures {
            quarantined.insert(id)
            disable(id)
        }
    }

    /// Routes an action to its owning runtime only if a currently published activity declares it.
    @discardableResult
    public func perform(actionID: String, stackID: String, moduleID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        state.tick(at: now())
        guard let runtime = runtimes[moduleID],
              state.stack.contains(where: {
                  $0.moduleID == moduleID && $0.stackID == stackID && $0.actions.contains { $0.id == actionID }
              })
        else { return false }
        runtime.handle(stackID: stackID, actionID: actionID)
        return true
    }

    public func tick() {
        lock.lock()
        defer { lock.unlock() }
        state.tick(at: now())
    }
    public func pin(moduleID: String, stackID: String) {
        lock.lock()
        defer { lock.unlock() }
        state.pin(moduleID: moduleID, stackID: stackID)
    }
    public func unpin() {
        lock.lock()
        defer { lock.unlock() }
        state.unpin()
    }
    public func dismiss(moduleID: String, stackID: String) {
        lock.lock()
        defer { lock.unlock() }
        state.dismiss(moduleID: moduleID, stackID: stackID)
    }

    /// User-initiated recovery from quarantine; the module stays disabled until enabled again.
    public func clearQuarantine(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        quarantined.remove(id)
        failures[id] = nil
    }

    /// Re-checks running modules after a permission change; any that lost a capability stop.
    public func capabilitiesChanged() {
        lock.lock()
        defer { lock.unlock() }
        for id in Array(runtimes.keys) {
            guard let capabilities = modules[id]?.descriptor.capabilities, !capabilities.allSatisfy(isGranted) else { continue }
            disable(id)
            permissionBlocked.insert(id)
        }
    }
}

private extension SaysoModuleHost {
    func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
