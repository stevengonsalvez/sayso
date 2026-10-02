import Foundation

public struct ModelsModule: SaysoModule {
    public let descriptor = SaysoModuleDescriptor(
        id: "models", title: "Models", capabilities: [.network], surfaces: [.compact, .expanded, .settings]
    )

    public init() {}

    public func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime { Runtime(context: context) }

    private static let completionSeconds: TimeInterval = 5

    private final class Runtime: SaysoModuleRuntime, SaysoResourceAccounting, @unchecked Sendable {
        let context: SaysoModuleContext
        private let lock = NSLock()
        private var subscriptions: [SaysoSubscription] = []

        init(context: SaysoModuleContext) { self.context = context }

        var retainedResources: Int { lock.withLock { subscriptions.count } }

        func start() {
            let made = [
                context.subscribe(ModelInstallProgress.self) { [context] event in
                    context.publish(
                        stackID: "install-\(event.modelID)", kind: .activeTask,
                        title: "Downloading \(event.displayName)", progress: event.fraction
                    )
                },
                context.subscribe(ModelInstallFinished.self) { [context] event in
                    // Clear first so an expiring notice never shadows (and later restores) the finished download.
                    context.dismiss(stackID: "install-\(event.modelID)")
                    if event.succeeded {
                        context.publish(
                            stackID: "install-\(event.modelID)", kind: .completion,
                            title: "\(event.displayName) ready", expiresAfter: ModelsModule.completionSeconds
                        )
                    } else {
                        context.publish(
                            stackID: "install-\(event.modelID)", kind: .failure,
                            title: "\(event.displayName) download failed",
                            actions: [SaysoAction(id: "retry", title: "Retry")]
                        )
                    }
                },
            ].compactMap { $0 }
            lock.withLock { subscriptions = made }
        }

        func stop() {
            let pending = lock.withLock { () -> [SaysoSubscription] in
                defer { subscriptions = [] }
                return subscriptions
            }
            pending.forEach { $0.cancel() }
        }

        func handle(stackID: String, actionID: String) {
            guard actionID == "retry", stackID.hasPrefix("install-") else { return }
            context.emit(ModelInstallRetryRequested(modelID: String(stackID.dropFirst("install-".count))))
            context.dismiss(stackID: stackID)
        }
    }
}
