import Foundation
import Testing
@testable import SaysoCore

private final class SpyRuntime: SaysoModuleRuntime, @unchecked Sendable {
    var started = 0
    var stopped = 0
    let context: SaysoModuleContext
    init(context: SaysoModuleContext) { self.context = context }
    func start() {
        started += 1
        context.publish(stackID: "main", kind: .activeTask, title: "Running")
    }
    func stop() { stopped += 1 }
}

private struct SpyModule: SaysoModule {
    let descriptor = SaysoModuleDescriptor(id: "spy", title: "Spy")
    let onMake: @Sendable (SpyRuntime) -> Void
    func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        let runtime = SpyRuntime(context: context)
        onMake(runtime)
        return runtime
    }
}

@Test func enablingStartsRuntimeAndDisablingStopsItAndClearsItsActivities() {
    let box = RuntimeBox()
    let host = SaysoModuleHost(modules: [SpyModule(onMake: { box.runtime = $0 })])

    #expect(host.health(of: "spy") == .disabled)

    host.enable("spy")
    #expect(host.health(of: "spy") == .ready)
    #expect(box.runtime?.started == 1)
    #expect(host.engine.stack.map(\.title) == ["Running"])
    #expect(host.engine.stack.first?.moduleID == "spy")

    host.disable("spy")
    #expect(host.health(of: "spy") == .disabled)
    #expect(box.runtime?.stopped == 1)
    #expect(host.engine.stack.isEmpty)
}

private final class RuntimeBox: @unchecked Sendable { var runtime: SpyRuntime? }
