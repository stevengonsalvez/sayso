import Testing
@testable import SaysoCore

@Test func trackingParametersAreRemovedAndOthersKeptInOrder() {
    #expect(ClipboardLinkCleaner.cleaned("https://example.com/p?id=7&utm_source=x&utm_medium=y&fbclid=abc&page=2")
        == "https://example.com/p?id=7&page=2")
    #expect(ClipboardLinkCleaner.cleaned("https://example.com/?gclid=1&igshid=2&mc_eid=3&si=4") == "https://example.com/")
}

@Test func fragmentsAndPathsSurvive() {
    #expect(ClipboardLinkCleaner.cleaned("https://example.com/a/b?utm_campaign=z#section") == "https://example.com/a/b#section")
}

@Test func nothingToCleanOrNotALinkReturnsNil() {
    #expect(ClipboardLinkCleaner.cleaned("https://example.com/p?id=7") == nil)
    #expect(ClipboardLinkCleaner.cleaned("hello world") == nil)
    #expect(ClipboardLinkCleaner.cleaned("see https://example.com/?utm_source=x here") == nil)
    #expect(ClipboardLinkCleaner.cleaned("ftp://example.com/?utm_source=x") == nil)
    #expect(ClipboardLinkCleaner.cleaned("  https://example.com/?utm_source=x  ") == "https://example.com/")
}
