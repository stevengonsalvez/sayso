import Foundation
import Testing
@testable import SaysoCore

private final class Probe: SaysoModuleRuntime, @unchecked Sendable {
    var started = 0
    func start() { started += 1 }
    func stop() {}
}

private final class ProbeBox: @unchecked Sendable { let probe = Probe() }

private struct NeedsClipboard: SaysoModule {
    let box: ProbeBox
    let descriptor = SaysoModuleDescriptor(id: "clip", title: "Clip", capabilities: [.clipboard])
    func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime { box.probe }
}

@Test func deniedCapabilityBlocksStartUntilGrantedThenEnableSucceeds() {
    let box = ProbeBox()
    let granted = GrantBox()
    let host = SaysoModuleHost(modules: [NeedsClipboard(box: box)], isGranted: { granted.value.contains($0) })

    host.enable("clip")
    #expect(host.health(of: "clip") == .permissionRequired)
    #expect(box.probe.started == 0)

    granted.value = [.clipboard]
    host.enable("clip")
    #expect(host.health(of: "clip") == .ready)
    #expect(box.probe.started == 1)
}

private final class GrantBox: @unchecked Sendable { var value: Set<SaysoCapability> = [] }
