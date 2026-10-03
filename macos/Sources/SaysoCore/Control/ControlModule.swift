import Foundation

/// Surfaces a Control run, its clarification and its confirmation as activities and reports the user's answers.
public struct ControlModule: SaysoModule {
    public let descriptor = SaysoModuleDescriptor(
        id: "control", title: "Control", capabilities: [.accessibility],
        surfaces: [.compact, .expanded, .detail, .settings]
    )

    public init() {}

    public func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        Runtime(context: context)
    }

    private final class Runtime: SaysoModuleRuntime, SaysoResourceAccounting, @unchecked Sendable {
        private static let completedSeconds: TimeInterval = 5
        private static let failedSeconds: TimeInterval = 8

        let context: SaysoModuleContext
        private let lock = NSLock()
        private var subscriptions: [SaysoSubscription] = []
        private var choices: [String] = []
        private var reviewStep: UUID?

        init(context: SaysoModuleContext) { self.context = context }

        var retainedResources: Int { lock.withLock { subscriptions.count } }

        func start() {
            let made = [
                context.subscribe(ControlRunStarted.self) { [weak self] in self?.showRun($0.goal) },
                context.subscribe(ControlStepPlanned.self) { [weak self] in self?.showRun($0.reason) },
                context.subscribe(ControlClarificationAsked.self) { [weak self] in self?.ask($0) },
                context.subscribe(ControlConfirmationRequired.self) { [weak self] in self?.review($0) },
                context.subscribe(ControlConfirmationResolved.self) { [weak self] in self?.resolve($0.stepID) },
                context.subscribe(ControlRunFinished.self) { [weak self] in self?.finish($0) },
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
            switch (stackID, actionID) {
            case ("run", "cancel"):
                context.emit(ControlCancelRequested())
            case ("confirmation", _) where actionID.hasPrefix("approve-") || actionID.hasPrefix("deny-"):
                let approved = actionID.hasPrefix("approve-")
                guard let step = UUID(uuidString: String(actionID.dropFirst(approved ? "approve-".count : "deny-".count))),
                      lock.withLock({ reviewStep == step }) else { return }
                lock.withLock { reviewStep = nil }
                context.dismiss(stackID: "confirmation")
                context.emit(ControlConfirmationAnswered(approved: approved, stepID: step))
            case ("clarification", _) where actionID.hasPrefix("choice-"):
                guard let index = Int(actionID.dropFirst("choice-".count)),
                      let choice = lock.withLock({ choices.indices.contains(index) ? choices[index] : nil }) else { return }
                context.dismiss(stackID: "clarification")
                context.emit(ControlClarificationChosen(choice: choice))
            default:
                break
            }
        }

        private func showRun(_ text: String) {
            context.publish(
                stackID: "run", kind: .activeTask, title: "Control: \(text)",
                actions: [SaysoAction(id: "cancel", title: "Cancel")]
            )
        }

        private func ask(_ question: ControlClarificationAsked) {
            lock.withLock { choices = question.choices }
            context.publish(
                stackID: "clarification", kind: .confirmation, title: question.question,
                expiresAfter: ControlClarification.maximumAge,
                actions: question.choices.enumerated().map { SaysoAction(id: "choice-\($0.offset)", title: $0.element) }
            )
        }

        private func review(_ request: ControlConfirmationRequired) {
            lock.withLock { reviewStep = request.stepID }
            context.publish(
                stackID: "confirmation", kind: .confirmation, title: "Review required: \(request.reason)",
                actions: [
                    SaysoAction(id: "approve-\(request.stepID)", title: "Approve"),
                    SaysoAction(id: "deny-\(request.stepID)", title: "Deny"),
                ],
                interruption: .critical
            )
        }

        private func resolve(_ step: UUID) {
            guard lock.withLock({ () -> Bool in
                guard reviewStep == step else { return false }
                reviewStep = nil
                return true
            }) else { return }
            context.dismiss(stackID: "confirmation")
        }

        private func finish(_ result: ControlRunFinished) {
            for stack in ["run", "clarification", "confirmation"] { context.dismiss(stackID: stack) }
            lock.withLock { choices = []; reviewStep = nil }
            switch result.outcome {
            case .completed:
                context.publish(stackID: "outcome", kind: .completion, title: result.message, expiresAfter: Self.completedSeconds)
            case .failed:
                context.publish(stackID: "outcome", kind: .failure, title: result.message, expiresAfter: Self.failedSeconds)
            case .cancelled:
                context.dismiss(stackID: "outcome")
            }
        }
    }
}
