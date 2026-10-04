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
        guard runtime.reserve(stackID, expiresAfter: expiresAfter, limit: maxStacks) else { return .limitReached }
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
        /// Stack id to the moment its activity expires (`.distantFuture` when persistent), so expired stacks free their slot.
        private var stacks: [String: Date] = [:]
        init(context: SaysoModuleContext) { self.context = context }
        var isActive: Bool { lock.withLock { active } }
        var retainedResources: Int { 0 }
        func start() { lock.withLock { active = true } }
        func stop() { lock.withLock { active = false; stacks = [:] } }

        func reserve(_ stackID: String, expiresAfter: TimeInterval?, limit: Int) -> Bool {
            lock.withLock {
                let now = Date()
                stacks = stacks.filter { $0.value > now }
                if stacks[stackID] == nil, stacks.count >= limit { return false }
                stacks[stackID] = expiresAfter.map { now.addingTimeInterval($0) } ?? .distantFuture
                return true
            }
        }

        func release(_ stackID: String) { lock.withLock { stacks[stackID] = nil } }
    }
}
