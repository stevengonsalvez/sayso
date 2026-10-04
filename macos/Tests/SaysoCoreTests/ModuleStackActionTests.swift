import Foundation
import Testing
@testable import SaysoCore

private final class Log: @unchecked Sendable { var calls: [String] = [] }
private final class Slot: @unchecked Sendable { var context: SaysoModuleContext? }

private final class Files: SaysoModuleRuntime, @unchecked Sendable {
    let context: SaysoModuleContext
    let log: Log
    init(context: SaysoModuleContext, log: Log) { self.context = context; self.log = log }
    func start() {}
    func stop() {}
    func handle(stackID: String, actionID: String) { log.calls.append("\(stackID):\(actionID)") }
}

private struct FilesModule: SaysoModule {
    let log: Log
    let slot: Slot
    let descriptor = SaysoModuleDescriptor(id: "files", title: "Files")
    func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        slot.context = context
        return Files(context: context, log: log)
    }
}

@Test func actionsAreScopedToTheActivityThatDeclaredThem() {
    let log = Log(), slot = Slot()
    let host = SaysoModuleHost(modules: [FilesModule(log: log, slot: slot)])
    host.enable("files")
    let reveal = [SaysoAction(id: "reveal", title: "Reveal")]
    slot.context?.publish(stackID: "copy-a", kind: .completion, title: "A", actions: reveal)
    slot.context?.publish(stackID: "copy-b", kind: .completion, title: "B")

    #expect(host.perform(actionID: "reveal", stackID: "copy-a", moduleID: "files"))
    #expect(!host.perform(actionID: "reveal", stackID: "copy-b", moduleID: "files"))
    #expect(log.calls == ["copy-a:reveal"])
}

@Test func modulesCanPublishCriticalActivities() {
    let log = Log(), slot = Slot()
    let host = SaysoModuleHost(modules: [FilesModule(log: log, slot: slot)])
    host.enable("files")
    slot.context?.publish(stackID: "np", kind: .ambient, title: "Song")
    host.pin(moduleID: "files", stackID: "np")
    slot.context?.publish(stackID: "ask", kind: .confirmation, title: "Delete?", interruption: .critical)
    #expect(host.engine.primary?.title == "Delete?")
}
