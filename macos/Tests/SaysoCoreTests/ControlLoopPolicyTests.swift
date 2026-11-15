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

// An answered clarification that stays low confidence must not ask the same question again.

@Test func firstLowConfidenceStepAsksForClarification() {
    #expect(ControlLoopPolicy.lowConfidenceResolution(confidence: 0.3, hasAnsweredClarification: false, isTryNow: false) == .askClarification)
}

@Test func answeredClarificationThatStaysLowConfidenceRequestsApproval() {
    #expect(ControlLoopPolicy.lowConfidenceResolution(confidence: 0.3, hasAnsweredClarification: true, isTryNow: false) == .requestApproval)
}

@Test func tryNowKeepsAskingEvenAfterAnAnswer() {
    #expect(ControlLoopPolicy.lowConfidenceResolution(confidence: 0.3, hasAnsweredClarification: true, isTryNow: true) == .askClarification)
}

@Test func confidentStepsNeverEscalate() {
    #expect(ControlLoopPolicy.lowConfidenceResolution(confidence: ControlPolicy.minimumConfidence, hasAnsweredClarification: true, isTryNow: false) == .proceed)
    #expect(ControlLoopPolicy.lowConfidenceResolution(confidence: 0.9, hasAnsweredClarification: false, isTryNow: false) == .proceed)
}

@Test func approvalStepKeepsTheActionButAlwaysRequiresConfirmation() {
    let low = ControlPlanStep(
        action: .activate(bundleIdentifier: "com.apple.calculator"), confidence: 0.3, reason: "Open Calculator",
        planningSource: .jev, candidateTitle: "Calculator"
    )

    let approval = ControlLoopPolicy.approvalStep(for: low)

    #expect(approval.id == low.id)
    #expect(approval.action == low.action)
    #expect(approval.reason == low.reason)
    #expect(approval.planningSource == .jev)
    #expect(approval.candidateTitle == "Calculator")
    #expect(approval.requiresConfirmation)
    #expect(approval.confidence >= ControlPolicy.minimumConfidence)
    #expect(!ControlPolicy.canAutoRun(approval))
}

// An explicit folder path is planned locally so the path never reaches the network.

@Test func openFolderWithAnAbsoluteOrHomePathIsAnExplicitFolderCommand() {
    #expect(ControlLoopPolicy.explicitFolderCommand("open folder /Applications") == "open folder /Applications")
    #expect(ControlLoopPolicy.explicitFolderCommand("Open Folder ~/Documents") == "open folder ~/Documents")
}

@Test func trailingSentencePunctuationAndQuotesAreNotPartOfThePath() {
    #expect(ControlLoopPolicy.explicitFolderCommand("Open folder ~/Documents.") == "open folder ~/Documents")
    #expect(ControlLoopPolicy.explicitFolderCommand("open folder /tmp/notes!") == "open folder /tmp/notes")
    #expect(ControlLoopPolicy.explicitFolderCommand("open folder \"/Applications\"") == "open folder /Applications")
    #expect(ControlLoopPolicy.explicitFolderCommand("open folder \u{201C}~/My Files\u{201D}.") == "open folder ~/My Files")
    #expect(ControlLoopPolicy.explicitFolderCommand("  open folder /Applications  ") == "open folder /Applications")
}

@Test func spokenFolderNamesAndOtherCommandsAreNotExplicitFolderCommands() {
    #expect(ControlLoopPolicy.explicitFolderCommand("open folder downloads") == nil)
    #expect(ControlLoopPolicy.explicitFolderCommand("open folder") == nil)
    #expect(ControlLoopPolicy.explicitFolderCommand("open folder \"\"") == nil)
    #expect(ControlLoopPolicy.explicitFolderCommand("open the folder with my notes") == nil)
    #expect(ControlLoopPolicy.explicitFolderCommand("open calculator") == nil)
    #expect(ControlLoopPolicy.explicitFolderCommand("please open folder /tmp") == nil)
}
