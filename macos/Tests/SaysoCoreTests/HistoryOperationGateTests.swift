import Foundation
import Testing
@testable import SaysoCore

@Test func onlyOneHistoryOperationRunsAtATime() {
    var gate = HistoryOperationGate()
    let id = UUID()

    #expect(gate.begin(.reprocess(id)))
    #expect(gate.reprocessingID == id)
    #expect(!gate.begin(.reprocess(UUID())))
    #expect(!gate.begin(.importAudio))
    #expect(!gate.begin(.clear))

    gate.end(.reprocess(id))
    #expect(gate.reprocessingID == nil)
    #expect(gate.begin(.importAudio))
    #expect(gate.isImporting)
    #expect(!gate.begin(.clear))
    gate.end(.importAudio)

    #expect(gate.begin(.clear))
    #expect(gate.isClearing)
    #expect(!gate.begin(.reprocess(id)))
    gate.end(.clear)
    #expect(!gate.isClearing)
}

@Test func backgroundAudioTaskBlocksClearAndDictationButNotItsOwnOperations() {
    var gate = HistoryOperationGate()

    #expect(gate.beginAudioTask())
    #expect(!gate.beginAudioTask())
    #expect(gate.isAudioTaskRunning)
    #expect(gate.blocksDictation)
    #expect(gate.begin(.importAudio))
    gate.end(.importAudio)
    #expect(!gate.begin(.clear))

    gate.endAudioTask()
    #expect(!gate.blocksDictation)
    #expect(gate.begin(.clear))
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
