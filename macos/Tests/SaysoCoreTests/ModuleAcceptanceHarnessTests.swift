import Foundation
import Testing
@testable import SaysoCore

private final class Timerish: SaysoModuleRuntime, SaysoResourceAccounting, @unchecked Sendable {
    let context: SaysoModuleContext
    let leaks: Bool
    var retainedResources = 0
    init(context: SaysoModuleContext, leaks: Bool) { self.context = context; self.leaks = leaks }
    func start() {
        retainedResources = 1
        context.publish(stackID: "main", kind: .activeTask, title: "Running")
    }
    func stop() { if !leaks { retainedResources = 0 } }
}

private struct FakeModule: SaysoModule {
    var leaks = false
    let descriptor = SaysoModuleDescriptor(id: "fake", title: "Fake", capabilities: [.clipboard])
    func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime { Timerish(context: context, leaks: leaks) }
}

@Test func harnessPassesAWellBehavedModule() {
    #expect(SaysoModuleAcceptance.violations(for: FakeModule()) == [])
}

@Test func harnessFlagsAModuleThatRetainsResourcesAfterStop() {
    #expect(SaysoModuleAcceptance.violations(for: FakeModule(leaks: true)) == ["resources retained after disable: 1"])
}

private struct UnaccountedModule: SaysoModule {
    let descriptor = SaysoModuleDescriptor(id: "plain", title: "Plain")
    func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime { Bare() }
}
private final class Bare: SaysoModuleRuntime, @unchecked Sendable {
    func start() {}
    func stop() {}
}

@Test func harnessRequiresResourceAccounting() {
    #expect(SaysoModuleAcceptance.violations(for: UnaccountedModule()) == ["runtime does not report retainedResources"])
}
