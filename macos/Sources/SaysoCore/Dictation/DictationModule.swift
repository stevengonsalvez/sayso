import Foundation

/// Mirrors dictation phases as one live activity; the pipeline itself stays with its owner.
public struct DictationModule: SaysoModule {
    public let descriptor = SaysoModuleDescriptor(
        id: "dictation", title: "Dictation", capabilities: [.microphone],
        surfaces: [.compact, .peek, .expanded, .settings]
    )
    private static let failureSeconds: TimeInterval = 8

    public init() {}

    public func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime { Runtime(context: context) }

    private final class Runtime: SaysoModuleRuntime, SaysoResourceAccounting, @unchecked Sendable {
        let context: SaysoModuleContext
        private let lock = NSLock()
        private var subscription: SaysoSubscription?

        init(context: SaysoModuleContext) { self.context = context }

        var retainedResources: Int { lock.withLock { subscription == nil ? 0 : 1 } }

        func start() {
            let made = context.subscribe(DictationPhaseChanged.self) { [context] event in
                // Dismiss first so a failure notice that expires never restores an older phase.
                context.dismiss(stackID: "dictation")
                switch event.phase {
                case .requestingPermission:
                    context.publish(stackID: "dictation", kind: .activeTask, title: "Waiting for microphone permission")
                case .listening:
                    context.publish(stackID: "dictation", kind: .activeTask, title: "Listening")
                case .processing:
                    context.publish(stackID: "dictation", kind: .activeTask, title: "Transcribing")
                case .failed:
                    context.publish(
                        stackID: "dictation", kind: .failure, title: event.errorMessage ?? "Dictation failed",
                        expiresAfter: DictationModule.failureSeconds
                    )
                case .idle, .speaking:
                    break
                }
            }
            lock.withLock { subscription = made }
        }

        func stop() {
            let made = lock.withLock { () -> SaysoSubscription? in
                defer { subscription = nil }
                return subscription
            }
            made?.cancel()
        }
    }
}
