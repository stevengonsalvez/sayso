import Foundation

/// Injected platform services; the only way a module touches the rest of Sayso.
public struct SaysoModuleContext: Sendable {
    public let moduleID: String
    private let publishActivity: @Sendable (SaysoActivity) -> Void

    public init(moduleID: String, publish: @escaping @Sendable (SaysoActivity) -> Void) {
        self.moduleID = moduleID
        self.publishActivity = publish
    }

    public func publish(stackID: String, kind: SaysoActivityKind, title: String, expiresAfter: TimeInterval? = nil) {
        publishActivity(SaysoActivity(moduleID: moduleID, stackID: stackID, kind: kind, title: title, expiresAfter: expiresAfter))
    }
}

public protocol SaysoModuleRuntime: AnyObject, Sendable {
    func start()
    /// Must release every observer, timer, hook, socket and retained resource.
    func stop()
}

public protocol SaysoModule: Sendable {
    var descriptor: SaysoModuleDescriptor { get }
    func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime
}
