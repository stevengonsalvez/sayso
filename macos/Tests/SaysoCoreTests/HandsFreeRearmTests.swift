import Foundation
import Testing
@testable import SaysoCore

@Test func handsFreeCycleRearmsAcrossDeliveredDictation() {
    var cycle = HandsFreeCycle()
    let startedAt = Date(timeIntervalSinceReferenceDate: 100)
    cycle.start(
        rearmRequested: true,
        handsFreeEnabled: true,
        isDictationMode: true,
        now: startedAt
    )

    let rearmed = cycle.consumeDelivery(
        wasDelivered: true,
        handsFreeEnabled: true,
        isDictationMode: true,
        now: startedAt.addingTimeInterval(1)
    )
    #expect(rearmed)
    #expect(cycle.isArmed)

    cycle.start(
        rearmRequested: true,
        handsFreeEnabled: true,
        isDictationMode: true,
        now: startedAt.addingTimeInterval(1)
    )
    let rearmedAgain = cycle.consumeDelivery(
        wasDelivered: true,
        handsFreeEnabled: true,
        isDictationMode: true,
        now: startedAt.addingTimeInterval(2)
    )
    #expect(rearmedAgain)
    #expect(cycle.isArmed)

    cycle.disarm()
    #expect(!cycle.shouldRearm(handsFreeEnabled: true, isDictationMode: true))
}

@Test func handsFreeCycleStopsAtSessionLimits() {
    let startedAt = Date(timeIntervalSinceReferenceDate: 100)
    var durationCycle = HandsFreeCycle()
    durationCycle.start(
        rearmRequested: true,
        handsFreeEnabled: true,
        isDictationMode: true,
        now: startedAt
    )
    let durationRearm = durationCycle.consumeDelivery(
        wasDelivered: true,
        handsFreeEnabled: true,
        isDictationMode: true,
        maximumSessionDuration: 30,
        now: startedAt.addingTimeInterval(30)
    )
    #expect(!durationRearm)
    #expect(!durationCycle.isArmed)

    var deliveryCycle = HandsFreeCycle()
    deliveryCycle.start(
        rearmRequested: true,
        handsFreeEnabled: true,
        isDictationMode: true,
        now: startedAt
    )
    for count in 1 ..< HandsFreeCycle.deliveryLimit {
        let rearmed = deliveryCycle.consumeDelivery(
            wasDelivered: true,
            handsFreeEnabled: true,
            isDictationMode: true,
            now: startedAt.addingTimeInterval(TimeInterval(count))
        )
        #expect(rearmed)
    }
    let finalDeliveryRearm = deliveryCycle.consumeDelivery(
        wasDelivered: true,
        handsFreeEnabled: true,
        isDictationMode: true,
        now: startedAt.addingTimeInterval(TimeInterval(HandsFreeCycle.deliveryLimit))
    )
    #expect(!finalDeliveryRearm)
    #expect(!deliveryCycle.isArmed)
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
