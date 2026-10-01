import Foundation

/// Injected platform services; the only way a module touches the rest of Sayso.
public struct SaysoModuleContext: Sendable {
    public let moduleID: String
    private let publishActivity: @Sendable (SaysoActivity) -> Void
    private let failure: @Sendable () -> Void

    public init(
        moduleID: String,
        publish: @escaping @Sendable (SaysoActivity) -> Void,
        reportFailure: @escaping @Sendable () -> Void = {}
    ) {
        self.moduleID = moduleID
        self.publishActivity = publish
        self.failure = reportFailure
    }

    /// Three failures within five minutes quarantine this module only.
    public func reportFailure() { failure() }

    public func publish(
        stackID: String,
        kind: SaysoActivityKind,
        title: String,
        expiresAfter: TimeInterval? = nil,
        actions: [SaysoAction] = []
    ) {
        publishActivity(
            SaysoActivity(
                moduleID: moduleID, stackID: stackID, kind: kind, title: title,
                expiresAfter: expiresAfter, actions: actions
            )
        )
    }
}

public protocol SaysoModuleRuntime: AnyObject, Sendable {
    func start()
    /// Must release every observer, timer, hook, socket and retained resource.
    func stop()
    /// Called only for actions declared on one of this module's published activities.
    func handle(actionID: String)
}

public extension SaysoModuleRuntime {
    func handle(actionID: String) {}
}

public protocol SaysoModule: Sendable {
    var descriptor: SaysoModuleDescriptor { get }
    func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime
}
