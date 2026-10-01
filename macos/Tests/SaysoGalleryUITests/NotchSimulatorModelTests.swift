import Foundation
import Testing
import SaysoCore
@testable import SaysoGalleryUI

@MainActor
private func make(startsHidden: Bool = false) -> SaysoNotchSimulatorModel {
    SaysoNotchSimulatorModel(startsHidden: startsHidden)
}

// MARK: Surface machine wiring

@MainActor
@Test func simulatorStartsClosedOnTheFirstModuleWithNothingActive() {
    let model = make()
    #expect(model.surface == .closed)
    #expect(model.tabs == ["clip", "timer", "media", "control"])
    #expect(model.selectedTab == "clip")
    #expect(model.primary == nil)
    #expect(model.activityStack.isEmpty)
    #expect(model.pinnedID == nil)
}

@MainActor
@Test func hoverPeeksOnlyAfterSixtyMilliseconds() {
    let model = make()
    model.hover(.entered)
    model.advance(0.059)
    #expect(model.surface == .closed)
    model.advance(0.001)
    #expect(model.surface == .peek)
    model.hover(.exited)
    #expect(model.surface == .closed)
}

@MainActor
@Test func clickExpandsAndAnOutsideClickCollapses() {
    let model = make()
    model.click(.background)
    #expect(model.surface == .expanded)
    model.click(.control)
    #expect(model.surface == .expanded)
    model.click(.outside)
    #expect(model.surface == .closed)
}

@MainActor
@Test func swipeChangesTabOnlyWhenExpandedAndStaysInRange() {
    let model = make()
    model.swipe(.next)
    #expect(model.selectedTab == "clip")
    model.click(.status)
    model.swipe(.next)
    #expect(model.selectedTab == "timer")
    model.swipe(.previous)
    model.swipe(.previous)
    #expect(model.selectedTab == "clip")
}

@MainActor
@Test func jumpSelectsTheNthTabAndExpands() {
    let model = make()
    model.jump(3)
    #expect(model.selectedTab == "media")
    #expect(model.surface == .expanded)
    model.jump(9)
    #expect(model.selectedTab == "media")
}

@MainActor
@Test func topEdgeHoverRevealsAHiddenNotch() {
    let model = make(startsHidden: true)
    #expect(model.surface == .hidden)
    model.topEdgeHover()
    #expect(model.surface == .closed)
}

// MARK: Scenarios and arbitration

@MainActor
@Test func temporaryAlertBecomesPrimaryThenTheShadowedPinnedTaskIsRestored() {
    let model = make()
    model.inject(.persistentTask)
    model.pinPrimary()
    let taskID = model.pinnedID
    #expect(taskID != nil)

    model.inject(.temporaryCompletion)
    #expect(model.primary?.kind == .completion)

    model.advance(2.9)
    #expect(model.primary?.kind == .completion)
    model.advance(0.1)
    #expect(model.primary?.kind == .activeTask)
    #expect(model.pinnedID == taskID)
}

@MainActor
@Test func temporaryAlertWithNothingUnderneathJustDisappears() {
    let model = make()
    model.inject(.temporaryCompletion)
    #expect(model.activityStack.count == 1)
    model.advance(3)
    #expect(model.activityStack.isEmpty)
    #expect(model.primary == nil)
}

@MainActor
@Test func criticalConfirmationOverridesAUserPinButANormalFailureDoesNot() {
    let model = make()
    model.inject(.persistentTask)
    model.pinPrimary()

    model.inject(.failure)
    #expect(model.primary?.kind == .activeTask)

    model.inject(.criticalConfirmation)
    #expect(model.primary?.kind == .confirmation)
    #expect(model.primary?.interruption == .critical)
    #expect(model.pinnedID != nil)
}

@MainActor
@Test func arbitrationListsConfirmationThenFailureThenTaskThenAmbient() {
    let model = make()
    model.inject(.ambient)
    model.inject(.persistentTask)
    model.inject(.failure)
    model.inject(.criticalConfirmation)
    #expect(model.arbitration.map(\.kind) == [.confirmation, .failure, .activeTask, .ambient])
    #expect(model.arbitration.map(\.isPrimary) == [true, false, false, false])
}

@MainActor
@Test func pinMarksTheArbitrationRowAndUnpinReleasesIt() {
    let model = make()
    model.inject(.ambient)
    model.inject(.persistentTask)
    model.pin(moduleID: "clip", stackID: "ambient")
    #expect(model.primary?.kind == .ambient)
    #expect(model.arbitration.filter(\.isPinned).map(\.kind) == [.ambient])
    model.unpin()
    #expect(model.pinnedID == nil)
    #expect(model.primary?.kind == .activeTask)
}

@MainActor
@Test func pinningAnActivityThatVanishesClearsThePinnedID() {
    let model = make()
    model.inject(.temporaryCompletion)
    model.pinPrimary()
    #expect(model.pinnedID != nil)
    model.advance(3)
    #expect(model.pinnedID == nil)
}

@MainActor
@Test func performingAnActionOnTheConfirmationResolvesIt() {
    let model = make()
    model.inject(.criticalConfirmation)
    #expect(model.primary?.actions.map(\.id) == ["approve", "deny"])
    #expect(model.performPrimaryAction("approve"))
    #expect(model.primary == nil)
    #expect(!model.performPrimaryAction("approve"))
}

@MainActor
@Test func ambientDoesNotMoveTheSurface() {
    let model = make()
    model.inject(.ambient)
    #expect(model.surface == .closed)
    #expect(model.primary?.kind == .ambient)
}

@MainActor
@Test func advanceMovesTheInjectedClockAndNothingElse() {
    let model = make()
    let start = model.now
    model.advance(1.5)
    #expect(model.now == start.addingTimeInterval(1.5))
}
