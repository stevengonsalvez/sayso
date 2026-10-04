import Foundation
import Testing
@testable import SaysoCore

private final class Slot: @unchecked Sendable { var context: SaysoModuleContext? }

private final class Quiet: SaysoModuleRuntime, @unchecked Sendable {
    func start() {}
    func stop() {}
}

private struct BusyModule: SaysoModule {
    let slot: Slot
    let descriptor = SaysoModuleDescriptor(id: "busy", title: "Busy")
    func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        slot.context = context
        return Quiet()
    }
}

@Test func concurrentPublishesFromManyThreadsAreSerializedWithoutLoss() {
    let slot = Slot()
    let host = SaysoModuleHost(modules: [BusyModule(slot: slot)])
    host.enable("busy")
    let context = slot.context!

    DispatchQueue.concurrentPerform(iterations: 8) { worker in
        for n in 0..<250 {
            context.publish(stackID: "w\(worker)-\(n)", kind: .ambient, title: "t")
            if n % 50 == 0 { host.tick() }
        }
    }

    #expect(host.engine.stack.count == 2_000)
}
