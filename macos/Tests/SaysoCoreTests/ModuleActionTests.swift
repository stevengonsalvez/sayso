import Foundation
import Testing
@testable import SaysoCore

private final class Recorder: SaysoModuleRuntime, @unchecked Sendable {
    var handled: [String] = []
    let context: SaysoModuleContext
    init(context: SaysoModuleContext) { self.context = context }
    func start() {
        context.publish(
            stackID: "ask", kind: .confirmation, title: "Delete?",
            actions: [SaysoAction(id: "confirm", title: "Delete")]
        )
    }
    func stop() {}
    func handle(actionID: String) { handled.append(actionID) }
}

private final class Holder: @unchecked Sendable { var runtime: Recorder? }

private struct AskModule: SaysoModule {
    let holder: Holder
    let descriptor = SaysoModuleDescriptor(id: "ask", title: "Ask")
    func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        let runtime = Recorder(context: context)
        holder.runtime = runtime
        return runtime
    }
}

@Test func onlyActionsOfAPublishedActivityReachTheOwningRuntime() {
    let holder = Holder()
    let host = SaysoModuleHost(modules: [AskModule(holder: holder)])
    host.enable("ask")

    #expect(host.perform(actionID: "confirm", moduleID: "ask") == true)
    #expect(host.perform(actionID: "wipe-disk", moduleID: "ask") == false)
    #expect(host.perform(actionID: "confirm", moduleID: "other") == false)
    #expect(holder.runtime?.handled == ["confirm"])

    host.disable("ask")
    #expect(host.perform(actionID: "confirm", moduleID: "ask") == false)
    #expect(holder.runtime?.handled == ["confirm"])
}
