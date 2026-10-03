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

    public enum PublishResult: Equatable, Sendable { case published, unavailable, limitReached }

    /// `.unavailable` while the module is disabled or stopped; `.limitReached` for a new stack beyond `maxStacks`.
    @discardableResult
    public func publish(
        stackID: String, kind: SaysoActivityKind, title: String, expiresAfter: TimeInterval?, maxStacks: Int = .max
    ) -> PublishResult {
        guard let runtime = lock.withLock({ runtime }), runtime.isActive else { return .unavailable }
        guard runtime.reserve(stackID, limit: maxStacks) else { return .limitReached }
        runtime.context.publish(stackID: stackID, kind: kind, title: title, expiresAfter: expiresAfter)
        return .published
    }

    @discardableResult
    public func clear(stackID: String) -> Bool {
        guard let runtime = lock.withLock({ runtime }), runtime.isActive else { return false }
        runtime.release(stackID)
        runtime.context.dismiss(stackID: stackID)
        return true
    }

    private final class Runtime: SaysoModuleRuntime, SaysoResourceAccounting, @unchecked Sendable {
        let context: SaysoModuleContext
        private let lock = NSLock()
        private var active = false
        private var stacks: Set<String> = []
        init(context: SaysoModuleContext) { self.context = context }
        var isActive: Bool { lock.withLock { active } }
        var retainedResources: Int { 0 }
        func start() { lock.withLock { active = true } }
        func stop() { lock.withLock { active = false; stacks = [] } }

        func reserve(_ stackID: String, limit: Int) -> Bool {
            lock.withLock {
                if stacks.contains(stackID) { return true }
                guard stacks.count < limit else { return false }
                stacks.insert(stackID)
                return true
            }
        }

        func release(_ stackID: String) { lock.withLock { _ = stacks.remove(stackID) } }
    }
}
