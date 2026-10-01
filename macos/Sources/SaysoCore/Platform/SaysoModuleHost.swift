import Foundation

/// Owns module lifecycles and the shared activity engine.
// ponytail: single-threaded by contract (main actor callers), no lock; add one if modules publish off-thread.
public final class SaysoModuleHost: @unchecked Sendable {
    public private(set) var engine = SaysoActivityEngine()
    private let modules: [String: SaysoModule]
    private var runtimes: [String: SaysoModuleRuntime] = [:]
    private var failures: [String: [Date]] = [:]
    private var quarantined: Set<String> = []
    private let now: @Sendable () -> Date
    private let isGranted: @Sendable (SaysoCapability) -> Bool
    private var permissionBlocked: Set<String> = []
    private var generations: [String: Int] = [:]

    private static let quarantineWindow: TimeInterval = 300
    private static let quarantineFailures = 3

    public var descriptors: [SaysoModuleDescriptor] { order.map(\.descriptor) }
    private let order: [SaysoModule]

    public init(
        modules: [SaysoModule],
        now: @escaping @Sendable () -> Date = { Date() },
        isGranted: @escaping @Sendable (SaysoCapability) -> Bool = { _ in true }
    ) {
        self.now = now
        self.isGranted = isGranted
        var seen = Set<String>()
        let unique = modules.filter { seen.insert($0.descriptor.id).inserted }
        self.order = unique
        self.modules = Dictionary(uniqueKeysWithValues: unique.map { ($0.descriptor.id, $0) })
    }

    public func health(of id: String) -> SaysoModuleHealth {
        if quarantined.contains(id) { return .quarantined }
        if permissionBlocked.contains(id) { return .permissionRequired }
        if runtimes[id] == nil { return .disabled }
        return recentFailures(id).isEmpty ? .ready : .degraded
    }

    public func enable(_ id: String) {
        guard runtimes[id] == nil, !quarantined.contains(id), let module = modules[id] else { return }
        guard module.descriptor.capabilities.allSatisfy(isGranted) else {
            permissionBlocked.insert(id)
            return
        }
        permissionBlocked.remove(id)
        failures[id] = nil
        let generation = generations[id, default: 0] + 1
        generations[id] = generation
        let context = SaysoModuleContext(
            moduleID: id,
            publish: { [weak self] in
                guard let self, self.generations[id] == generation else { return }
                self.engine.publish($0, at: self.now())
            },
            reportFailure: { [weak self] in
                guard let self, self.generations[id] == generation else { return }
                self.recordFailure(id)
            }
        )
        let runtime = module.makeRuntime(context: context)
        runtimes[id] = runtime
        runtime.start()
    }

    public func disable(_ id: String) {
        permissionBlocked.remove(id)
        guard let runtime = runtimes.removeValue(forKey: id) else { return }
        generations[id, default: 0] += 1
        runtime.stop()
        engine.dismissAll(moduleID: id)
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
        engine.tick(at: now())
        guard let runtime = runtimes[moduleID],
              engine.stack.contains(where: {
                  $0.moduleID == moduleID && $0.stackID == stackID && $0.actions.contains { $0.id == actionID }
              })
        else { return false }
        runtime.handle(stackID: stackID, actionID: actionID)
        return true
    }

    public func tick() { engine.tick(at: now()) }
    public func pin(moduleID: String, stackID: String) { engine.pin(moduleID: moduleID, stackID: stackID) }
    public func unpin() { engine.unpin() }
    public func dismiss(moduleID: String, stackID: String) { engine.dismiss(moduleID: moduleID, stackID: stackID) }

    /// User-initiated recovery from quarantine; the module stays disabled until enabled again.
    public func clearQuarantine(_ id: String) {
        quarantined.remove(id)
        failures[id] = nil
    }

    /// Re-checks running modules after a permission change; any that lost a capability stop.
    public func capabilitiesChanged() {
        for id in Array(runtimes.keys) {
            guard let capabilities = modules[id]?.descriptor.capabilities, !capabilities.allSatisfy(isGranted) else { continue }
            disable(id)
            permissionBlocked.insert(id)
        }
    }
}
