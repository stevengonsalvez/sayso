import Foundation

/// Asked by the dictation module's Stop action; the session owner stops the transcriber.
public struct DictationStopRequested: SaysoEvent, Equatable {
    public init() {}
}

/// Surfaces the dictation session as an activity driven only by lifecycle events.
public struct DictationModule: SaysoModule {
    public let descriptor = SaysoModuleDescriptor(
        id: "dictation", title: "Dictation", capabilities: [.microphone],
        surfaces: [.compact, .expanded, .detail, .settings]
    )

    public init() {}

    public func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        Runtime(context: context)
    }

    private final class Runtime: SaysoModuleRuntime, SaysoResourceAccounting, @unchecked Sendable {
        private static let failureSeconds: TimeInterval = 6

        let context: SaysoModuleContext
        private let lock = NSLock()
        private var subscription: SaysoSubscription?

        init(context: SaysoModuleContext) { self.context = context }

        var retainedResources: Int { lock.withLock { subscription == nil ? 0 : 1 } }

        func start() {
            let made = context.subscribe(DictationLifecycleEvent.self) { [weak self] in self?.apply($0) }
            lock.withLock { subscription = made }
        }

        func stop() {
            lock.withLock { () -> SaysoSubscription? in
                defer { subscription = nil }
                return subscription
            }?.cancel()
        }

        func handle(stackID: String, actionID: String) {
            if stackID == "session", actionID == "stop" { context.emit(DictationStopRequested()) }
        }

        private func apply(_ event: DictationLifecycleEvent) {
            switch event {
            case .listening:
                context.publish(
                    stackID: "session", kind: .activeTask, title: "Listening",
                    actions: [SaysoAction(id: "stop", title: "Stop")]
                )
            case .processing:
                context.publish(stackID: "session", kind: .activeTask, title: "Transcribing")
            case .ended(let ending):
                context.dismiss(stackID: "session")
                if ending == .failed {
                    context.publish(
                        stackID: "outcome", kind: .failure, title: "Dictation failed",
                        expiresAfter: Self.failureSeconds
                    )
                }
            }
        }
    }
}
