import Foundation
import Testing
@testable import SaysoCore

@Test func progressIsClampedAndUpdatesInPlaceOnTheSameStack() {
    var engine = SaysoActivityEngine()
    engine.publish(SaysoActivity(moduleID: "models", stackID: "dl", kind: .activeTask, title: "Downloading", progress: 0.25))
    engine.publish(SaysoActivity(moduleID: "models", stackID: "dl", kind: .activeTask, title: "Downloading", progress: 0.5))
    #expect(engine.stack.count == 1)
    #expect(engine.stack.first?.progress == 0.5)

    engine.publish(SaysoActivity(moduleID: "models", stackID: "dl", kind: .activeTask, title: "x", progress: 7))
    #expect(engine.stack.first?.progress == 1)
    engine.publish(SaysoActivity(moduleID: "models", stackID: "dl", kind: .activeTask, title: "x", progress: -3))
    #expect(engine.stack.first?.progress == 0)
    engine.publish(SaysoActivity(moduleID: "models", stackID: "dl", kind: .activeTask, title: "x", progress: .nan))
    #expect(engine.stack.first?.progress == nil)
}

@Test func contextPublishesProgressThroughTheHost() {
    final class Slot: @unchecked Sendable { var context: SaysoModuleContext? }
    final class Quiet: SaysoModuleRuntime, @unchecked Sendable { func start() {}; func stop() {} }
    struct M: SaysoModule {
        let slot: Slot
        let descriptor = SaysoModuleDescriptor(id: "m", title: "M")
        func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime { slot.context = context; return Quiet() }
    }
    let slot = Slot()
    let host = SaysoModuleHost(modules: [M(slot: slot)])
    host.enable("m")
    slot.context?.publish(stackID: "s", kind: .activeTask, title: "t", progress: 0.4)
    #expect(host.engine.stack.first?.progress == 0.4)
}
