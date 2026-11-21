import Testing
@testable import SaysoCore

@Test func englishUsesParakeetV3OnlyWhenItsFilesAreInstalled() {
    #expect(LocalBatchEngine.choose(language: .english, parakeetV3Installed: true) == .parakeetV3)
    #expect(LocalBatchEngine.choose(language: .english, parakeetV3Installed: false) == .realtimeEOU)
}

@Test func otherLanguagesKeepTheExistingLocalEngine() {
    #expect(LocalBatchEngine.choose(language: .hindi, parakeetV3Installed: true) == .realtimeEOU)
    #expect(LocalBatchEngine.choose(language: .automatic, parakeetV3Installed: true) == .realtimeEOU)
}
