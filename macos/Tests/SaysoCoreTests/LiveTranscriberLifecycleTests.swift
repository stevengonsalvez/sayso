import Testing
@testable import SaysoCore

@Test func pendingStartRejectsConcurrentStart() {
    var gate = TranscriptionRunGate()

    #expect(!gate.isPending)
    #expect(gate.begin() != nil)
    #expect(gate.isPending)
    #expect(gate.begin() == nil)
}

@Test func cancelledPendingStartCannotBecomeCurrent() {
    var gate = TranscriptionRunGate()
    let cancelledAttempt = gate.begin()
    gate.cancel()

    #expect(!gate.isPending)
    #expect(cancelledAttempt.map(gate.isCurrent) == false)
    #expect(gate.begin() != nil)
}

@Test func finishingOldStartCannotClearNewStart() {
    var gate = TranscriptionRunGate()
    let first = gate.begin()
    gate.cancel()
    let second = gate.begin()

    if let first { gate.finish(first) }

    #expect(second.map(gate.isCurrent) == true)
}

@Test func staleRecognitionRunCannotFinalizeCurrentSession() {
    var gate = TranscriptionRunGate()
    let previous = gate.begin()
    gate.cancel()
    let current = gate.begin()

    #expect(previous.map(gate.isCurrent) == false)
    #expect(current.map(gate.isCurrent) == true)
}
