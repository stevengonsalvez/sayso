import Foundation

/// Pure decisions made by the Control run loop, kept out of the app target so they can be tested.
public enum ControlLoopPolicy {
    /// A freshly launched Calculator can expose no controls to its first capture.
    public static let calculatorSettleAttempts = 5
    public static let calculatorSettleDelayMilliseconds = 400

    public static func shouldWaitForCalculatorControls(clearAvailable: Bool, attemptsMade: Int) -> Bool {
        !clearAvailable && attemptsMade < calculatorSettleAttempts
    }
}
