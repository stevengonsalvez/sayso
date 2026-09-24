import Testing
@testable import SaysoCore

@Test func handsFreeCycleRearmsAcrossDeliveredDictation() {
    var cycle = HandsFreeCycle()
    cycle.start(
        rearmRequested: true,
        handsFreeEnabled: true,
        isDictationMode: true
    )

    let rearmed = cycle.consumeDelivery(
        wasDelivered: true,
        handsFreeEnabled: true,
        isDictationMode: true
    )
    #expect(rearmed)
    #expect(cycle.isArmed)

    cycle.disarm()
    #expect(!cycle.shouldRearm(handsFreeEnabled: true, isDictationMode: true))
}

@Test func handsFreeCycleDisarmsWhenDeliveryCannotContinue() {
    var cycle = HandsFreeCycle()
    cycle.start(
        rearmRequested: true,
        handsFreeEnabled: true,
        isDictationMode: true
    )

    let failedDeliveryRearm = cycle.consumeDelivery(
        wasDelivered: false,
        handsFreeEnabled: true,
        isDictationMode: true
    )
    #expect(!failedDeliveryRearm)
    #expect(!cycle.isArmed)

    cycle.start(
        rearmRequested: true,
        handsFreeEnabled: true,
        isDictationMode: true
    )
    let disabledHandsFreeRearm = cycle.consumeDelivery(
        wasDelivered: true,
        handsFreeEnabled: false,
        isDictationMode: true
    )
    #expect(!disabledHandsFreeRearm)
    #expect(!cycle.isArmed)
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
