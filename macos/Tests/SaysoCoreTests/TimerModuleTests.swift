import Foundation
import Testing
@testable import SaysoCore

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
    }
}

private final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000_000) }

private final class PingSink: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [TimerPing] = []
    var pings: [TimerPing] { lock.withLock { received } }
    func add(_ ping: TimerPing) { lock.withLock { received.append(ping) } }
}

private struct Rig {
    let host: SaysoModuleHost
    let module: TimerModule
    let scheduler: FakeScheduler
    let clock: Clock
    let sink: PingSink

    func advance(_ seconds: TimeInterval) {
        clock.now += seconds
        scheduler.runDue(clock.now)
    }

    var activities: [SaysoActivity] { host.engine.stack.filter { $0.moduleID == "timer" } }
    var running: [SaysoActivity] { activities.filter { $0.kind == .activeTask } }
}

private func rig(maxTimers: Int = TimerModule.defaultMaxTimers) -> Rig {
    let scheduler = FakeScheduler(), clock = Clock(), sink = PingSink(), bus = SaysoEventBus()
    _ = bus.subscribe(TimerPing.self) { sink.add($0) }
    let module = TimerModule(scheduler: scheduler, now: { clock.now }, maxTimers: maxTimers)
    let host = SaysoModuleHost(modules: [module], now: { clock.now }, events: bus)
    host.enable("timer")
    return Rig(host: host, module: module, scheduler: scheduler, clock: clock, sink: sink)
}

@Suite struct TimerModuleTests {
    @Test func aCountdownPublishesItsProgressAndTimeLabelAsAnActiveTask() throws {
        let rig = rig()
        let id = try #require(rig.module.startCountdown(1500))

        let started = try #require(rig.running.first)
        #expect(started.title == "Timer 25:00")
        #expect(started.progress == 0)
        #expect(started.expiresAfter == nil)

        rig.advance(61.5)
        let ticking = try #require(rig.running.first)
        #expect(ticking.title == "Timer 23:59")
        #expect(abs((ticking.progress ?? -1) - 61.5 / 1500) < 0.000_1)
        let snapshot = try #require(rig.module.timers.first { $0.id == id })
        #expect(snapshot.elapsed == 61.5)
        #expect(snapshot.remaining == 1438.5)
    }

    @Test func elapsedAndRemainingComeFromTheClockNotFromHowManyTicksFired() throws {
        let rig = rig()
        let id = try #require(rig.module.startCountdown(600))

        rig.clock.now += 300
        #expect(rig.module.timers.first { $0.id == id }?.remaining == 300, "no tick fired, the clock alone decides")

        rig.scheduler.runDue(rig.clock.now)
        #expect(rig.running.first?.title == "Timer 5:00", "one late tick catches the label up")
        #expect(rig.scheduler.jobs.count == 1, "exactly one tick stays armed")
        #expect(rig.scheduler.jobs.allSatisfy { $0 > rig.clock.now && $0 <= rig.clock.now + 1 })
    }

    @Test func pauseFreezesTheTimerAndStopsTickingAndResumeCarriesOn() throws {
        let rig = rig()
        let id = try #require(rig.module.startCountdown(600))
        rig.advance(100)

        #expect(rig.module.pause(id))
        #expect(rig.scheduler.jobs.isEmpty, "a paused timer needs no tick")
        rig.advance(1000)
        let paused = try #require(rig.module.timers.first { $0.id == id })
        #expect(paused.isPaused)
        #expect(paused.remaining == 500)
        let pausedActivity = try #require(rig.running.first)
        #expect(pausedActivity.title == "Timer 8:20 (paused)")
        #expect(pausedActivity.actions.map(\.id) == ["resume", "cancel"])
        #expect(!rig.module.pause(id), "pausing twice is refused")

        #expect(rig.host.perform(actionID: "resume", stackID: pausedActivity.stackID, moduleID: "timer"))
        rig.advance(50)
        #expect(rig.module.timers.first { $0.id == id }?.remaining == 450)
        #expect(rig.running.first?.title == "Timer 7:30")
        #expect(rig.running.first?.actions.map(\.id) == ["pause", "cancel"])
        #expect(!rig.module.resume(id), "resuming a running timer is refused")
    }

    @Test func cancelRemovesTheTimerItsActivityAndItsTickWithoutAPing() throws {
        let rig = rig()
        let id = try #require(rig.module.startCountdown(600))
        rig.advance(10)

        #expect(rig.module.cancel(id))
        #expect(rig.module.timers.isEmpty)
        #expect(rig.activities.isEmpty)
        #expect(rig.scheduler.jobs.isEmpty)
        #expect(rig.sink.pings.isEmpty)
        #expect(!rig.module.cancel(id), "cancelling twice is refused")
    }

    @Test func aCountdownNeedsAPositiveDuration() {
        let rig = rig()
        #expect(rig.module.startCountdown(0) == nil)
        #expect(rig.module.startCountdown(-5) == nil)
        #expect(rig.module.startCountdown(.nan) == nil)
        #expect(rig.module.timers.isEmpty)
    }

    @Test func timeLabelsUseMinutesAndSecondsAndAddHoursOnlyWhenNeeded() {
        #expect(TimerModule.clockLabel(0) == "0:00")
        #expect(TimerModule.clockLabel(59.2) == "0:59")
        #expect(TimerModule.clockLabel(300) == "5:00")
        #expect(TimerModule.clockLabel(3599) == "59:59")
        #expect(TimerModule.clockLabel(3600) == "1:00:00")
        #expect(TimerModule.clockLabel(-3) == "0:00")
    }
}
