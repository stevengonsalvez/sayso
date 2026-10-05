import Foundation
import Testing
@testable import SaysoCore

/// Counts live assertions so a leak or a moment with two held fails the test.
private final class FakePowerPort: PowerAssertionPort, @unchecked Sendable {
    private let lock = NSLock()
    private var live = 0
    private var peak = 0
    private var names: [String] = []
    private var refusing = false

    var held: Int { lock.withLock { live } }
    var peakHeld: Int { lock.withLock { peak } }
    var requestedNames: [String] { lock.withLock { names } }
    func refuse(_ on: Bool) { lock.withLock { refusing = on } }

    func createAssertion(named name: String) -> PowerAssertion? {
        let granted = lock.withLock { () -> Bool in
            names.append(name)
            guard !refusing else { return false }
            live += 1
            peak = max(peak, live)
            return true
        }
        guard granted else { return nil }
        return PowerAssertion { [weak self] in self?.lock.withLock { self?.live -= 1 } }
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
        Issue.record("ticks kept re-arming at or before now: a runaway tick loop")
    }
}

private final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000_000) }

private final class Captured: @unchecked Sendable {
    var runtimes: [SaysoModuleRuntime] = []
    var contexts: [SaysoModuleContext] = []
}

/// Hands the real runtime and context to the test so resource accounting and failures can be driven.
private struct Probe: SaysoModule {
    let inner: CaffeineModule
    let captured: Captured
    var descriptor: SaysoModuleDescriptor { inner.descriptor }
    func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        let runtime = inner.makeRuntime(context: context)
        captured.runtimes.append(runtime)
        captured.contexts.append(context)
        return runtime
    }
}

private struct Rig {
    let host: SaysoModuleHost
    let module: CaffeineModule
    let port: FakePowerPort
    let scheduler: FakeScheduler
    let clock: Clock
    let captured: Captured

    func advance(_ seconds: TimeInterval) {
        clock.now += seconds
        scheduler.runDue(clock.now)
    }

    var activities: [SaysoActivity] { host.engine.stack.filter { $0.moduleID == "caffeine" } }
    var running: [SaysoActivity] { activities.filter { $0.kind == .activeTask } }
    var retained: Int { (captured.runtimes.last as? SaysoResourceAccounting)?.retainedResources ?? -1 }
}

private func rig() -> Rig {
    let port = FakePowerPort(), scheduler = FakeScheduler(), clock = Clock(), captured = Captured()
    let module = CaffeineModule(port: port, scheduler: scheduler, now: { clock.now })
    let host = SaysoModuleHost(modules: [Probe(inner: module, captured: captured)], now: { clock.now })
    host.enable("caffeine")
    return Rig(host: host, module: module, port: port, scheduler: scheduler, clock: clock, captured: captured)
}

@Suite struct CaffeineModuleTests {
    @Test func fifteenMinutesHoldsOneNamedAssertionAndShowsTheTimeLeft() throws {
        let rig = rig()
        #expect(rig.module.start(.fifteenMinutes))

        #expect(rig.port.held == 1)
        #expect(rig.port.requestedNames == ["Sayso Caffeine"])
        let shown = try #require(rig.running.first)
        #expect(rig.running.count == 1)
        #expect(shown.title == "Awake · 15 min left")
        #expect(shown.expiresAfter == nil)
        #expect(shown.actions.map(\.id) == ["stop", "dismiss"])
        #expect(rig.module.session?.title == "Awake · 15 min left")
        #expect(rig.module.session?.deadline == rig.clock.now + 900)
    }

    @Test func anHourAndAnIndefiniteSessionShowTheirOwnLabels() throws {
        let rig = rig()
        #expect(rig.module.start(.oneHour))
        #expect(rig.running.first?.title == "Awake · 1 h left")

        #expect(rig.module.start(.indefinite))
        #expect(rig.running.first?.title == "Awake · ∞")
        #expect(rig.module.session?.deadline == nil)
        #expect(rig.scheduler.jobs.isEmpty, "an indefinite session has nothing to count down")
        #expect(rig.port.held == 1)
    }

    @Test func startingAgainReplacesTheSessionWithoutEverHoldingTwoAssertions() throws {
        let rig = rig()
        #expect(rig.module.start(.fifteenMinutes))
        #expect(rig.module.start(.oneHour))
        #expect(rig.module.start(.indefinite))
        #expect(rig.module.start(.fifteenMinutes))

        #expect(rig.port.held == 1)
        #expect(rig.port.peakHeld == 1, "the old assertion is released before the new one is taken")
        #expect(rig.port.requestedNames.count == 4)
        #expect(rig.running.map(\.title) == ["Awake · 15 min left"])
        #expect(rig.scheduler.jobs.count == 1, "the replaced session's tick is gone")
    }

    @Test func stopReleasesTheAssertionAndRemovesTheActivity() throws {
        let rig = rig()
        #expect(rig.module.start(.oneHour))
        #expect(rig.module.stop())

        #expect(rig.port.held == 0)
        #expect(rig.activities.isEmpty, "a user stop leaves no notice behind")
        #expect(rig.scheduler.jobs.isEmpty)
        #expect(rig.module.session == nil)
        #expect(rig.retained == 0)
        #expect(!rig.module.stop(), "stopping with nothing running is refused")
    }

    @Test func stopAndDismissFromTheNotchBothEndTheSession() throws {
        for actionID in ["stop", "dismiss"] {
            let rig = rig()
            #expect(rig.module.start(.indefinite))
            let shown = try #require(rig.running.first)

            #expect(rig.host.perform(actionID: actionID, stackID: shown.stackID, moduleID: "caffeine"))
            #expect(rig.port.held == 0, "\(actionID) releases the assertion")
            #expect(rig.activities.isEmpty)
            #expect(rig.module.session == nil)
        }
    }

    @Test func theLabelFollowsTheClockOneMinuteAtATime() throws {
        let rig = rig()
        let start = rig.clock.now
        #expect(rig.module.start(.oneHour))
        #expect(rig.scheduler.jobs == [start + 60], "the label next changes when 59 minutes are left")

        rig.advance(61)
        #expect(rig.running.first?.title == "Awake · 59 min left")

        rig.clock.now += 1200
        #expect(rig.running.first?.title == "Awake · 59 min left", "no tick fired yet")
        rig.scheduler.runDue(rig.clock.now)
        #expect(rig.running.first?.title == "Awake · 39 min left", "one late tick reads the clock, not a tick count")
        #expect(rig.scheduler.jobs == [start + 1320])
    }

    @Test func aTimedSessionEndsAtItsExactDeadlineWithAnExpiringNotice() throws {
        let rig = rig()
        let deadline = rig.clock.now + 900
        #expect(rig.module.start(.fifteenMinutes))

        rig.advance(899.999)
        #expect(rig.port.held == 1, "still awake a millisecond before the deadline")
        #expect(rig.running.first?.title == "Awake · 1 min left")
        #expect(rig.scheduler.jobs == [deadline], "the last job is due exactly at the deadline")

        rig.advance(0.001)
        #expect(rig.port.held == 0)
        #expect(rig.running.isEmpty)
        #expect(rig.module.session == nil)
        #expect(rig.scheduler.jobs.isEmpty)
        #expect(rig.retained == 0)
        let notice = try #require(rig.activities.first { $0.kind == .completion })
        #expect(notice.title == "Caffeine off · Mac can sleep")
        #expect(notice.expiresAfter == CaffeineModule.completionNoticeSeconds)
        #expect(rig.activities.count == 1)
    }

    @Test func aLateTickEndsTheSessionOnceAndAnyCallSettlesAMissedDeadline() throws {
        let late = rig(), missed = rig()
        #expect(late.module.start(.fifteenMinutes))
        late.advance(3 * 3600)
        #expect(late.port.held == 0)
        #expect(late.activities.filter { $0.kind == .completion }.count == 1)

        #expect(missed.module.start(.fifteenMinutes))
        missed.clock.now += 901
        #expect(!missed.module.stop(), "the deadline already ended it, so there is nothing to stop")
        #expect(missed.port.held == 0)
        #expect(missed.activities.map(\.kind) == [.completion])
    }

    @Test func aSessionPastItsDeadlineIsNotReportedAsRunningBeforeTheTickFires() {
        let rig = rig()
        #expect(rig.module.start(.fifteenMinutes))
        rig.clock.now += 900

        #expect(rig.module.session == nil, "the deadline passed, so Studio must not offer Stop for it")
    }

    @Test func startingAfterAMissedDeadlineLeavesOnlyTheNewSession() {
        let rig = rig()
        #expect(rig.module.start(.fifteenMinutes))
        rig.clock.now += 1000

        #expect(rig.module.start(.oneHour))
        #expect(rig.activities.map(\.kind) == [.activeTask])
        #expect(rig.running.first?.title == "Awake · 1 h left")
        #expect(rig.port.held == 1)
        #expect(rig.port.peakHeld == 1)
    }

    @Test func labelsRoundUpToWholeMinutesAndShowHours() {
        #expect(CaffeineModule.title(remaining: 24 * 3600) == "Awake · 24 h left")
        #expect(CaffeineModule.title(remaining: 3660) == "Awake · 1 h 1 min left")
        #expect(CaffeineModule.title(remaining: 3600.5) == "Awake · 1 h 1 min left")
        #expect(CaffeineModule.title(remaining: 3600) == "Awake · 1 h left")
        #expect(CaffeineModule.title(remaining: 60) == "Awake · 1 min left")
        #expect(CaffeineModule.title(remaining: 0.2) == "Awake · 1 min left")
        #expect(CaffeineModule.title(remaining: nil) == "Awake · ∞")
    }

    @Test func theLabelChangesExactlyOnTheMinute() {
        let rig = rig()
        #expect(rig.module.start(.oneHour))
        rig.advance(59.999)
        #expect(rig.running.first?.title == "Awake · 1 h left")
        rig.advance(0.001)
        #expect(rig.running.first?.title == "Awake · 59 min left")
    }

    @Test func startingANewSessionClearsTheEndedNotice() throws {
        let rig = rig()
        #expect(rig.module.start(.fifteenMinutes))
        rig.advance(900)
        #expect(rig.activities.map(\.kind) == [.completion])

        #expect(rig.module.start(.indefinite))
        #expect(rig.activities.map(\.kind) == [.activeTask])
    }

    @Test func aRefusedAssertionIsReportedAsAFailureAndNothingIsHeld() throws {
        let rig = rig()
        rig.port.refuse(true)

        #expect(!rig.module.start(.oneHour))
        #expect(rig.port.held == 0)
        #expect(rig.module.session == nil)
        #expect(rig.running.isEmpty)
        #expect(rig.retained == 0)
        #expect(rig.scheduler.jobs.isEmpty)
        #expect(rig.host.health(of: "caffeine") == .degraded, "the failure reached the host through the context")
    }

    @Test func aRefusedReplacementLeavesNeitherTheOldNorANewAssertion() throws {
        let rig = rig()
        #expect(rig.module.start(.indefinite))
        rig.port.refuse(true)

        #expect(!rig.module.start(.fifteenMinutes))
        #expect(rig.port.held == 0, "the old session was released before asking for the new one")
        #expect(rig.activities.isEmpty, "no stale Awake label stays behind")
        #expect(rig.module.session == nil)
        #expect(rig.host.health(of: "caffeine") == .degraded)
    }

    @Test func invalidDurationsAreRefusedWithoutTouchingThePort() {
        let rig = rig()
        for seconds in [0, -1, .infinity, .nan, CaffeineModule.maxTimedSeconds + 1] as [TimeInterval] {
            #expect(!rig.module.start(.timed(seconds)), "\(seconds) s")
        }
        #expect(rig.port.requestedNames.isEmpty)
        #expect(rig.activities.isEmpty)
        #expect(rig.host.health(of: "caffeine") == .ready, "bad input is not a module failure")
    }

    @Test func disablingTheModuleReleasesTheAssertionAndRefusesNewSessions() {
        let rig = rig()
        #expect(rig.module.start(.oneHour))

        rig.host.disable("caffeine")
        #expect(rig.port.held == 0)
        #expect(rig.retained == 0)
        #expect(rig.scheduler.jobs.isEmpty)
        #expect(rig.activities.isEmpty)
        #expect(!rig.module.start(.indefinite), "a disabled module takes no assertion")
        #expect(rig.port.held == 0)
        #expect(rig.module.session == nil)
    }

    @Test func quarantineReleasesTheAssertion() throws {
        let rig = rig()
        #expect(rig.module.start(.indefinite))
        let context = try #require(rig.captured.contexts.last)

        for _ in 0..<3 { context.reportFailure() }
        #expect(rig.host.health(of: "caffeine") == .quarantined)
        #expect(rig.port.held == 0)
        #expect(rig.retained == 0)
        #expect(rig.activities.isEmpty)
    }

    @Test func passesTheModuleAcceptanceContract() {
        let module = CaffeineModule(port: FakePowerPort(), scheduler: FakeScheduler())
        #expect(SaysoModuleAcceptance.violations(for: module) == [])
    }
}
