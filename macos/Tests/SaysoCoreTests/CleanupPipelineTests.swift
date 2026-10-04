import Foundation
import Testing
@testable import SaysoCore

private struct Boom: Error {}
private final class Calls: @unchecked Sendable { var texts: [String] = [] }

private func run(
    route: CleanupRoute,
    rulesOutput: String = "rules",
    local: (@Sendable (String) async throws -> String)? = nil,
    cloud: (@Sendable (String) async throws -> String)? = nil
) async -> CleanupOutcome {
    await CleanupPipeline.run(
        text: "raw", route: route, rulesOutput: rulesOutput,
        finish: { "finished(\($0))" }, localSLM: local, cloud: cloud
    )
}

@Test func rulesRouteReturnsTheLocalRulesOutputWithoutCallingProviders() async {
    let calls = Calls()
    let outcome = await run(route: .rules, local: { calls.texts.append($0); return "x" }, cloud: { calls.texts.append($0); return "y" })
    #expect(outcome == CleanupOutcome(text: "rules", notice: nil))
    #expect(calls.texts.isEmpty)
}

@Test func providerOutputIsFinishedByTheSameFormattingPipeline() async {
    let local = await run(route: .localSLM, local: { "slm(\($0))" })
    #expect(local == CleanupOutcome(text: "finished(slm(raw))", notice: nil))
    let cloud = await run(route: .cloud, cloud: { "cloud(\($0))" })
    #expect(cloud == CleanupOutcome(text: "finished(cloud(raw))", notice: nil))
}

@Test func localSLMFailureFallsBackSilentlyToRules() async {
    let outcome = await run(route: .localSLM, local: { _ in throw Boom() })
    #expect(outcome == CleanupOutcome(text: "rules", notice: nil))
}

@Test func cloudFailureFallsBackToRulesAndSaysSo() async {
    let outcome = await run(route: .cloud, cloud: { _ in throw Boom() })
    #expect(outcome == CleanupOutcome(text: "rules", notice: "Cloud cleanup unavailable. Applied smart rules."))
}

@Test func aRouteWithoutItsProviderFallsBackToRules() async {
    #expect(await run(route: .localSLM) == CleanupOutcome(text: "rules", notice: nil))
    #expect(await run(route: .cloud) == CleanupOutcome(text: "rules", notice: nil))
}
