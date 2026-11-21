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

@Test func aFailingPrimaryFallsBackInsteadOfLosingTheRecording() async throws {
    let text = try await LocalBatchEngine.run(primary: { throw Boom() }, fallback: { "fallback text" })
    #expect(text == "fallback text")
    let ok = try await LocalBatchEngine.run(primary: { "primary text" }, fallback: { "fallback text" })
    #expect(ok == "primary text")
}

@Test func cancellationIsNotSwallowedByTheFallback() async {
    await #expect(throws: CancellationError.self) {
        try await LocalBatchEngine.run(primary: { throw CancellationError() }, fallback: { "fallback text" })
    }
}
