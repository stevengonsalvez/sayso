import Foundation
import Testing
@testable import SaysoCore

private final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000_000) }

/// Stands in for the machine: returns whatever reading the test set, counting reads.
private final class FakeMachine: SystemStatsPort, @unchecked Sendable {
    private let lock = NSLock()
    private var reading: SystemStatsReading
    private var error: SystemStatsPortError?
    private var readCount = 0

    init(_ reading: SystemStatsReading = .calm) { self.reading = reading }

    var reads: Int { lock.withLock { readCount } }

    func set(_ change: (inout SystemStatsReading) -> Void) { lock.withLock { change(&reading) } }
    func fail(_ error: SystemStatsPortError?) { lock.withLock { self.error = error } }

    func read() throws(SystemStatsPortError) -> SystemStatsReading {
        lock.lock()
        defer { lock.unlock() }
        readCount += 1
        if let error { throw error }
        return reading
    }
}

private extension SystemStatsReading {
    /// Ticks since boot that would read as 20% busy if mistaken for a load; nothing notable.
    static let calm = SystemStatsReading(
        cpuTicks: SystemCPUTicks(user: 1_000, system: 1_000, idle: 8_000, nice: 0),
        memoryUsedFraction: 0.5,
        memoryPressure: .normal,
        batteryFraction: 0.8,
        isPluggedIn: false,
        diskFreeBytes: 100_000_000_000
    )
}

private final class FakeScheduler: SaysoScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var nextID = 0
    private var pending: [(id: Int, at: Date, action: @Sendable () -> Void)] = []
    var jobs: [Date] { lock.withLock { pending.map(\.at) } }

    func schedule(at date: Date, _ action: @escaping @Sendable () -> Void) -> SaysoSubscription {
        let id = lock.withLock { () -> Int in nextID += 1; pending.append((nextID, date, action)); return nextID }
        return SaysoSubscription { [weak self] in self?.lock.withLock { self?.pending.removeAll { $0.id == id } } }
    }

    /// Fires every job due at `now`, earliest first, like a real timer firing late.
    func runDue(_ now: Date) {
        for _ in 0..<10_000 {
            let job = lock.withLock { () -> (id: Int, at: Date, action: @Sendable () -> Void)? in
                guard let index = pending.indices.filter({ pending[$0].at <= now }).min(by: { pending[$0].at < pending[$1].at })
                else { return nil }
                return pending.remove(at: index)
            }
            guard let job else { return }
            job.action()
        }
        Issue.record("jobs kept re-arming at or before now: a runaway loop")
    }
}

private final class Captured: @unchecked Sendable {
    var runtimes: [SaysoModuleRuntime] = []
}

private struct Probe: SaysoModule {
    let inner: SystemStatsModule
    let captured: Captured
    var descriptor: SaysoModuleDescriptor { inner.descriptor }
    func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        let runtime = inner.makeRuntime(context: context)
        captured.runtimes.append(runtime)
        return runtime
    }
}

private struct Rig {
    let host: SaysoModuleHost
    let module: SystemStatsModule
    let machine: FakeMachine
    let scheduler: FakeScheduler
    let clock: Clock
    let captured: Captured

    func advance(_ seconds: TimeInterval) {
        clock.now += seconds
        scheduler.runDue(clock.now)
    }

    var retained: Int { (captured.runtimes.last as? SaysoResourceAccounting)?.retainedResources ?? -1 }
}

/// Enables the module and lets the first sample run.
private func rig(_ reading: SystemStatsReading = .calm) -> Rig {
    let clock = Clock(), scheduler = FakeScheduler(), captured = Captured()
    let machine = FakeMachine(reading)
    let module = SystemStatsModule(port: machine, scheduler: scheduler, now: { clock.now })
    let host = SaysoModuleHost(modules: [Probe(inner: module, captured: captured)], now: { clock.now })
    host.enable("system-stats")
    let rig = Rig(host: host, module: module, machine: machine, scheduler: scheduler, clock: clock, captured: captured)
    rig.advance(0)
    return rig
}

private func close(_ value: Double?, _ expected: Double) -> Bool {
    value.map { abs($0 - expected) < 1e-9 } ?? false
}

@Suite struct SystemStatsModuleTests {
    @Test func theFirstSampleIsAScheduledJobSoEnablingNeverReadsInline() {
        let clock = Clock(), scheduler = FakeScheduler(), machine = FakeMachine()
        let module = SystemStatsModule(port: machine, scheduler: scheduler, now: { clock.now })
        let host = SaysoModuleHost(modules: [module], now: { clock.now })
        host.enable("system-stats")
        #expect(machine.reads == 0)
        #expect(module.snapshot == nil)
        #expect(scheduler.jobs == [clock.now])
    }

    @Test func unobservedItSamplesOnceAMinuteWithOneJob() {
        let rig = rig()
        #expect(rig.machine.reads == 1)
        #expect(rig.scheduler.jobs == [rig.clock.now + SystemStatsModule.idleIntervalSeconds])
        rig.advance(SystemStatsModule.idleIntervalSeconds - 1)
        #expect(rig.machine.reads == 1)
        rig.advance(1)
        #expect(rig.machine.reads == 2)
        #expect(rig.scheduler.jobs.count == 1)
    }

    @Test func whileThePaneOrTheNotchIsObservedItSamplesEveryFiveSeconds() {
        let rig = rig()
        rig.module.setObserved(.studio, true)
        #expect(rig.scheduler.jobs == [rig.clock.now + SystemStatsModule.observedIntervalSeconds])
        rig.advance(SystemStatsModule.observedIntervalSeconds)
        #expect(rig.machine.reads == 2)

        rig.module.setObserved(.notch, true)
        rig.module.setObserved(.studio, false)
        #expect(rig.scheduler.jobs == [rig.clock.now + SystemStatsModule.observedIntervalSeconds], "the notch still watches")

        rig.module.setObserved(.notch, false)
        #expect(rig.scheduler.jobs == [rig.clock.now + SystemStatsModule.idleIntervalSeconds], "nobody watches: once a minute")
        rig.advance(SystemStatsModule.observedIntervalSeconds)
        #expect(rig.machine.reads == 2)
    }

    @Test func openingThePaneAfterAQuietSpellSamplesAtOnce() {
        let rig = rig()
        rig.advance(30)
        rig.module.setObserved(.studio, true)
        #expect(rig.scheduler.jobs == [rig.clock.now], "the last sample is 30 s old")
        rig.advance(0)
        #expect(rig.machine.reads == 2)
        #expect(rig.scheduler.jobs == [rig.clock.now + SystemStatsModule.observedIntervalSeconds])
    }

    @Test func cpuLoadIsTheDeltaBetweenTwoSamplesAndTheFirstSampleHasNone() {
        let rig = rig()
        #expect(rig.module.snapshot?.cpuLoad == nil, "ticks since boot are not a load")
        #expect(rig.module.snapshot?.cpuText == "Measuring")
        rig.machine.set {
            $0.cpuTicks = SystemCPUTicks(user: 1_030, system: 1_015, idle: 8_050, nice: 5)
        }
        rig.advance(SystemStatsModule.idleIntervalSeconds)
        #expect(close(rig.module.snapshot?.cpuLoad, 0.5), "50 busy of 100 ticks")
        #expect(rig.module.snapshot?.cpuText == "50%")
    }

    @Test func cpuTicksThatWrapPastTheirLimitStillGiveTheDelta() {
        let near = UInt32.max - 9
        let rig = rig(SystemStatsReading.calm.with { $0.cpuTicks = SystemCPUTicks(user: near, system: 0, idle: near, nice: 0) })
        rig.machine.set { $0.cpuTicks = SystemCPUTicks(user: 10, system: 0, idle: 50, nice: 0) }
        rig.advance(SystemStatsModule.idleIntervalSeconds)
        #expect(close(rig.module.snapshot?.cpuLoad, 20.0 / 80.0), "20 busy and 60 idle ticks across the wrap")
    }

    @Test func noTicksBetweenSamplesGivesNoLoadRatherThanANumber() {
        let rig = rig()
        rig.advance(SystemStatsModule.idleIntervalSeconds)
        #expect(rig.module.snapshot?.cpuLoad == nil)
        #expect(rig.module.snapshot?.cpuText == "Measuring")
    }

    @Test func readingsAreClampedAndNonFiniteValuesAreUnknown() throws {
        let wild = rig(SystemStatsReading.calm.with {
            $0.memoryUsedFraction = 1.4
            $0.batteryFraction = -0.2
            $0.diskFreeBytes = -5
        })
        let clamped = try #require(wild.module.snapshot)
        #expect(clamped.memoryUsedFraction == 1)
        #expect(clamped.batteryFraction == 0)
        #expect(clamped.diskFreeBytes == 0)

        let broken = rig(SystemStatsReading.calm.with {
            $0.memoryUsedFraction = .nan
            $0.batteryFraction = .infinity
        })
        let unknown = try #require(broken.module.snapshot)
        #expect(unknown.memoryUsedFraction == nil)
        #expect(unknown.batteryFraction == nil)
        #expect(unknown.memoryText == "Unknown, pressure normal")
        #expect(unknown.batteryText == "No battery")
    }

    @Test func theSnapshotIsFormattedForTheUI() throws {
        let rig = rig(SystemStatsReading.calm.with {
            $0.memoryUsedFraction = 0.625
            $0.memoryPressure = .warning
            $0.batteryFraction = 0.54
            $0.isPluggedIn = false
            $0.diskFreeBytes = 123_456_789_012
        })
        let snapshot = try #require(rig.module.snapshot)
        #expect(snapshot.memoryText == "63% used, pressure warning")
        #expect(snapshot.batteryText == "54%, on battery")
        #expect(snapshot.diskText == "123.5 GB free")
        #expect(snapshot.sampledAt == rig.clock.now)

        rig.machine.set { $0.isPluggedIn = true; $0.diskFreeBytes = 4_049_999_999 }
        rig.advance(SystemStatsModule.idleIntervalSeconds)
        #expect(rig.module.snapshot?.batteryText == "54%, plugged in")
        #expect(rig.module.snapshot?.diskText == "4.0 GB free")
    }

    @Test func aMachineWithNoBatteryReadsNoBattery() throws {
        let rig = rig(SystemStatsReading.calm.with { $0.batteryFraction = nil; $0.isPluggedIn = true })
        let snapshot = try #require(rig.module.snapshot)
        #expect(snapshot.batteryFraction == nil)
        #expect(snapshot.isPluggedIn == nil, "no battery, nothing to plug in")
        #expect(snapshot.batteryText == "No battery")
    }

    @Test func disableCancelsTheJobAndForgetsTheSnapshot() {
        let rig = rig()
        rig.module.setObserved(.studio, true)
        #expect(rig.retained == 1)
        rig.host.disable("system-stats")
        #expect(rig.retained == 0)
        #expect(rig.scheduler.jobs.isEmpty)
        #expect(rig.module.snapshot == nil)
        rig.module.setObserved(.notch, true)
        rig.module.clockChanged()
        #expect(rig.scheduler.jobs.isEmpty, "a disabled module arms nothing")

        rig.host.enable("system-stats")
        #expect(rig.scheduler.jobs == [rig.clock.now])
        rig.advance(0)
        #expect(rig.module.snapshot?.cpuLoad == nil, "a fresh start has no earlier sample to compare with")
        #expect(rig.scheduler.jobs == [rig.clock.now + SystemStatsModule.observedIntervalSeconds], "still observed")
    }

    @Test func passesTheModuleAcceptanceContract() {
        let module = SystemStatsModule(port: FakeMachine(), scheduler: FakeScheduler())
        #expect(SaysoModuleAcceptance.violations(for: module) == [])
        #expect(module.descriptor.id == "system-stats")
        #expect(module.descriptor.capabilities.isEmpty, "read-only stats need no permission")
    }
}

private extension SystemStatsReading {
    func with(_ change: (inout SystemStatsReading) -> Void) -> SystemStatsReading {
        var copy = self
        change(&copy)
        return copy
    }
}
