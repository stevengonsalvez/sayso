import Foundation
import Testing
@testable import SaysoCore

private final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 50_000) }
private final class Grants: @unchecked Sendable { var value: Set<SaysoCapability> = [.clipboard] }
private final class Handles: @unchecked Sendable { var runtimes: [String: ScriptedRuntime] = [:] }

private final class ScriptedRuntime: SaysoModuleRuntime, @unchecked Sendable {
    let context: SaysoModuleContext
    var stops = 0
    var handled: [String] = []
    init(context: SaysoModuleContext) { self.context = context }
    func start() {}
    func stop() { stops += 1 }
    func handle(actionID: String) { handled.append(actionID) }
}

private struct ScriptedModule: SaysoModule {
    let descriptor: SaysoModuleDescriptor
    let handles: Handles
    func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        let runtime = ScriptedRuntime(context: context)
        handles.runtimes[descriptor.id] = runtime
        return runtime
    }
}

private func makeHost(
    ids: [String] = ["m"], capabilities: Set<SaysoCapability> = [], clock: Clock = Clock(),
    grants: Grants = Grants(), handles: Handles = Handles()
) -> SaysoModuleHost {
    SaysoModuleHost(
        modules: ids.map { ScriptedModule(descriptor: .init(id: $0, title: $0, capabilities: capabilities), handles: handles) },
        now: { clock.now },
        isGranted: { grants.value.contains($0) }
    )
}

@Test func hostExpiresAlertsAndRefusesActionsOnExpiredActivities() {
    let clock = Clock(); let handles = Handles()
    let host = makeHost(clock: clock, handles: handles)
    host.enable("m")
    handles.runtimes["m"]?.context.publish(
        stackID: "copy", kind: .completion, title: "Copied", expiresAfter: 3,
        actions: [SaysoAction(id: "undo", title: "Undo")]
    )
    #expect(host.perform(actionID: "undo", moduleID: "m"))

    clock.now += 3
    #expect(!host.perform(actionID: "undo", moduleID: "m"))
    host.tick()
    #expect(host.engine.stack.isEmpty)
}

@Test func hostExposesPinUnpinAndDismiss() {
    let handles = Handles()
    let host = makeHost(handles: handles)
    host.enable("m")
    let context = handles.runtimes["m"]!.context
    context.publish(stackID: "np", kind: .ambient, title: "Song")
    context.publish(stackID: "err", kind: .failure, title: "Err")
    host.pin(moduleID: "m", stackID: "np")
    #expect(host.engine.primary?.title == "Song")
    host.unpin()
    #expect(host.engine.primary?.title == "Err")
    host.dismiss(moduleID: "m", stackID: "err")
    #expect(host.engine.stack.map(\.title) == ["Song"])
}

@Test func degradedHealthDecaysAndReenableResetsFailureCount() {
    let clock = Clock(); let handles = Handles()
    let host = makeHost(clock: clock, handles: handles)
    host.enable("m")
    handles.runtimes["m"]?.context.reportFailure()
    #expect(host.health(of: "m") == .degraded)
    clock.now += 301
    #expect(host.health(of: "m") == .ready)

    handles.runtimes["m"]?.context.reportFailure()
    host.disable("m")
    host.enable("m")
    #expect(host.health(of: "m") == .ready)
}

@Test func quarantineCanBeClearedByTheUser() {
    let handles = Handles()
    let host = makeHost(handles: handles)
    host.enable("m")
    for _ in 0..<3 { handles.runtimes["m"]?.context.reportFailure() }
    #expect(host.health(of: "m") == .quarantined)

    host.clearQuarantine("m")
    host.enable("m")
    #expect(host.health(of: "m") == .ready)
}

@Test func revokedCapabilityStopsRunningModuleAndDisableClearsPermissionState() {
    let grants = Grants(); let handles = Handles()
    let host = makeHost(capabilities: [.clipboard], grants: grants, handles: handles)
    host.enable("m")
    handles.runtimes["m"]?.context.publish(stackID: "s", kind: .activeTask, title: "T")

    grants.value = []
    host.capabilitiesChanged()
    #expect(host.health(of: "m") == .permissionRequired)
    #expect(handles.runtimes["m"]?.stops == 1)
    #expect(host.engine.stack.isEmpty)

    host.disable("m")
    #expect(host.health(of: "m") == .disabled)
}

@Test func duplicateModuleIDsKeepTheFirstRegistration() {
    let handles = Handles()
    let host = SaysoModuleHost(modules: [
        ScriptedModule(descriptor: .init(id: "dup", title: "first"), handles: handles),
        ScriptedModule(descriptor: .init(id: "dup", title: "second"), handles: handles),
    ])
    #expect(host.descriptors.map(\.title) == ["first"])
}
