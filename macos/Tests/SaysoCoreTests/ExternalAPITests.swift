import Foundation
import Testing
@testable import SaysoCore

private func makeAPI(enableExternal: Bool = true) -> (SaysoExternalAPI, SaysoModuleHost) {
    let external = ExternalActivitiesModule()
    let host = SaysoModuleHost(modules: [external, TtsModule(synthesizer: NullSynth())])
    if enableExternal { host.enable("external") }
    return (SaysoExternalAPI(host: host, external: external), host)
}

private final class NullSynth: SpeechSynthesizing, @unchecked Sendable {
    var isSpeaking = false
    var onFinish: (@Sendable (Int) -> Void)?
    func speak(_ plan: SpeechPlan) -> Int { 1 }
    func stop() {}
}

private func call(_ api: SaysoExternalAPI, _ json: String) throws -> [String: Any] {
    let out = api.handle(Data(json.utf8))
    return try #require(JSONSerialization.jsonObject(with: out) as? [String: Any])
}

@Test func unsupportedVersionAndGarbageAreRejectedWithoutSideEffects() throws {
    let (api, host) = makeAPI()
    #expect(try call(api, #"{"v":2,"op":"listModules"}"#)["error"] as? String == "unsupported_version")
    #expect(try call(api, "not json")["error"] as? String == "bad_request")
    #expect(try call(api, #"{"v":1,"op":"nope"}"#)["error"] as? String == "unknown_op")
    #expect(host.engine.stack.isEmpty)
}

@Test func listModulesReportsIdTitleAndHealth() throws {
    let (api, _) = makeAPI()
    let reply = try call(api, #"{"v":1,"op":"listModules"}"#)
    let modules = try #require(reply["modules"] as? [[String: Any]])
    let byID = Dictionary(uniqueKeysWithValues: modules.compactMap { m in (m["id"] as? String).map { ($0, m) } })
    #expect(byID["external"]?["health"] as? String == "ready")
    #expect(byID["tts"]?["health"] as? String == "disabled")
    #expect(byID["tts"]?["title"] as? String == "Voice output")
}

@Test func scriptsPublishAndClearActivitiesInTheirOwnStack() throws {
    let (api, host) = makeAPI()
    let ok = try call(api, #"{"v":1,"op":"publish","stackID":"build","kind":"activeTask","title":"Building","expiresAfter":60}"#)
    #expect(ok["ok"] as? Bool == true)
    #expect(host.engine.stack.map(\.title) == ["Building"])
    #expect(host.engine.stack.first?.moduleID == "external")

    _ = try call(api, #"{"v":1,"op":"publish","stackID":"build","kind":"completion","title":"Done"}"#)
    #expect(host.engine.stack.map(\.title) == ["Done"])

    #expect(try call(api, #"{"v":1,"op":"clear","stackID":"build"}"#)["ok"] as? Bool == true)
    #expect(host.engine.stack.isEmpty)
}

@Test func scriptsCannotRaiseConfirmationsOrOversizedOrUnboundedContent() throws {
    let (api, host) = makeAPI()
    #expect(try call(api, #"{"v":1,"op":"publish","stackID":"s","kind":"confirmation","title":"Delete?"}"#)["error"] as? String == "invalid_kind")
    #expect(try call(api, #"{"v":1,"op":"publish","stackID":"s","kind":"bogus","title":"x"}"#)["error"] as? String == "invalid_kind")
    let long = String(repeating: "a", count: 121)
    #expect(try call(api, #"{"v":1,"op":"publish","stackID":"s","kind":"ambient","title":"\#(long)"}"#)["error"] as? String == "invalid_field")
    #expect(try call(api, #"{"v":1,"op":"publish","stackID":"","kind":"ambient","title":"x"}"#)["error"] as? String == "invalid_field")
    #expect(try call(api, #"{"v":1,"op":"publish","stackID":"s","kind":"ambient","title":"x","expiresAfter":99999}"#)["error"] as? String == "invalid_field")
    #expect(host.engine.stack.isEmpty)
}

@Test func publishFailsCleanlyWhileTheExternalModuleIsDisabled() throws {
    let (api, host) = makeAPI(enableExternal: false)
    #expect(try call(api, #"{"v":1,"op":"publish","stackID":"s","kind":"ambient","title":"x"}"#)["error"] as? String == "module_unavailable")
    #expect(host.engine.stack.isEmpty)
}

@Test func externalModulePassesTheGenericAcceptanceHarness() {
    #expect(SaysoModuleAcceptance.violations(for: ExternalActivitiesModule()) == [])
}

@Test func booleanVersionIsNotAVersion() throws {
    let (api, _) = makeAPI()
    #expect(try call(api, #"{"v":true,"op":"listModules"}"#)["error"] as? String == "unsupported_version")
    #expect(try call(api, #"{"v":1.0,"op":"listModules"}"#)["modules"] != nil)
}

@Test func scriptsCannotCreateUnboundedStacksButMayUpdateAndFreeThem() throws {
    let (api, host) = makeAPI()
    for n in 0..<SaysoExternalAPI.maxStacks {
        #expect(try call(api, #"{"v":1,"op":"publish","stackID":"s\#(n)","kind":"ambient","title":"x"}"#)["ok"] as? Bool == true)
    }
    #expect(try call(api, #"{"v":1,"op":"publish","stackID":"overflow","kind":"ambient","title":"x"}"#)["error"] as? String == "limit_reached")
    #expect(try call(api, #"{"v":1,"op":"publish","stackID":"s0","kind":"failure","title":"y"}"#)["ok"] as? Bool == true)
    #expect(host.engine.stack.count == SaysoExternalAPI.maxStacks)

    _ = try call(api, #"{"v":1,"op":"clear","stackID":"s1"}"#)
    #expect(try call(api, #"{"v":1,"op":"publish","stackID":"overflow","kind":"ambient","title":"x"}"#)["ok"] as? Bool == true)
}

@Test func expiredScriptStacksFreeTheirSlotsForNewOnes() throws {
    let external = ExternalActivitiesModule()
    let host = SaysoModuleHost(modules: [external])
    host.enable("external")

    for n in 0..<3 {
        #expect(external.publish(stackID: "s\(n)", kind: .ambient, title: "t", expiresAfter: 0.05, maxStacks: 3) == .published)
    }
    #expect(external.publish(stackID: "extra", kind: .ambient, title: "t", expiresAfter: 0.05, maxStacks: 3) == .limitReached)

    Thread.sleep(forTimeInterval: 0.2)
    #expect(external.publish(stackID: "extra", kind: .ambient, title: "t", expiresAfter: 0.05, maxStacks: 3) == .published)
}
