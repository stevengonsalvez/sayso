import Testing
@testable import SaysoCore

@Test func controlSessionCompletesAfterObservedWork() async {
    let session = ControlSession(limits: .init(maxActions: 3, maxConsecutiveNoEffect: 2))

    #expect(await session.start().canRunAction)
    let afterEffect = await session.record(.effectObserved)
    #expect(afterEffect.actionCount == 1)
    #expect(afterEffect.consecutiveNoEffectCount == 0)

    let completed = await session.complete()
    #expect(completed.phase == .finished)
    #expect(completed.result == .completed)
    #expect(!completed.canRunAction)
}

@Test func controlSessionStopsAfterNoEffectBudget() async {
    let session = ControlSession(limits: .init(maxActions: 5, maxConsecutiveNoEffect: 2))
    _ = await session.start()

    let firstNoEffect = await session.record(.noEffectObserved)
    #expect(firstNoEffect.canRunAction)
    #expect(firstNoEffect.consecutiveNoEffectCount == 1)

    let exhausted = await session.record(.noEffectObserved)
    #expect(exhausted.phase == .finished)
    #expect(exhausted.result == .noEffectBudgetExhausted)
    #expect(exhausted.actionCount == 2)
}

@Test func controlSessionStopsAfterActionBudget() async {
    let session = ControlSession(limits: .init(maxActions: 2, maxConsecutiveNoEffect: 3))
    _ = await session.start()
    _ = await session.record(.actionFailed)

    let exhausted = await session.record(.effectObserved)
    #expect(exhausted.phase == .finished)
    #expect(exhausted.result == .actionBudgetExhausted)
    #expect(exhausted.actionCount == 2)
}

@Test func controlSessionCancellationPreventsFurtherSteps() async {
    let session = ControlSession()
    _ = await session.start()
    let cancelled = await session.cancel()
    let afterCancelledRecord = await session.record(.effectObserved)

    #expect(cancelled.result == .cancelled)
    #expect(afterCancelledRecord == cancelled)
}
