import Foundation

/// Run-level bookkeeping for Control that used to live loose in `SaysoAppModel`: one finish per run,
/// and review answers bound to the exact step that was shown. It talks only through the event bus.
public final class ControlRunCoordinator: @unchecked Sendable {
    public enum Decision: Equatable, Sendable { case approved, denied }

    /// Called on the publishing thread with the decision and the reason of the reviewed step.
    public var onDecision: (@Sendable (Decision, String) -> Void)?

    private let bus: SaysoEventBus
    private let lock = NSLock()
    private var pending: (step: UUID, reason: String)?
    private var announced = true
    private var subscription: SaysoSubscription?

    public init(bus: SaysoEventBus) {
        self.bus = bus
        subscription = bus.subscribe(ControlConfirmationAnswered.self) { [weak self] answer in
            self?.receive(answer)
        }
    }

    /// Starts a run; false while a previous run has not finished.
    @discardableResult
    public func begin(goal: String) -> Bool {
        let started = lock.withLock { () -> Bool in
            guard announced else { return false }
            announced = false
            return true
        }
        if started { bus.publish(ControlRunStarted(goal: goal)) }
        return started
    }

    public func plan(reason: String) { bus.publish(ControlStepPlanned(reason: reason)) }

    /// Shows a review for `reason`; any earlier review is replaced and can no longer be answered.
    @discardableResult
    public func requestReview(reason: String) -> UUID {
        let step = UUID()
        lock.withLock { pending = (step, reason) }
        bus.publish(ControlConfirmationRequired(reason: reason, stepID: step))
        return step
    }

    /// The pending review was approved or discarded through another path (for example the Studio window).
    public func resolveElsewhere() {
        let step = lock.withLock { () -> UUID? in
            defer { pending = nil }
            return pending?.step
        }
        if let step { bus.publish(ControlConfirmationResolved(stepID: step)) }
    }

    /// Announces the end of the run once; later calls for the same run are ignored.
    public func end(_ outcome: ControlRunFinished.Outcome, message: String) {
        resolveElsewhere()
        let first = lock.withLock { () -> Bool in
            guard !announced else { return false }
            announced = true
            return true
        }
        if first { bus.publish(ControlRunFinished(outcome: outcome, message: message)) }
    }

    /// True while a review is waiting for an answer.
    public var hasPendingReview: Bool { lock.withLock { pending != nil } }

    private func receive(_ answer: ControlConfirmationAnswered) {
        let reviewed = lock.withLock { () -> String? in
            guard let current = pending, current.step == answer.stepID else { return nil }
            pending = nil
            return current.reason
        }
        guard let reviewed else { return }
        onDecision?(answer.approved ? .approved : .denied, reviewed)
    }
}
