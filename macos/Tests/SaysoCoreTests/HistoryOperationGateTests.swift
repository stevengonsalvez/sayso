import Foundation
import Testing
@testable import SaysoCore

private func take(_ gate: inout HistoryOperationGate, _ op: HistoryOperationGate.Operation) -> Bool { gate.begin(op) }
private func takeTask(_ gate: inout HistoryOperationGate) -> Bool { gate.beginAudioTask() }

@Test func onlyOneHistoryOperationRunsAtATime() {
    var gate = HistoryOperationGate()
    let id = UUID()

    #expect(take(&gate, .reprocess(id)))
    #expect(gate.reprocessingID == id)
    #expect(!take(&gate, .reprocess(UUID())))
    #expect(!take(&gate, .importAudio))
    #expect(!take(&gate, .clear))

    gate.end(.reprocess(id))
    #expect(gate.reprocessingID == nil)
    #expect(take(&gate, .importAudio))
    #expect(gate.isImporting)
    #expect(!take(&gate, .clear))
    gate.end(.importAudio)

    #expect(take(&gate, .clear))
    #expect(gate.isClearing)
    #expect(!take(&gate, .reprocess(id)))
    gate.end(.clear)
    #expect(!gate.isClearing)
}

@Test func backgroundAudioTaskBlocksClearAndDictationButNotItsOwnOperations() {
    var gate = HistoryOperationGate()

    #expect(takeTask(&gate))
    #expect(!takeTask(&gate))
    #expect(gate.isAudioTaskRunning)
    #expect(gate.blocksDictation)
    #expect(take(&gate, .importAudio))
    gate.end(.importAudio)
    #expect(!take(&gate, .clear))

    gate.endAudioTask()
    #expect(!gate.blocksDictation)
    #expect(take(&gate, .clear))
}

@Test func dictationIsBlockedWhileReprocessingOrImportingButNotWhileClearing() {
    var gate = HistoryOperationGate()
    _ = gate.begin(.reprocess(UUID()))
    #expect(gate.blocksDictation)
    gate = HistoryOperationGate()
    _ = gate.begin(.importAudio)
    #expect(gate.blocksDictation)
    gate = HistoryOperationGate()
    _ = gate.begin(.clear)
    #expect(!gate.blocksDictation)
}
