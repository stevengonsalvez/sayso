import AppKit
import Testing
@testable import SaysoCore

private func makePort() -> (PasteboardClipboardPort, NSPasteboard) {
    let board = NSPasteboard.withUniqueName()
    return (PasteboardClipboardPort(pasteboard: board), board)
}

@Test func writtenTextIsReadBackAsPlainTextAndBumpsTheChangeCount() {
    let (port, board) = makePort()
    defer { board.releaseGlobally() }
    let before = port.changeCount

    #expect(port.write(text: "héllo", concealed: false))

    #expect(port.changeCount > before)
    let snapshot = port.snapshot()
    #expect(snapshot.text == "héllo")
    #expect(snapshot.types.contains("public.utf8-plain-text"))
    #expect(!snapshot.types.contains("org.nspasteboard.ConcealedType"))
    #expect(snapshot.changeCount == port.changeCount)
}

@Test func concealedWritesCarryTheConcealedMarkerSoPrivacyRejectsThem() {
    let (port, board) = makePort()
    defer { board.releaseGlobally() }

    #expect(port.write(text: "p4ss", concealed: true))

    let snapshot = port.snapshot()
    #expect(snapshot.types.contains("org.nspasteboard.ConcealedType"))
    #expect(!ClipboardPrivacy.shouldRecord(snapshot))
}

@Test func anEmptyPasteboardHasNoText() {
    let (port, board) = makePort()
    defer { board.releaseGlobally() }
    #expect(port.snapshot().text == nil)
}

@Test func captureAndRestoreRoundTripEveryItemAndFlavour() {
    let (port, board) = makePort()
    defer { board.releaseGlobally() }
    let original = ClipboardContents(changeCount: 0, items: [
        [ClipboardRepresentation(type: "public.png", data: Data([0x89, 0x50, 0x4E, 0x47, 7])),
         ClipboardRepresentation(type: "public.tiff", data: Data([1, 2, 3]))],
        [ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("hello".utf8)),
         ClipboardRepresentation(type: "org.nspasteboard.ConcealedType", data: Data())],
    ])

    #expect(port.restore(original))
    let captured = port.captureContents()

    #expect(captured.items.count == 2)
    for (index, item) in original.items.enumerated() {
        for representation in item {
            #expect(captured.items[index].contains(representation))
        }
    }
    #expect(captured.types.contains("org.nspasteboard.ConcealedType"))
}

@Test func restoringEmptyContentsAndClearBothEmptyThePasteboard() {
    let (port, board) = makePort()
    defer { board.releaseGlobally() }
    _ = port.write(text: "x", concealed: false)

    #expect(port.restore(ClipboardContents(changeCount: 0, items: [])))
    #expect(port.captureContents().items.isEmpty)

    _ = port.write(text: "y", concealed: false)
    port.clear()
    #expect(port.captureContents().items.isEmpty)
    #expect(port.snapshot().text == nil)
}
