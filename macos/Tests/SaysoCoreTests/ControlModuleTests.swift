import Foundation
import Testing
@testable import SaysoCore

private final class Answers: @unchecked Sendable {
    var cancels = 0
    var confirmations: [Bool] = []
    var answeredSteps: [UUID] = []
    var choices: [String] = []
}

private func setup() -> (SaysoModuleHost, SaysoEventBus, Answers) {
    let bus = SaysoEventBus(), answers = Answers()
    _ = bus.subscribe(ControlCancelRequested.self) { _ in answers.cancels += 1 }
    _ = bus.subscribe(ControlConfirmationAnswered.self) {
        answers.confirmations.append($0.approved)
        answers.answeredSteps.append($0.stepID)
    }
    _ = bus.subscribe(ControlClarificationChosen.self) { answers.choices.append($0.choice) }
    let host = SaysoModuleHost(modules: [ControlModule()], events: bus)
    host.enable("control")
    return (host, bus, answers)
}

@Test func runShowsACancellableActivityThatFollowsPlanning() {
    let (host, bus, answers) = setup()
    bus.publish(ControlRunStarted(goal: "Open Calculator"))
    #expect(host.engine.stack.map(\.title) == ["Control: Open Calculator"])
    #expect(host.engine.stack.first?.kind == .activeTask)

    bus.publish(ControlStepPlanned(reason: "Open Calculator app"))
    #expect(host.engine.stack.map(\.title) == ["Control: Open Calculator app"])

    #expect(host.perform(actionID: "cancel", stackID: "run", moduleID: "control"))
    #expect(answers.cancels == 1)
}

@Test func clarificationOffersOneActionPerChoiceAndExpiresWithTheSessionRule() {
    let (host, bus, answers) = setup()
    bus.publish(ControlClarificationAsked(question: "Which one: Steve, Steven?", choices: ["Steve", "Steven"], askedAt: Date()))

    let ask = host.engine.stack.first
    #expect(ask?.title == "Which one: Steve, Steven?")
    #expect(ask?.kind == .confirmation)
    #expect(ask?.interruption == .normal)
    #expect(ask?.actions.map(\.title) == ["Steve", "Steven"])
    #expect(ask?.expiresAfter == ControlClarification.maximumAge)

    #expect(host.perform(actionID: "choice-1", stackID: "clarification", moduleID: "control"))
    #expect(answers.choices == ["Steven"])
    #expect(host.engine.stack.isEmpty)
}

@Test func requiredConfirmationIsCriticalAndAnswersAreBoundToTheStep() {
    let (host, bus, answers) = setup()
    let step = UUID()
    bus.publish(ControlConfirmationRequired(reason: "Delete file", stepID: step))

    let review = host.engine.stack.first
    #expect(review?.title == "Review required: Delete file")
    #expect(review?.kind == .confirmation)
    #expect(review?.interruption == .critical)
    #expect(review?.actions.map(\.id) == ["approve-\(step)", "deny-\(step)"])

    #expect(host.perform(actionID: "approve-\(step)", stackID: "confirmation", moduleID: "control"))
    #expect(answers.confirmations == [true])
    #expect(answers.answeredSteps == [step])
    #expect(host.engine.stack.isEmpty)

    let next = UUID()
    bus.publish(ControlConfirmationRequired(reason: "Delete file", stepID: next))
    #expect(host.perform(actionID: "deny-\(next)", stackID: "confirmation", moduleID: "control"))
    #expect(answers.confirmations == [true, false])
}

@Test func aStaleApproveForAReplacedStepIsRejectedAndNeverAnswered() {
    let (host, bus, answers) = setup()
    let stepA = UUID(), stepB = UUID()
    bus.publish(ControlConfirmationRequired(reason: "A", stepID: stepA))
    bus.publish(ControlConfirmationRequired(reason: "B", stepID: stepB))

    #expect(!host.perform(actionID: "approve-\(stepA)", stackID: "confirmation", moduleID: "control"))
    #expect(answers.confirmations.isEmpty)
    #expect(host.engine.stack.first?.title == "Review required: B")
}

@Test func resolvingAStepElsewhereDismissesItsCardButNotANewerOne() {
    let (host, bus, _) = setup()
    let stepA = UUID(), stepB = UUID()
    bus.publish(ControlConfirmationRequired(reason: "A", stepID: stepA))
    bus.publish(ControlConfirmationResolved(stepID: stepA))
    #expect(host.engine.stack.isEmpty)

    bus.publish(ControlConfirmationRequired(reason: "B", stepID: stepB))
    bus.publish(ControlConfirmationResolved(stepID: stepA))
    #expect(host.engine.stack.first?.title == "Review required: B")
}

@Test func finishClearsPromptsAndLeavesAnExpiringOutcome() {
    let (host, bus, answers) = setup()
    bus.publish(ControlRunStarted(goal: "Open Calculator"))
    bus.publish(ControlConfirmationRequired(reason: "x", stepID: UUID()))

    bus.publish(ControlRunFinished(outcome: .completed, message: "Verified 36"))
    #expect(host.engine.stack.map(\.title) == ["Verified 36"])
    #expect(host.engine.stack.first?.kind == .completion)
    #expect(host.engine.stack.first?.expiresAfter != nil)
    #expect(host.engine.stack.contains { $0.stackID == "confirmation" } == false)
    #expect(answers.confirmations.isEmpty)

    bus.publish(ControlRunFinished(outcome: .failed, message: "Jev could not find a safe next action."))
    #expect(host.engine.stack.first?.kind == .failure)

    bus.publish(ControlRunFinished(outcome: .cancelled, message: "Control command cancelled."))
    #expect(host.engine.stack.isEmpty)
}

@Test func disabledControlIgnoresRunEvents() {
    let (host, bus, _) = setup()
    host.disable("control")
    bus.publish(ControlRunStarted(goal: "Open Calculator"))
    #expect(host.engine.stack.isEmpty)
}

@Test func controlModulePassesTheGenericAcceptanceHarness() {
    #expect(SaysoModuleAcceptance.violations(for: ControlModule()) == [])
}
