import Testing
@testable import SaysoCore

@Test func localCleanupMatchesSafeFormatterRules() {
    #expect(TranscriptCleanup.processLocally("  [blank_audio] hello   ,world!next  ") == "Hello, world! next")
    #expect(TranscriptCleanup.processLocally("[BLANK_AUDIO]") == "")
}

@Test func localCleanupIsIdempotentAndKeepsIndianScripts() {
    let cleaned = TranscriptCleanup.processLocally("  नमस्ते , दुनिया!कैसे  ")
    #expect(cleaned == "नमस्ते, दुनिया! कैसे")
    #expect(TranscriptCleanup.processLocally(cleaned) == cleaned)
}

@Test func localCleanupPreservesStructuredPunctuation() {
    let text = "3.14 at 10:30, example.com costs 1,000!"
    #expect(TranscriptCleanup.processLocally(text) == text)
    #expect(TranscriptCleanup.processLocally("lowercase", capitalizesFirstLetter: false) == "lowercase")
}
