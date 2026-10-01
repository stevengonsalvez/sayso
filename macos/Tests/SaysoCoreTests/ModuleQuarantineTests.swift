import Foundation
import Testing
@testable import SaysoCore

private final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 10_000) }

private final class FlakyRuntime: SaysoModuleRuntime, @unchecked Sendable {
    let context: SaysoModuleContext
    var stopped = 0
    init(context: SaysoModuleContext) { self.context = context }
    func start() { context.publish(stackID: "main", kind: .activeTask, title: context.moduleID) }
    func stop() { stopped += 1 }
}

private final class Registry: @unchecked Sendable { var runtimes: [String: FlakyRuntime] = [:] }

private struct FlakyModule: SaysoModule {
    let descriptor: SaysoModuleDescriptor
    let registry: Registry
    func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        let runtime = FlakyRuntime(context: context)
        registry.runtimes[descriptor.id] = runtime
        return runtime
    }
}

@Test func threeFailuresInFiveMinutesQuarantineOnlyThatModule() {
    let clock = Clock()
    let registry = Registry()
    let host = SaysoModuleHost(
        modules: ["bad", "good"].map { FlakyModule(descriptor: .init(id: $0, title: $0), registry: registry) },
        now: { clock.now }
    )
    host.enable("bad")
    host.enable("good")

    registry.runtimes["bad"]?.context.reportFailure()
    clock.now += 200
    registry.runtimes["bad"]?.context.reportFailure()
    #expect(host.health(of: "bad") == .degraded)

    clock.now += 99
    registry.runtimes["bad"]?.context.reportFailure()

    #expect(host.health(of: "bad") == .quarantined)
    #expect(registry.runtimes["bad"]?.stopped == 1)
    #expect(host.engine.stack.map(\.moduleID) == ["good"])
    #expect(host.health(of: "good") == .ready)

    host.enable("bad")
    #expect(host.health(of: "bad") == .quarantined)
}

@Test func failuresOlderThanFiveMinutesDoNotQuarantine() {
    let clock = Clock()
    let registry = Registry()
    let host = SaysoModuleHost(
        modules: [FlakyModule(descriptor: .init(id: "m", title: "m"), registry: registry)],
        now: { clock.now }
    )
    host.enable("m")
    for _ in 0..<4 {
        registry.runtimes["m"]?.context.reportFailure()
        clock.now += 200
    }
    #expect(host.health(of: "m") != .quarantined)
}
