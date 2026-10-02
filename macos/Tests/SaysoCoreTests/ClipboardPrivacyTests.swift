import Testing
@testable import SaysoCore

private func snapshot(_ types: Set<String>, text: String? = "hello") -> ClipboardSnapshot {
    ClipboardSnapshot(changeCount: 1, types: types, text: text, sourceApp: nil)
}

@Test func plainTextCopiesAreRecorded() {
    #expect(ClipboardPrivacy.shouldRecord(snapshot(["public.utf8-plain-text"])))
}

@Test func concealedAndTransientPasteboardItemsAreNeverRecorded() {
    #expect(!ClipboardPrivacy.shouldRecord(snapshot(["public.utf8-plain-text", "org.nspasteboard.ConcealedType"])))
    #expect(!ClipboardPrivacy.shouldRecord(snapshot(["public.utf8-plain-text", "org.nspasteboard.TransientType"])))
    #expect(!ClipboardPrivacy.shouldRecord(snapshot(["public.utf8-plain-text", "com.agilebits.onepassword"])))
}

@Test func emptyOrWhitespaceOnlyOrNonTextItemsAreSkipped() {
    #expect(!ClipboardPrivacy.shouldRecord(snapshot(["public.utf8-plain-text"], text: nil)))
    #expect(!ClipboardPrivacy.shouldRecord(snapshot(["public.utf8-plain-text"], text: "  \n\t ")))
    #expect(!ClipboardPrivacy.shouldRecord(snapshot(["public.png"], text: nil)))
}
