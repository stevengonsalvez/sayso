import Testing
@testable import SaysoCore

@Test func handsFreeRearmsOnlyForAnArmedDictationSession() {
    #expect(HandsFreeRearmPolicy.shouldRearm(
        isArmed: true,
        handsFreeEnabled: true,
        isDictationMode: true
    ))
    #expect(!HandsFreeRearmPolicy.shouldRearm(
        isArmed: false,
        handsFreeEnabled: true,
        isDictationMode: true
    ))
    #expect(!HandsFreeRearmPolicy.shouldRearm(
        isArmed: true,
        handsFreeEnabled: false,
        isDictationMode: true
    ))
    #expect(!HandsFreeRearmPolicy.shouldRearm(
        isArmed: true,
        handsFreeEnabled: true,
        isDictationMode: false
    ))
}
