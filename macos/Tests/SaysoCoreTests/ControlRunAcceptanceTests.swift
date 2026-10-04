import Foundation
import Testing
@testable import SaysoCore

/// Text-in acceptance for one Control run, wiring the real module, host, bus and coordinator.
/// Only the planner and the desktop executor are faked, so no speech, Jev or Accessibility is involved.
private final class Executor: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [String] = []
    var executed: [String] { lock.withLock { steps } }
    func run(_ reason: String) { lock.withLock { steps.append(reason) } }
}

private struct Harness {
    let host: SaysoModuleHost
    let bus: SaysoEventBus
    let coordinator: ControlRunCoordinator
    let executor: Executor
    let finishes: Finishes

    final class Finishes: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [ControlRunFinished] = []
        func add(_ finish: ControlRunFinished) { lock.withLock { all.append(finish) } }
        var values: [ControlRunFinished] { lock.withLock { all } }
    }

    init() {
        bus = SaysoEventBus()
        host = SaysoModuleHost(modules: [ControlModule()], events: bus)
        host.enable("control")
        executor = Executor()
        finishes = Finishes()
        coordinator = ControlRunCoordinator(bus: bus)
        let executor = self.executor
        _ = bus.subscribe(ControlRunFinished.self) { [finishes] in finishes.add($0) }
        // The app routes approved answers to its guarded executor; here the executor just records.
        coordinator.onDecision = { decision, reason in
            if decision == .approved { executor.run(reason) }
        }
    }

    var cards: [String] { host.engine.stack.map(\.stackID) }
}

@Test func denyingAReviewExecutesNothingAndTheRunFinishesExactlyOnce() {
    let h = Harness()
    #expect(h.coordinator.begin(goal: "Delete the file"))
    h.coordinator.plan(reason: "Move file to Trash")
    h.coordinator.requestReview(reason: "Move file to Trash")

    let review = h.host.engine.primary
    #expect(review?.interruption == .critical)
    let deny = review?.actions.first { $0.id.hasPrefix("deny-") }
    #expect(h.host.perform(actionID: deny!.id, stackID: "confirmation", moduleID: "control"))

    #expect(h.executor.executed.isEmpty)
    #expect(!h.cards.contains("confirmation"))

    h.coordinator.end(.cancelled, message: "Action discarded")
    h.coordinator.end(.completed, message: "late completion")
    #expect(h.finishes.values == [ControlRunFinished(outcome: .cancelled, message: "Action discarded")])
}

@Test func approvingAReviewExecutesTheReviewedStepOnce() {
    let h = Harness()
    _ = h.coordinator.begin(goal: "Open Calculator")
    h.coordinator.requestReview(reason: "Open Calculator app")

    let approve = h.host.engine.primary?.actions.first { $0.id.hasPrefix("approve-") }
    #expect(h.host.perform(actionID: approve!.id, stackID: "confirmation", moduleID: "control"))
    #expect(!h.host.perform(actionID: approve!.id, stackID: "confirmation", moduleID: "control"))

    #expect(h.executor.executed == ["Open Calculator app"])
    h.coordinator.end(.completed, message: "Verified Calculator")
    #expect(h.finishes.values.map(\.outcome) == [.completed])
}

@Test func aStaleApproveForAReplacedStepNeverExecutesTheNewStep() {
    let h = Harness()
    _ = h.coordinator.begin(goal: "Clean up")
    h.coordinator.requestReview(reason: "Step A")
    let staleApprove = h.host.engine.primary!.actions.first { $0.id.hasPrefix("approve-") }!
    h.coordinator.requestReview(reason: "Step B")

    #expect(!h.host.perform(actionID: staleApprove.id, stackID: "confirmation", moduleID: "control"))
    #expect(h.executor.executed.isEmpty)
    // A forged answer for the old step is also rejected by the coordinator itself.
    h.bus.publish(ControlConfirmationAnswered(approved: true, stepID: UUID()))
    #expect(h.executor.executed.isEmpty)
}

@Test func approvingElsewhereDismissesTheCardAndAnAnswerAfterwardsDoesNothing() {
    let h = Harness()
    _ = h.coordinator.begin(goal: "Open Calculator")
    h.coordinator.requestReview(reason: "Open Calculator app")
    let approve = h.host.engine.primary!.actions.first { $0.id.hasPrefix("approve-") }!

    h.coordinator.resolveElsewhere()
    #expect(!h.cards.contains("confirmation"))
    #expect(!h.host.perform(actionID: approve.id, stackID: "confirmation", moduleID: "control"))
    #expect(h.executor.executed.isEmpty)
}

@Test func cancellingMidRunAnnouncesOnceAndALateCompletionIsIgnored() {
    let h = Harness()
    _ = h.coordinator.begin(goal: "Open Calculator")
    #expect(h.host.perform(actionID: "cancel", stackID: "run", moduleID: "control"))

    h.coordinator.end(.cancelled, message: "Cancellation requested")
    h.coordinator.end(.failed, message: "Control stopped")
    h.coordinator.end(.completed, message: "Verified")

    #expect(h.finishes.values.count == 1)
    #expect(h.finishes.values.first?.outcome == .cancelled)
    #expect(h.cards.isEmpty)
}

@Test func aNewRunAfterAFinishIsAnnouncedAgainAndABusyRunRefusesASecond() {
    let h = Harness()
    #expect(h.coordinator.begin(goal: "First"))
    #expect(!h.coordinator.begin(goal: "Second while active"))
    h.coordinator.end(.completed, message: "done 1")

    #expect(h.coordinator.begin(goal: "Third"))
    h.coordinator.end(.failed, message: "stopped")
    #expect(h.finishes.values.map(\.message) == ["done 1", "stopped"])
}
