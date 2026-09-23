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
    let failed = await session.record(.actionFailed)
    #expect(failed.actionCount == 1)
    #expect(failed.canRunAction)

    let exhausted = await session.record(.effectObserved)
    #expect(exhausted.phase == .finished)
    #expect(exhausted.result == .actionBudgetExhausted)
    #expect(exhausted.actionCount == 2)
}

@Test func terminalControlSessionNeverRestartsImplicitly() async {
    let session = ControlSession(limits: .init(maxActions: 1, maxConsecutiveNoEffect: 2))
    _ = await session.start()
    let exhausted = await session.record(.actionFailed)
    let restarted = await session.start()

    #expect(exhausted.phase == .finished)
    #expect(exhausted.result == .actionBudgetExhausted)
    #expect(restarted == exhausted)
}

@Test func explicitNewControlCommandGetsFreshBoundedSession() async {
    let session = ControlSession(limits: .init(maxActions: 1, maxConsecutiveNoEffect: 2))
    _ = await session.start()
    let exhausted = await session.record(.effectObserved)
    let fresh = await session.beginCommand()

    #expect(exhausted.result == .actionBudgetExhausted)
    #expect(fresh.phase == .running)
    #expect(fresh.result == nil)
    #expect(fresh.actionCount == 0)
    #expect((await session.record(.effectObserved)).result == .actionBudgetExhausted)
}

@Test func cancelledControlSessionNeverRestartsImplicitly() async {
    let session = ControlSession()
    _ = await session.start()
    let cancelled = await session.cancel()
    let restarted = await session.start()

    #expect(cancelled.result == .cancelled)
    #expect(restarted == cancelled)
}

@Test func controlSessionCancellationPreventsFurtherSteps() async {
    let session = ControlSession()
    _ = await session.start()
    let cancelled = await session.cancel()
    let afterCancelledRecord = await session.record(.effectObserved)

    #expect(cancelled.result == .cancelled)
    #expect(afterCancelledRecord == cancelled)
}

@Test func controlSessionFailureIsTerminalUntilNewCommand() async {
    let session = ControlSession()
    _ = await session.start()
    _ = await session.record(.actionFailed)
    let failed = await session.fail()
    let afterFailure = await session.record(.effectObserved)
    let restarted = await session.beginCommand()

    #expect(failed.result == .failed)
    #expect(!failed.canRunAction)
    #expect(afterFailure == failed)
    #expect(restarted.phase == .running)
    #expect(restarted.result == nil)
    #expect(restarted.actionCount == 0)
}
