import Foundation
import Testing
@testable import SaysoCore

private final class Lingering: SaysoModuleRuntime, @unchecked Sendable {
    let context: SaysoModuleContext
    init(context: SaysoModuleContext) { self.context = context }
    func start() {}
    func stop() {}
}

private final class Keep: @unchecked Sendable { var runtime: Lingering? }

private struct LingeringModule: SaysoModule {
    let keep: Keep
    let descriptor = SaysoModuleDescriptor(id: "late", title: "Late")
    func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        let runtime = Lingering(context: context)
        keep.runtime = runtime
        return runtime
    }
}

@Test func stoppedOrReplacedRuntimeCannotPublishThroughItsOldContext() {
    let keep = Keep()
    let host = SaysoModuleHost(modules: [LingeringModule(keep: keep)])
    host.enable("late")
    let oldContext = keep.runtime!.context

    host.disable("late")
    oldContext.publish(stackID: "ghost", kind: .failure, title: "Ghost")
    #expect(host.engine.stack.isEmpty)

    host.enable("late")
    oldContext.publish(stackID: "ghost", kind: .failure, title: "Ghost")
    #expect(host.engine.stack.isEmpty)

    keep.runtime!.context.publish(stackID: "live", kind: .activeTask, title: "Live")
    #expect(host.engine.stack.map(\.title) == ["Live"])
}
