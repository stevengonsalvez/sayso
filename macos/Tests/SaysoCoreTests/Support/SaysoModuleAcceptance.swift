import Foundation
@testable import SaysoCore

private final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000_000) }
private final class Flag: @unchecked Sendable { var granted = true }

/// Records what the host builds so the harness can observe real runtimes without faking the host.
private final class ProbeLog: @unchecked Sendable {
    var runtimes: [SaysoModuleRuntime] = []
    var contexts: [SaysoModuleContext] = []
}

private struct ProbeModule: SaysoModule {
    let inner: SaysoModule
    let log: ProbeLog
    var descriptor: SaysoModuleDescriptor { inner.descriptor }
    func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        let runtime = inner.makeRuntime(context: context)
        log.runtimes.append(runtime)
        log.contexts.append(context)
        return runtime
    }
}

/// Black-box contract every module must satisfy, run against the real host and activity engine.
enum SaysoModuleAcceptance {
    static func violations(for module: SaysoModule) -> [String] {
        let id = module.descriptor.id
        var found: [String] = []
        let clock = Clock(), flag = Flag(), log = ProbeLog()
        let host = SaysoModuleHost(
            modules: [ProbeModule(inner: module, log: log)],
            now: { clock.now },
            isGranted: { _ in flag.granted }
        )

        if host.health(of: id) != .disabled { found.append("not disabled by default") }

        if !module.descriptor.capabilities.isEmpty {
            flag.granted = false
            host.enable(id)
            if host.health(of: id) != .permissionRequired { found.append("denied capability did not require permission") }
            if !log.runtimes.isEmpty { found.append("runtime started despite denied capability") }
            flag.granted = true
        }

        host.enable(id)
        host.enable(id)
        if host.health(of: id) != .ready { found.append("not ready after enable") }
        if log.runtimes.count != 1 { found.append("enable is not idempotent: \(log.runtimes.count) runtimes") }

        guard let runtime = log.runtimes.first, let context = log.contexts.first else { return found }
        guard let accounting = runtime as? SaysoResourceAccounting else {
            return found + ["runtime does not report retainedResources"]
        }

        host.disable(id)
        if host.health(of: id) != .disabled { found.append("not disabled after disable") }
        if accounting.retainedResources != 0 {
            found.append("resources retained after disable: \(accounting.retainedResources)")
        }
        if host.engine.stack.contains(where: { $0.moduleID == id }) { found.append("activities remain after disable") }

        context.publish(stackID: "late", kind: .failure, title: "late")
        if host.engine.stack.contains(where: { $0.moduleID == id }) { found.append("published after disable") }

        host.enable(id)
        if let fresh = log.contexts.last {
            for _ in 0..<3 { fresh.reportFailure() }
            if host.health(of: id) != .quarantined { found.append("three failures did not quarantine") }
        }
        return found
    }
}
