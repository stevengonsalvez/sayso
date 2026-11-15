import Foundation
import Testing
@testable import SaysoCore

// Calculator cold launch: a freshly launched app can expose no controls to the first capture.

@Test func calculatorWaitsForControlsAfterAColdLaunch() {
    #expect(ControlLoopPolicy.shouldWaitForCalculatorControls(clearAvailable: false, attemptsMade: 0))
    #expect(ControlLoopPolicy.shouldWaitForCalculatorControls(clearAvailable: false, attemptsMade: 4))
}

@Test func calculatorStopsWaitingOnceControlsAppearOrAttemptsRunOut() {
    #expect(!ControlLoopPolicy.shouldWaitForCalculatorControls(clearAvailable: true, attemptsMade: 0))
    #expect(!ControlLoopPolicy.shouldWaitForCalculatorControls(clearAvailable: false, attemptsMade: ControlLoopPolicy.calculatorSettleAttempts))
    #expect(ControlLoopPolicy.calculatorSettleAttempts == 5)
    #expect(ControlLoopPolicy.calculatorSettleDelayMilliseconds == 400)
}
