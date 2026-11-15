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

private func resolution(
    confidence: Double = 0.3,
    answered: Bool = false,
    tryNow: Bool = false,
    alternatives: Bool = true
) -> ControlLoopPolicy.LowConfidenceResolution {
    ControlLoopPolicy.lowConfidenceResolution(
        confidence: confidence, hasAnsweredClarification: answered, isTryNow: tryNow, hasAlternatives: alternatives
    )
}

@Test func firstLowConfidenceStepAsksForClarification() {
    #expect(resolution() == .askClarification)
}

@Test func answeredClarificationThatStaysLowConfidenceFailsClosed() {
    #expect(resolution(answered: true) == .refuse)
}

@Test func tryNowKeepsAskingEvenAfterAnAnswer() {
    #expect(resolution(answered: true, tryNow: true) == .askClarification)
}

@Test func lowConfidenceWithNothingToChooseFromIsRefusedEvenAfterAnAnswer() {
    #expect(resolution(alternatives: false) == .refuse)
    #expect(resolution(answered: true, alternatives: false) == .refuse)
    #expect(resolution(answered: true, tryNow: true, alternatives: false) == .refuse)
}

@Test func confidentStepsNeverEscalate() {
    #expect(resolution(confidence: ControlPolicy.minimumConfidence, answered: true) == .proceed)
    #expect(resolution(confidence: 0.9, alternatives: false) == .proceed)
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

// An open-folder effect is always unknown, so the explicit folder step must end the run itself or the loop
// would plan again and send the path to the model.

@Test func explicitFolderStepAlwaysCompletesTheRun() {
    let open = DesktopAction.openFolder(url: URL(fileURLWithPath: "/Applications"))

    #expect(ControlLoopPolicy.completesRun(after: open, explicitFolderStep: true))
}

@Test func onlyTheExplicitFolderShortcutCompletesTheRunThisWay() {
    let open = DesktopAction.openFolder(url: URL(fileURLWithPath: "/Applications"))

    #expect(!ControlLoopPolicy.completesRun(after: open, explicitFolderStep: false))
    #expect(!ControlLoopPolicy.completesRun(after: .activate(bundleIdentifier: "com.apple.finder"), explicitFolderStep: true))
}
