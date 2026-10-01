import Foundation

/// Injected platform services; the only way a module touches the rest of Sayso.
public struct SaysoModuleContext: Sendable {
    public let moduleID: String
    private let publishActivity: @Sendable (SaysoActivity) -> Void
    private let failure: @Sendable () -> Void
    private let dismissStack: @Sendable (String) -> Void

    public init(
        moduleID: String,
        publish: @escaping @Sendable (SaysoActivity) -> Void,
        reportFailure: @escaping @Sendable () -> Void = {},
        dismiss: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.moduleID = moduleID
        self.publishActivity = publish
        self.failure = reportFailure
        self.dismissStack = dismiss
    }

    /// Removes this module's activity on `stackID`.
    public func dismiss(stackID: String) { dismissStack(stackID) }

    /// Three failures within five minutes quarantine this module only.
    public func reportFailure() { failure() }

    public func publish(
        stackID: String,
        kind: SaysoActivityKind,
        title: String,
        expiresAfter: TimeInterval? = nil,
        actions: [SaysoAction] = [],
        interruption: SaysoInterruptionPolicy = .normal
    ) {
        publishActivity(
            SaysoActivity(
                moduleID: moduleID, stackID: stackID, kind: kind, title: title,
                expiresAfter: expiresAfter, actions: actions, interruption: interruption
            )
        )
    }
}

public protocol SaysoModuleRuntime: AnyObject, Sendable {
    func start()
    /// Must release every observer, timer, hook, socket and retained resource.
    func stop()
    /// Called only for actions declared on one of this module's published activities.
    func handle(stackID: String, actionID: String)
}

public extension SaysoModuleRuntime {
    func handle(stackID: String, actionID: String) {}
}

public protocol SaysoModule: Sendable {
    var descriptor: SaysoModuleDescriptor { get }
    func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime
}
