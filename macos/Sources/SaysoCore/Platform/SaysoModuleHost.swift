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

    private static let quarantineWindow: TimeInterval = 300
    private static let quarantineFailures = 3

    public init(
        modules: [SaysoModule],
        now: @escaping @Sendable () -> Date = { Date() },
        isGranted: @escaping @Sendable (SaysoCapability) -> Bool = { _ in true }
    ) {
        self.now = now
        self.isGranted = isGranted
        self.modules = Dictionary(uniqueKeysWithValues: modules.map { ($0.descriptor.id, $0) })
    }

    public func health(of id: String) -> SaysoModuleHealth {
        if quarantined.contains(id) { return .quarantined }
        if permissionBlocked.contains(id) { return .permissionRequired }
        if runtimes[id] == nil { return .disabled }
        return failures[id, default: []].isEmpty ? .ready : .degraded
    }

    public func enable(_ id: String) {
        guard runtimes[id] == nil, !quarantined.contains(id), let module = modules[id] else { return }
        guard module.descriptor.capabilities.allSatisfy(isGranted) else {
            permissionBlocked.insert(id)
            return
        }
        permissionBlocked.remove(id)
        let context = SaysoModuleContext(
            moduleID: id,
            publish: { [weak self] in self?.engine.publish($0) },
            reportFailure: { [weak self] in self?.recordFailure(id) }
        )
        let runtime = module.makeRuntime(context: context)
        runtimes[id] = runtime
        runtime.start()
    }

    public func disable(_ id: String) {
        guard let runtime = runtimes.removeValue(forKey: id) else { return }
        runtime.stop()
        engine.dismissAll(moduleID: id)
    }

    private func recordFailure(_ id: String) {
        let current = now()
        let recent = failures[id, default: []].filter { current.timeIntervalSince($0) < Self.quarantineWindow } + [current]
        failures[id] = recent
        if recent.count >= Self.quarantineFailures {
            quarantined.insert(id)
            disable(id)
        }
    }
}
