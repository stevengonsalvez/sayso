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
