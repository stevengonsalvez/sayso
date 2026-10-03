import Testing
@testable import SaysoCore

private func verdict(
    text: String = "one two three four",
    partialsApplied: [Bool] = [true, true],
    delivery: AcceptanceVerdict.Delivery = .inserted,
    observed: String? = "one two three four",
    before: String? = nil
) -> AcceptanceVerdict {
    AcceptanceVerdict.evaluate(
        expectedText: text, partialsApplied: partialsApplied, delivery: delivery, observedTargetValue: observed, targetValueBefore: before
    )
}

@Test func acceptancePassesOnlyWithPartialsInsertionAndVerifiedTargetValue() {
    #expect(verdict().ok)
    #expect(verdict(observed: "prefix one  two three\nfour suffix").ok)
}

@Test func acceptanceFailsWhenNoPartialInsertionWasApplied() {
    let result = verdict(partialsApplied: [false, false])
    #expect(!result.ok)
    #expect(result.error == "No partial insertion was applied.")
    #expect(!verdict(partialsApplied: []).ok)
}

@Test func shortTextWithoutCheckpointsDoesNotRequirePartials() {
    #expect(verdict(text: "hi there", partialsApplied: [], observed: "hi there").ok)
}

@Test func acceptanceFailsWhenTheTargetValueCannotBeReadOrDoesNotMatch() {
    #expect(verdict(observed: nil).error == "Target value could not be read to verify the insertion.")
    #expect(verdict(observed: "one two").error == "Target value does not contain the dictated text.")
}

@Test func clipboardOrFailedDeliveryNeverPasses() {
    #expect(verdict(delivery: .clipboard).error == "Final text was copied, not inserted.")
    #expect(verdict(delivery: .failed("No paste target")).error == "No paste target")
}

@Test func targetThatAlreadyHeldTheTextBeforeTheRunDoesNotProveInsertion() {
    let result = verdict(observed: "one two three four", before: "one two three four")
    #expect(result.error == "Target value did not change, so insertion is unproven.")
    #expect(verdict(observed: "one two three four one two three four", before: "one two three four").ok)
}
