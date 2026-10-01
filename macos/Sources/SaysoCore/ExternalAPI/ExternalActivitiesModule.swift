import Foundation

/// Lets trusted local scripts show activities; the only module the external API may publish through.
public final class ExternalActivitiesModule: SaysoModule, @unchecked Sendable {
    public let descriptor = SaysoModuleDescriptor(
        id: "external", title: "Local scripts", capabilities: [.automation], surfaces: [.compact, .settings]
    )
    private let lock = NSLock()
    private var runtime: Runtime?

    public init() {}

    public func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        let runtime = Runtime(context: context)
        lock.withLock { self.runtime = runtime }
        return runtime
    }

    /// False while the module is disabled or stopped.
    @discardableResult
    public func publish(stackID: String, kind: SaysoActivityKind, title: String, expiresAfter: TimeInterval?) -> Bool {
        guard let runtime = lock.withLock({ runtime }), runtime.isActive else { return false }
        runtime.context.publish(stackID: stackID, kind: kind, title: title, expiresAfter: expiresAfter)
        return true
    }

    @discardableResult
    public func clear(stackID: String) -> Bool {
        guard let runtime = lock.withLock({ runtime }), runtime.isActive else { return false }
        runtime.context.dismiss(stackID: stackID)
        return true
    }

    private final class Runtime: SaysoModuleRuntime, SaysoResourceAccounting, @unchecked Sendable {
        let context: SaysoModuleContext
        private let lock = NSLock()
        private var active = false
        init(context: SaysoModuleContext) { self.context = context }
        var isActive: Bool { lock.withLock { active } }
        var retainedResources: Int { 0 }
        func start() { lock.withLock { active = true } }
        func stop() { lock.withLock { active = false } }
    }
}
