import Foundation

/// A Control run began for a spoken or typed goal.
public struct ControlRunStarted: SaysoEvent, Equatable {
    public let goal: String
    public init(goal: String) { self.goal = goal }
}

/// The planner picked the next guarded step.
public struct ControlStepPlanned: SaysoEvent, Equatable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

/// Planning was not confident; the user must pick one of the choices.
public struct ControlClarificationAsked: SaysoEvent, Equatable {
    public let question: String
    public let choices: [String]
    public let askedAt: Date
    public init(question: String, choices: [String], askedAt: Date) {
        self.question = question
        self.choices = choices
        self.askedAt = askedAt
    }
}

/// A destructive or opaque step is waiting for explicit approval.
public struct ControlConfirmationRequired: SaysoEvent, Equatable {
    public let reason: String
    /// Identifies this exact step; an answer for any other step is ignored.
    public let stepID: UUID
    public init(reason: String, stepID: UUID) {
        self.reason = reason
        self.stepID = stepID
    }
}

/// The step was approved or discarded through another path (for example the Studio window).
public struct ControlConfirmationResolved: SaysoEvent, Equatable {
    public let stepID: UUID
    public init(stepID: UUID) { self.stepID = stepID }
}

public struct ControlRunFinished: SaysoEvent, Equatable {
    public enum Outcome: Equatable, Sendable { case completed, failed, cancelled }
    public let outcome: Outcome
    public let message: String
    public init(outcome: Outcome, message: String) {
        self.outcome = outcome
        self.message = message
    }
}

/// Answers emitted by the control module for the run owner to act on.
public struct ControlCancelRequested: SaysoEvent, Equatable {
    public init() {}
}

public struct ControlConfirmationAnswered: SaysoEvent, Equatable {
    public let approved: Bool
    public let stepID: UUID
    public init(approved: Bool, stepID: UUID) {
        self.approved = approved
        self.stepID = stepID
    }
}

public struct ControlClarificationChosen: SaysoEvent, Equatable {
    public let choice: String
    public init(choice: String) { self.choice = choice }
}
