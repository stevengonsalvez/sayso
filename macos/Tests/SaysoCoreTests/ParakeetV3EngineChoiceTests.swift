import Testing
@testable import SaysoCore

@Test func englishOnTheLocalRouteUsesParakeetV3OnlyWhenInstalled() {
    #expect(LocalBatchEngine.choose(route: .local, language: .english, parakeetV3Installed: true) == .parakeetV3)
    #expect(LocalBatchEngine.choose(route: .local, language: .english, parakeetV3Installed: false) == .realtimeEOU)
}

@Test func otherRoutesAndLanguagesKeepTheExistingEngine() {
    #expect(LocalBatchEngine.choose(route: .byok, language: .english, parakeetV3Installed: true) == .realtimeEOU)
    #expect(LocalBatchEngine.choose(route: .appleSpeech, language: .english, parakeetV3Installed: true) == .realtimeEOU)
    #expect(LocalBatchEngine.choose(route: .local, language: .hindi, parakeetV3Installed: true) == .realtimeEOU)
    #expect(LocalBatchEngine.choose(route: .local, language: .automatic, parakeetV3Installed: true) == .realtimeEOU)
}

private struct Boom: Error {}

@Test func aFailingAttemptReturnsNilSoTheNextEngineRuns() async throws {
    let failed: String? = try await LocalBatchEngine.attempt { throw Boom() }
    #expect(failed == nil)
    let ok = try await LocalBatchEngine.attempt { "primary text" }
    #expect(ok == "primary text")
}

@Test func cancellationIsNotSwallowedByTheAttempt() async {
    await #expect(throws: CancellationError.self) {
        let _: String? = try await LocalBatchEngine.attempt { throw CancellationError() }
    }
}
