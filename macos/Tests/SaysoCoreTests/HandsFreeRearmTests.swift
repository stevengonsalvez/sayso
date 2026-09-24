import Testing
@testable import SaysoCore

@Test func handsFreeCycleRearmsAcrossDeliveredDictation() {
    var cycle = HandsFreeCycle()
    cycle.start(
        rearmRequested: true,
        handsFreeEnabled: true,
        isDictationMode: true
    )

    #expect(cycle.shouldRearm(handsFreeEnabled: true, isDictationMode: true))
    #expect(cycle.shouldRearm(handsFreeEnabled: true, isDictationMode: true))

    cycle.disarm()
    #expect(!cycle.shouldRearm(handsFreeEnabled: true, isDictationMode: true))
}

@Test func handsFreeCycleArmsOnlyForContinuousDictation() {
    var cycle = HandsFreeCycle()
    cycle.start(
        rearmRequested: false,
        handsFreeEnabled: true,
        isDictationMode: true
    )
    #expect(!cycle.isArmed)

    cycle.start(
        rearmRequested: true,
        handsFreeEnabled: false,
        isDictationMode: true
    )
    #expect(!cycle.isArmed)

    cycle.start(
        rearmRequested: true,
        handsFreeEnabled: true,
        isDictationMode: false
    )
    #expect(!cycle.isArmed)
}
