import Foundation

/// Injected platform services; the only way a module touches the rest of Sayso.
public struct SaysoModuleContext: Sendable {
    public let moduleID: String
    private let publishActivity: @Sendable (SaysoActivity) -> Void
    private let failure: @Sendable () -> Void
    private let dismissStack: @Sendable (String) -> Void
    private let events: SaysoEventScope?

    public init(
        moduleID: String,
        publish: @escaping @Sendable (SaysoActivity) -> Void,
        reportFailure: @escaping @Sendable () -> Void = {},
        dismiss: @escaping @Sendable (String) -> Void = { _ in },
        events: SaysoEventScope? = nil
    ) {
        self.moduleID = moduleID
        self.publishActivity = publish
        self.failure = reportFailure
        self.dismissStack = dismiss
        self.events = events
    }

    /// Removes this module's activity on `stackID`.
    public func dismiss(stackID: String) { dismissStack(stackID) }

    /// Emits a platform event; dropped once this runtime is stopped.
    public func emit<E: SaysoEvent>(_ event: E) { events?.emit(event) }

    /// Subscriptions are cancelled by the host when the module stops.
    @discardableResult
    public func subscribe<E: SaysoEvent>(_ type: E.Type, handler: @escaping @Sendable (E) -> Void) -> SaysoSubscription? {
        events?.subscribe(type, handler: handler)
    }

    /// Three failures within five minutes quarantine this module only.
    public func reportFailure() { failure() }

    public func publish(
        stackID: String,
        kind: SaysoActivityKind,
        title: String,
        expiresAfter: TimeInterval? = nil,
        actions: [SaysoAction] = [],
        interruption: SaysoInterruptionPolicy = .normal,
        progress: Double? = nil
    ) {
        publishActivity(
            SaysoActivity(
                moduleID: moduleID, stackID: stackID, kind: kind, title: title,
                expiresAfter: expiresAfter, actions: actions, interruption: interruption, progress: progress
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
