import Foundation

/// Pure decisions made by the Control run loop, kept out of the app target so they can be tested.
public enum ControlLoopPolicy {
    /// A freshly launched Calculator can expose no controls to its first capture.
    public static let calculatorSettleAttempts = 5
    public static let calculatorSettleDelayMilliseconds = 400

    public static func shouldWaitForCalculatorControls(clearAvailable: Bool, attemptsMade: Int) -> Bool {
        !clearAvailable && attemptsMade < calculatorSettleAttempts
    }

    public enum LowConfidenceResolution: Equatable, Sendable {
        case proceed
        case askClarification
        case requestApproval
    }

    /// Once the user has answered a clarification, asking again would loop. Hand them the exact action to approve
    /// instead. Try now keeps asking: it only ever accepts the expected Calculator action.
    public static func lowConfidenceResolution(
        confidence: Double,
        hasAnsweredClarification: Bool,
        isTryNow: Bool
    ) -> LowConfidenceResolution {
        guard confidence < ControlPolicy.minimumConfidence else { return .proceed }
        return hasAnsweredClarification && !isTryNow ? .requestApproval : .askClarification
    }

    /// The same step, lifted to the minimum confidence and marked for confirmation so it never runs unreviewed.
    public static func approvalStep(for step: ControlPlanStep) -> ControlPlanStep {
        ControlPlanStep(
            id: step.id, action: step.action, confidence: ControlPolicy.minimumConfidence,
            reason: step.reason, planningSource: step.planningSource,
            candidateTitle: step.candidateTitle, requiresConfirmation: true
        )
    }

    /// 'open folder <path>' is planned by `ControlPlanner` without a model, which keeps the path off the network.
    public static func isExplicitFolderCommand(_ goal: String) -> Bool {
        let command = goal.lowercased()
        guard command.hasPrefix("open folder ") else { return false }
        return !command.dropFirst("open folder ".count).trimmingCharacters(in: .whitespaces).isEmpty
    }
}
