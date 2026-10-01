import Foundation

/// Owns module lifecycles and the shared activity engine.
// ponytail: single-threaded by contract (main actor callers), no lock; add one if modules publish off-thread.
public final class SaysoModuleHost: @unchecked Sendable {
    public private(set) var engine = SaysoActivityEngine()
    private let modules: [String: SaysoModule]
    private var runtimes: [String: SaysoModuleRuntime] = [:]

    public init(modules: [SaysoModule]) {
        self.modules = Dictionary(uniqueKeysWithValues: modules.map { ($0.descriptor.id, $0) })
    }

    public func health(of id: String) -> SaysoModuleHealth {
        runtimes[id] == nil ? .disabled : .ready
    }

    public func enable(_ id: String) {
        guard runtimes[id] == nil, let module = modules[id] else { return }
        let context = SaysoModuleContext(moduleID: id) { [weak self] activity in
            self?.engine.publish(activity)
        }
        let runtime = module.makeRuntime(context: context)
        runtimes[id] = runtime
        runtime.start()
    }

    public func disable(_ id: String) {
        guard let runtime = runtimes.removeValue(forKey: id) else { return }
        runtime.stop()
        engine.dismissAll(moduleID: id)
    }
}
