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
        /// The model was not confident enough to act, and nothing may lift that: no card, no execution.
        case refuse
    }

    /// A low-confidence step never runs. The first time it asks which alternative was meant; once the user has
    /// answered and the plan is still low confidence, asking again would loop, so the run stops instead. Try now keeps
    /// asking: it only ever accepts the expected Calculator action. With no alternatives there is nothing to ask.
    public static func lowConfidenceResolution(
        confidence: Double,
        hasAnsweredClarification: Bool,
        isTryNow: Bool,
        hasAlternatives: Bool
    ) -> LowConfidenceResolution {
        guard confidence < ControlPolicy.minimumConfidence else { return .proceed }
        guard hasAlternatives else { return .refuse }
        return hasAnsweredClarification && !isTryNow ? .refuse : .askClarification
    }

    private static let folderPrefix = "open folder "
    private static let pathEdgeNoise = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\"'\u{201C}\u{201D}\u{2018}\u{2019}"))
    private static let pathTrailingNoise = pathEdgeNoise.union(CharacterSet(charactersIn: ".,;!?"))

    /// 'open folder <path>' with an absolute or ~/ path, normalised for `ControlPlanner`: trailing sentence
    /// punctuation and surrounding quotes are not part of a spoken path. Planning it locally keeps the path off the
    /// network. A spoken folder name ('open folder downloads') returns nil and still goes to the model.
    public static func explicitFolderCommand(_ goal: String) -> String? {
        let command = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard command.lowercased().hasPrefix(folderPrefix) else { return nil }
        var path = String(command.dropFirst(folderPrefix.count))
        path = String(path.drop(while: { $0.unicodeScalars.allSatisfy(pathEdgeNoise.contains) }))
        while let last = path.last, last.unicodeScalars.allSatisfy(pathTrailingNoise.contains) {
            path.removeLast()
        }
        guard path.hasPrefix("/") || path.hasPrefix("~") else { return nil }
        return folderPrefix + path
    }

    /// Opening a folder never reports an observed effect, so the explicit folder step ends the run itself. Reaching
    /// this point means `NSWorkspace.open` returned true (a failure throws first), which is the only signal available.
    /// Without it the loop would plan again and send the path to the model.
    public static func completesRun(after action: DesktopAction, effect: ControlEffect, explicitFolderStep: Bool) -> Bool {
        guard explicitFolderStep, case .openFolder = action else { return false }
        return effect == .unknown || effect == .observed
    }
}
