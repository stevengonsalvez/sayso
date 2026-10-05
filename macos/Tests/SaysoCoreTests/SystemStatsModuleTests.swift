import Foundation
import Testing
@testable import SaysoCore

private final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000_000) }

/// Everything the fake machine will say, disk included.
private struct MachineState {
    var cpuTicks: SystemCPUTicks
    var memoryUsedFraction: Double?
    var memoryPressure: SystemMemoryPressure?
    var batteryFraction: Double?
    var isPluggedIn: Bool?
    var diskFreeBytes: Int64?

    /// Ticks since boot that would read as 20% busy if mistaken for a load; nothing notable.
    static let calm = MachineState(
        cpuTicks: SystemCPUTicks(user: 1_000, system: 1_000, idle: 8_000, nice: 0),
        memoryUsedFraction: 0.5,
        memoryPressure: .normal,
        batteryFraction: 0.8,
        isPluggedIn: false,
        diskFreeBytes: 100_000_000_000
    )

    func with(_ change: (inout MachineState) -> Void) -> MachineState {
        var copy = self
        change(&copy)
        return copy
    }
}

/// Stands in for the machine: returns whatever the test set, counting reads.
private final class FakeMachine: SystemStatsPort, @unchecked Sendable {
    private let lock = NSLock()
    private var state: MachineState
    private var error: SystemStatsPortError?
    private var readCount = 0
    private var diskReadCount = 0

    init(_ state: MachineState = .calm) { self.state = state }

    var reads: Int { lock.withLock { readCount } }
    var diskReads: Int { lock.withLock { diskReadCount } }

    func set(_ change: (inout MachineState) -> Void) { lock.withLock { change(&state) } }
    func fail(_ error: SystemStatsPortError?) { lock.withLock { self.error = error } }

    func read() throws(SystemStatsPortError) -> SystemStatsReading {
        lock.lock()
        defer { lock.unlock() }
        readCount += 1
        if let error { throw error }
        return SystemStatsReading(
            cpuTicks: state.cpuTicks,
            memoryUsedFraction: state.memoryUsedFraction,
            memoryPressure: state.memoryPressure,
            batteryFraction: state.batteryFraction,
            isPluggedIn: state.isPluggedIn
        )
    }

    func diskFreeBytes() -> Int64? {
        lock.withLock {
            diskReadCount += 1
            return state.diskFreeBytes
        }
    }
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

/// Every change to this module's notch lines, as titles in stack order.
private final class Painted: @unchecked Sendable {
    var changes: [[String]] = []
}

/// What the module reports through a bare context, so "reported once" can be counted exactly.
private final class Reports: @unchecked Sendable {
    var failures = 0
    var published: [SaysoActivity] = []
    var dismissed: [String] = []
}

private final class Events: @unchecked Sendable {
    var log: [String] = []
    var tapDuringNextPublish = false
}

private final class RuntimeBox: @unchecked Sendable {
    var runtime: SaysoModuleRuntime?
}

private struct Rig {
    let host: SaysoModuleHost
    let module: SystemStatsModule
    let machine: FakeMachine
    let scheduler: FakeScheduler
    let clock: Clock
    let captured: Captured
    let painted: Painted

    var lines: [SaysoActivity] { host.engine.stack.filter { $0.moduleID == "system-stats" } }
    var titles: [String] { lines.map(\.title) }

    @discardableResult
    func tap(_ actionID: String, on stackID: String) -> Bool {
        host.perform(actionID: actionID, stackID: stackID, moduleID: "system-stats")
    }

    /// Sets the machine and lets the next sample run.
    func sample(_ change: (inout MachineState) -> Void) {
        machine.set(change)
        advance(SystemStatsModule.idleIntervalSeconds)
    }

    func advance(_ seconds: TimeInterval) {
        clock.now += seconds
        scheduler.runDue(clock.now)
    }

    var retained: Int { (captured.runtimes.last as? SaysoResourceAccounting)?.retainedResources ?? -1 }
}

/// Enables the module and lets the first sample run.
private func rig(_ reading: MachineState = .calm) -> Rig {
    let clock = Clock(), scheduler = FakeScheduler(), captured = Captured(), painted = Painted()
    let machine = FakeMachine(reading)
    let module = SystemStatsModule(port: machine, scheduler: scheduler, now: { clock.now })
    let host = SaysoModuleHost(modules: [Probe(inner: module, captured: captured)], now: { clock.now })
    host.onActivitiesChanged = { [weak host] in
        painted.changes.append(host?.engine.stack.filter { $0.moduleID == "system-stats" }.map(\.title) ?? [])
    }
    host.enable("system-stats")
    let rig = Rig(
        host: host, module: module, machine: machine, scheduler: scheduler, clock: clock, captured: captured, painted: painted
    )
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
        let rig = rig(MachineState.calm.with { $0.cpuTicks = SystemCPUTicks(user: near, system: 0, idle: near, nice: 0) })
        rig.machine.set { $0.cpuTicks = SystemCPUTicks(user: 10, system: 0, idle: 170, nice: 0) }
        rig.advance(SystemStatsModule.idleIntervalSeconds)
        #expect(close(rig.module.snapshot?.cpuLoad, 20.0 / 200.0), "20 busy and 180 idle ticks across the wrap")
    }

    @Test func noTicksBetweenSamplesGivesNoLoadRatherThanANumber() {
        let rig = rig()
        rig.advance(SystemStatsModule.idleIntervalSeconds)
        #expect(rig.module.snapshot?.cpuLoad == nil)
        #expect(rig.module.snapshot?.cpuText == "Measuring")
    }

    @Test func readingsAreClampedAndNonFiniteValuesAreUnknown() throws {
        let wild = rig(MachineState.calm.with {
            $0.memoryUsedFraction = 1.4
            $0.batteryFraction = -0.2
            $0.diskFreeBytes = -5
        })
        let clamped = try #require(wild.module.snapshot)
        #expect(clamped.memoryUsedFraction == 1)
        #expect(clamped.batteryFraction == 0)
        #expect(clamped.diskFreeBytes == 0)

        let broken = rig(MachineState.calm.with {
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
        let rig = rig(MachineState.calm.with {
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
        let rig = rig(MachineState.calm.with { $0.batteryFraction = nil; $0.isPluggedIn = true })
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

    @Test func nothingNotableShowsNoLine() {
        let rig = rig()
        #expect(rig.lines.isEmpty, "a calm machine never puts a permanent line in the notch")
        rig.module.setObserved(.notch, true)
        rig.advance(SystemStatsModule.observedIntervalSeconds)
        #expect(rig.lines.isEmpty)
    }

    @Test func aLowBatteryOnBatteryShowsALowPriorityLineAndPluggingInClearsIt() throws {
        let rig = rig(MachineState.calm.with { $0.batteryFraction = 0.18 })
        let line = try #require(rig.lines.first)
        #expect(rig.lines.count == 1)
        #expect(line.stackID == "system-stats-battery")
        #expect(line.title == "Battery 18%, not plugged in")
        #expect(line.kind == .ambient, "below every task, completion, failure and confirmation")
        #expect(line.interruption == .normal)
        #expect(line.progress == nil)
        #expect(line.expiresAfter == nil)
        #expect(line.actions.map(\.id) == ["dismiss"])

        rig.sample { $0.isPluggedIn = true }
        #expect(rig.lines.isEmpty, "plugged in: nothing to warn about")
    }

    @Test func batteryEntersAtTwentyAndClearsOnlyAtTwentyFiveSoItNeverFlaps() {
        let rig = rig(MachineState.calm.with { $0.batteryFraction = 0.21 })
        #expect(rig.lines.isEmpty)
        rig.sample { $0.batteryFraction = 0.20 }
        #expect(rig.titles == ["Battery 20%, not plugged in"])
        rig.sample { $0.batteryFraction = 0.22 }
        #expect(rig.titles == ["Battery 22%, not plugged in"], "a small recovery does not clear it")
        rig.sample { $0.batteryFraction = 0.24 }
        #expect(rig.lines.count == 1)
        rig.sample { $0.batteryFraction = 0.25 }
        #expect(rig.lines.isEmpty)
        rig.sample { $0.batteryFraction = 0.22 }
        #expect(rig.lines.isEmpty, "below 25 but above 20 again: still clear")
        rig.sample { $0.batteryFraction = 0.19 }
        #expect(rig.titles == ["Battery 19%, not plugged in"])
    }

    @Test func aMachineWithNoBatteryNeverShowsABatteryLine() {
        let rig = rig(MachineState.calm.with { $0.batteryFraction = nil; $0.isPluggedIn = false })
        #expect(rig.lines.isEmpty)
        rig.sample { $0.batteryFraction = .nan }
        #expect(rig.lines.isEmpty, "an unreadable battery is no battery")
        rig.sample { $0.batteryFraction = 0.1; $0.isPluggedIn = nil }
        #expect(rig.lines.isEmpty, "a level without a power state cannot say it is not charging")
    }

    @Test func criticalMemoryPressureShowsALineUntilPressureIsNormalAgain() {
        let rig = rig(MachineState.calm.with { $0.memoryPressure = .warning; $0.memoryUsedFraction = 0.9 })
        #expect(rig.lines.isEmpty, "warning alone is not notable")
        rig.sample { $0.memoryPressure = .critical; $0.memoryUsedFraction = 0.94 }
        #expect(rig.lines.map(\.stackID) == ["system-stats-memory"])
        #expect(rig.titles == ["Memory pressure critical"], "no used percent: it would repaint the line on every sample")
        rig.sample { $0.memoryUsedFraction = 0.95 }
        #expect(rig.titles == ["Memory pressure critical"])
        rig.sample { $0.memoryPressure = .warning }
        #expect(rig.titles == ["Memory pressure warning"], "easing to warning does not clear it")
        rig.sample { $0.memoryPressure = .normal }
        #expect(rig.lines.isEmpty)
    }

    @Test func lessThanFiveGigabytesFreeShowsALineUntilSixAreFree() {
        let rig = rig(MachineState.calm.with { $0.diskFreeBytes = 5_000_000_000 })
        #expect(rig.lines.isEmpty)
        rig.sample { $0.diskFreeBytes = 4_960_000_000 }
        #expect(rig.lines.map(\.stackID) == ["system-stats-disk"])
        #expect(rig.titles == ["Disk almost full, 4.9 GB free"], "rounded down, so it never reads 5.0 below 5 GB")
        rig.sample { $0.diskFreeBytes = 5_900_000_000 }
        #expect(rig.lines.count == 1)
        rig.sample { $0.diskFreeBytes = 6_000_000_000 }
        #expect(rig.lines.isEmpty)
    }

    @Test func dismissKeepsALineHiddenUntilItsConditionClearsAndReturns() {
        let rig = rig(MachineState.calm.with { $0.batteryFraction = 0.18; $0.diskFreeBytes = 1_000_000_000 })
        #expect(rig.lines.count == 2)
        #expect(rig.tap("dismiss", on: "system-stats-battery"))
        #expect(rig.scheduler.jobs == [rig.clock.now], "the job applies the dismissal")
        let reads = rig.machine.reads
        rig.advance(0)
        #expect(rig.machine.reads == reads, "a repaint is not a sample")
        #expect(rig.lines.map(\.stackID) == ["system-stats-disk"], "only the dismissed line goes")
        rig.sample { $0.batteryFraction = 0.17 }
        #expect(rig.lines.map(\.stackID) == ["system-stats-disk"], "still low: stays hidden")
        rig.sample { $0.batteryFraction = 0.26 }
        rig.sample { $0.batteryFraction = 0.19 }
        #expect(rig.titles.contains("Battery 19%, not plugged in"), "cleared, then low again: it returns")
    }

    @Test func aLineIsRepublishedOnlyWhenItsTextChanges() {
        let rig = rig(MachineState.calm.with { $0.batteryFraction = 0.18 })
        let before = rig.painted.changes.count
        rig.module.setObserved(.notch, true)
        for _ in 0..<6 { rig.advance(SystemStatsModule.observedIntervalSeconds) }
        #expect(rig.painted.changes.count == before, "same text, same line: no repaint")
        rig.sample { $0.batteryFraction = 0.17 }
        #expect(rig.painted.changes.count == before + 1)
    }

    @Test func aFailingMachineReadIsReportedOnceAndBacksOff() {
        let clock = Clock(), scheduler = FakeScheduler(), reports = Reports()
        let machine = FakeMachine(MachineState.calm.with { $0.batteryFraction = 0.18 })
        let module = SystemStatsModule(port: machine, scheduler: scheduler, now: { clock.now })
        let runtime = module.makeRuntime(context: SaysoModuleContext(
            moduleID: "system-stats",
            publish: { reports.published.append($0) },
            reportFailure: { reports.failures += 1 },
            dismiss: { reports.dismissed.append($0) }
        ))
        func advance(_ seconds: TimeInterval) {
            clock.now += seconds
            scheduler.runDue(clock.now)
        }
        module.setObserved(.studio, true)
        runtime.start()
        advance(0)
        #expect(reports.published.map(\.title) == ["Battery 18%, not plugged in"])

        machine.fail(.unavailable)
        advance(SystemStatsModule.observedIntervalSeconds)
        #expect(reports.failures == 1)
        #expect(module.snapshot == nil, "a failed read cannot vouch for the old figures")
        #expect(reports.dismissed == ["system-stats-battery"], "nor for the old line")
        #expect(scheduler.jobs == [clock.now + SystemStatsModule.failureBackoffSeconds], "backs off even while observed")
        for _ in 0..<5 { advance(SystemStatsModule.failureBackoffSeconds) }
        #expect(machine.reads == 7)
        #expect(reports.failures == 1, "a lasting failure is reported once, not on every sample")

        machine.fail(nil)
        advance(SystemStatsModule.failureBackoffSeconds)
        #expect(module.snapshot != nil)
        #expect(reports.published.last?.title == "Battery 18%, not plugged in", "still low after the outage")
        #expect(scheduler.jobs == [clock.now + SystemStatsModule.observedIntervalSeconds])
    }

    @Test func aLastingFailureLeavesTheModuleDegradedNeverQuarantined() {
        let rig = rig()
        rig.machine.fail(.unavailable)
        rig.advance(SystemStatsModule.idleIntervalSeconds)
        #expect(rig.host.health(of: "system-stats") == .degraded)
        for _ in 0..<20 { rig.advance(SystemStatsModule.failureBackoffSeconds) }
        #expect(rig.host.health(of: "system-stats") != .quarantined)
        rig.machine.fail(nil)
        for _ in 0..<3 {
            rig.advance(SystemStatsModule.idleIntervalSeconds)
            rig.machine.fail(.unavailable)
            rig.advance(SystemStatsModule.failureBackoffSeconds)
            rig.machine.fail(nil)
        }
        #expect(rig.host.health(of: "system-stats") != .quarantined, "flaky reads within five minutes report at most once")
    }

    @Test func aFailedReadKeepsDismissAndTheEnteredState() {
        let dismissed = rig(MachineState.calm.with { $0.batteryFraction = 0.18 })
        dismissed.tap("dismiss", on: "system-stats-battery")
        dismissed.machine.fail(.unavailable)
        dismissed.advance(SystemStatsModule.idleIntervalSeconds)
        dismissed.machine.fail(nil)
        dismissed.sample { $0.batteryFraction = 0.17 }
        #expect(dismissed.lines.isEmpty, "dismissed and still low: an outage in between does not bring it back")

        let entered = rig(MachineState.calm.with { $0.batteryFraction = 0.18 })
        entered.machine.fail(.unavailable)
        entered.advance(SystemStatsModule.idleIntervalSeconds)
        entered.machine.fail(nil)
        entered.sample { $0.batteryFraction = 0.22 }
        #expect(entered.titles == ["Battery 22%, not plugged in"], "entered before the outage and not yet recovered")
    }

    @Test func aClockSetBackSamplesAtOnceInsteadOfWaitingForTheOldTime() {
        let rig = rig()
        rig.module.setObserved(.studio, true)
        rig.clock.now -= 3_600
        rig.module.clockChanged()
        #expect(rig.scheduler.jobs == [rig.clock.now], "the pending job was set against the old time")
        rig.advance(0)
        #expect(rig.machine.reads == 2)
        #expect(rig.scheduler.jobs == [rig.clock.now + SystemStatsModule.observedIntervalSeconds])
    }

    @Test func aFailureReportedBeforeTheClockWentBackDoesNotSilenceTheNextOneForAnHour() {
        let clock = Clock(), scheduler = FakeScheduler(), reports = Reports(), machine = FakeMachine()
        let module = SystemStatsModule(port: machine, scheduler: scheduler, now: { clock.now })
        let runtime = module.makeRuntime(context: SaysoModuleContext(
            moduleID: "system-stats", publish: { _ in }, reportFailure: { reports.failures += 1 }
        ))
        func advance(_ seconds: TimeInterval) {
            clock.now += seconds
            scheduler.runDue(clock.now)
        }
        runtime.start()
        machine.fail(.unavailable)
        advance(0)
        #expect(reports.failures == 1)
        machine.fail(nil)
        clock.now -= 3_600
        module.clockChanged()
        advance(SystemStatsModule.failureReportWindowSeconds)
        machine.fail(.unavailable)
        advance(SystemStatsModule.idleIntervalSeconds)
        #expect(reports.failures == 2, "a new failure a full window after the last report is reported")
    }

    @Test func aDismissLandingWhileASampleIsPublishingNeverLeavesAGhostLine() {
        let clock = Clock(), scheduler = FakeScheduler(), events = Events()
        let machine = FakeMachine(MachineState.calm.with { $0.batteryFraction = 0.18 })
        let module = SystemStatsModule(port: machine, scheduler: scheduler, now: { clock.now })
        let box = RuntimeBox()
        let runtime = module.makeRuntime(context: SaysoModuleContext(
            moduleID: "system-stats",
            publish: { activity in
                // The user taps Dismiss on the old line between the sample deciding to repaint and the repaint.
                if events.tapDuringNextPublish {
                    events.tapDuringNextPublish = false
                    box.runtime?.handle(stackID: activity.stackID, actionID: "dismiss")
                }
                events.log.append("show \(activity.title)")
            },
            dismiss: { events.log.append("clear \($0)") }
        ))
        box.runtime = runtime
        func advance(_ seconds: TimeInterval) {
            clock.now += seconds
            scheduler.runDue(clock.now)
        }
        runtime.start()
        advance(0)
        events.tapDuringNextPublish = true
        machine.set { $0.batteryFraction = 0.17 }
        advance(SystemStatsModule.idleIntervalSeconds)
        advance(0)
        #expect(events.log.last == "clear system-stats-battery", "the dismissed line ends up cleared: \(events.log)")

        machine.set { $0.batteryFraction = 0.30 }
        advance(SystemStatsModule.idleIntervalSeconds)
        machine.set { $0.batteryFraction = 0.15 }
        advance(SystemStatsModule.idleIntervalSeconds)
        #expect(events.log.last == "show Battery 15%, not plugged in", "and comes back after it clears: \(events.log)")
    }

    @Test func aViewerChangeNeverPushesAPendingDismissOrClockChangeLater() {
        let rig = rig(MachineState.calm.with { $0.batteryFraction = 0.18 })
        rig.tap("dismiss", on: "system-stats-battery")
        rig.module.setObserved(.notch, true)
        rig.module.setObserved(.notch, false)
        #expect(rig.scheduler.jobs == [rig.clock.now], "the dismissal still lands at once")
        rig.advance(0)
        #expect(rig.lines.isEmpty)

        rig.advance(1)
        rig.module.clockChanged()
        rig.module.setObserved(.studio, true)
        #expect(rig.scheduler.jobs == [rig.clock.now], "the clock change still samples at once")
    }

    @Test func aSampleTooSoonAfterTheLastKeepsTheMeasuredLoadInsteadOfAFewTicksOfNoise() {
        let rig = rig()
        rig.machine.set { $0.cpuTicks = SystemCPUTicks(user: 1_300, system: 1_200, idle: 8_500, nice: 0) }
        rig.advance(SystemStatsModule.idleIntervalSeconds)
        #expect(close(rig.module.snapshot?.cpuLoad, 0.5))

        // A clock change forces a sample a moment later: 3 busy ticks of 4 would read as 75%.
        rig.machine.set { $0.cpuTicks = SystemCPUTicks(user: 1_303, system: 1_200, idle: 8_501, nice: 0) }
        rig.module.clockChanged()
        rig.advance(0)
        #expect(close(rig.module.snapshot?.cpuLoad, 0.5), "too few ticks to measure: the last load stands")

        rig.machine.set { $0.cpuTicks = SystemCPUTicks(user: 1_400, system: 1_200, idle: 8_800, nice: 0) }
        rig.advance(SystemStatsModule.idleIntervalSeconds)
        #expect(close(rig.module.snapshot?.cpuLoad, 0.25), "measured from the last sample that counted: 100 busy of 400")
    }

    @Test func freeDiskIsAskedOnceAMinuteEvenWhileObservedBecauseTheQueryIsSlow() {
        let rig = rig()
        #expect(rig.machine.diskReads == 1)
        rig.module.setObserved(.notch, true)
        rig.machine.set { $0.diskFreeBytes = 90_000_000_000 }
        for _ in 0..<11 { rig.advance(SystemStatsModule.observedIntervalSeconds) }
        #expect(rig.machine.reads == 12)
        #expect(rig.machine.diskReads == 1)
        #expect(rig.module.snapshot?.diskText == "100.0 GB free", "the last disk reading stands between disk reads")
        rig.advance(SystemStatsModule.observedIntervalSeconds)
        #expect(rig.machine.diskReads == 2)
        #expect(rig.module.snapshot?.diskText == "90.0 GB free")
    }

    @Test func aFigureTheSystemCannotGiveReadsUnknownWithoutBlankingTheRest() throws {
        let rig = rig(MachineState.calm.with { $0.memoryPressure = .critical })
        #expect(rig.titles == ["Memory pressure critical"])
        rig.sample { $0.memoryPressure = nil; $0.memoryUsedFraction = nil; $0.diskFreeBytes = nil }
        let snapshot = try #require(rig.module.snapshot, "CPU and battery still read")
        #expect(snapshot.memoryText == "Unknown")
        #expect(snapshot.diskText == "Unknown")
        #expect(snapshot.batteryText == "80%, on battery")
        #expect(rig.lines.isEmpty, "an unknown pressure cannot vouch for a critical line")
        #expect(rig.host.health(of: "system-stats") == .ready, "a missing figure is not a failure")

        rig.sample { $0.memoryUsedFraction = 0.7 }
        #expect(rig.module.snapshot?.memoryText == "70% used")
    }

    @Test func passesTheModuleAcceptanceContract() {
        let module = SystemStatsModule(port: FakeMachine(), scheduler: FakeScheduler())
        #expect(SaysoModuleAcceptance.violations(for: module) == [])
        #expect(module.descriptor.id == "system-stats")
        #expect(module.descriptor.capabilities.isEmpty, "read-only stats need no permission")
    }
}
