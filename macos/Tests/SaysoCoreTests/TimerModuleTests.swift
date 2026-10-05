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

    @Test func finishingPublishesAnExpiringCompletionThatOutranksAmbientAndPingsOnce() throws {
        let rig = rig()
        let id = try #require(rig.module.startCountdown(60))
        rig.advance(30)
        rig.advance(30)

        #expect(rig.module.timers.isEmpty)
        #expect(rig.running.isEmpty)
        let done = try #require(rig.activities.first)
        #expect(done.kind == .completion)
        #expect(done.kind > .ambient)
        #expect(done.title == "Timer done · 1:00")
        #expect(done.expiresAfter == TimerModule.completionNoticeSeconds)
        #expect(rig.sink.pings == [TimerPing(timerID: id, reason: .finished)])
        #expect(rig.scheduler.jobs.isEmpty, "nothing left to tick")

        rig.clock.now += TimerModule.completionNoticeSeconds
        rig.host.tick()
        #expect(rig.activities.isEmpty, "the completion notice expires")
    }

    @Test func aTickThatFiresLongAfterTheDeadlineFinishesTheTimerOnce() throws {
        let rig = rig()
        let id = try #require(rig.module.startCountdown(60))

        rig.advance(500)

        #expect(rig.module.timers.isEmpty)
        #expect(rig.sink.pings == [TimerPing(timerID: id, reason: .finished)])
        #expect(rig.activities.map(\.kind) == [.completion])
    }

    @Test func aCompletionIsShownAheadOfAnotherRunningTimer() throws {
        let rig = rig()
        try #require(rig.module.startCountdown(600) != nil)
        try #require(rig.module.startCountdown(60) != nil)

        rig.advance(60)

        #expect(rig.host.engine.primary?.kind == .completion)
        #expect(rig.running.map(\.title) == ["Timer 9:00"])
    }

    @Test func aPomodoroMovesFromFocusToBreakToFocusWithALongBreakAfterEveryFourthFocus() throws {
        let rig = rig()
        let id = try #require(rig.module.startPomodoro())
        #expect(rig.running.map(\.title) == ["Focus 25:00"])
        #expect(rig.running.first?.progress == 0)

        let steps: [(after: TimeInterval, phase: TimerPhase, title: String, notice: String)] = [
            (1500, .shortBreak, "Short break 5:00", "Focus done · Short break"),
            (300, .focus, "Focus 25:00", "Short break done · Focus"),
            (1500, .shortBreak, "Short break 5:00", "Focus done · Short break"),
            (300, .focus, "Focus 25:00", "Short break done · Focus"),
            (1500, .shortBreak, "Short break 5:00", "Focus done · Short break"),
            (300, .focus, "Focus 25:00", "Short break done · Focus"),
            (1500, .longBreak, "Long break 15:00", "Focus done · Long break"),
            (900, .focus, "Focus 25:00", "Long break done · Focus"),
        ]
        for (index, step) in steps.enumerated() {
            rig.advance(step.after)
            #expect(rig.running.map(\.title) == [step.title], "step \(index)")
            let notice = rig.activities.first { $0.kind == .completion }
            #expect(notice?.title == step.notice, "step \(index)")
            #expect(notice?.expiresAfter == TimerModule.completionNoticeSeconds, "step \(index)")
            #expect(rig.sink.pings.count == index + 1, "one ping per transition, step \(index)")
            #expect(rig.sink.pings.last == TimerPing(timerID: id, reason: .phaseStarted(step.phase)), "step \(index)")
        }
        #expect(rig.module.timers.first?.kind == .pomodoro(phase: .focus, completedFocusSessions: 4))
    }

    @Test func onlyOnePomodoroRunsAtATimeButCountdownsCanRunBesideIt() throws {
        let rig = rig()
        try #require(rig.module.startPomodoro() != nil)
        #expect(rig.module.startPomodoro() == nil)
        #expect(rig.module.startCountdown(60) != nil)
        #expect(rig.module.timers.count == 2)
    }

    @Test func startingAPomodoroAfterCancellingOneStartsCleanAtFocus() throws {
        let rig = rig()
        let first = try #require(rig.module.startPomodoro())
        rig.advance(1500)
        #expect(rig.module.cancel(first))
        #expect(rig.activities.isEmpty, "cancel clears the phase and its transition notice")
        #expect(rig.scheduler.jobs.isEmpty)

        let second = try #require(rig.module.startPomodoro())
        #expect(second != first)
        #expect(rig.module.timers.map(\.kind) == [.pomodoro(phase: .focus, completedFocusSessions: 0)])
        #expect(rig.running.map(\.title) == ["Focus 25:00"])
        #expect(rig.scheduler.jobs.count == 1)
        #expect(rig.sink.pings.count == 1, "cancel and restart do not ping")
    }

    @Test func aLateTickCatchesUpMissedPhasesFromTheClockAndPingsOnlyForTheCurrentOne() throws {
        let rig = rig()
        let id = try #require(rig.module.startPomodoro())

        rig.advance(1500 + 300 + 10)

        #expect(rig.running.map(\.title) == ["Focus 24:50"])
        #expect(rig.module.timers.first?.kind == .pomodoro(phase: .focus, completedFocusSessions: 1))
        #expect(rig.sink.pings == [TimerPing(timerID: id, reason: .phaseStarted(.focus))], "no burst of pings after a sleep")
    }

    @Test func aPausedPomodoroKeepsItsPhaseAndTimeLeft() throws {
        let rig = rig()
        let id = try #require(rig.module.startPomodoro())
        rig.advance(50)
        #expect(rig.module.pause(id))
        rig.advance(5000)
        #expect(rig.running.map(\.title) == ["Focus 24:10 (paused)"])
        #expect(rig.sink.pings.isEmpty)
    }

    @Test func aStopwatchCountsUpAndRecordsLapsOnlyWhileRunning() throws {
        let rig = rig()
        let id = try #require(rig.module.startStopwatch())
        #expect(rig.running.map(\.title) == ["Stopwatch 0:00"])
        #expect(rig.running.first?.progress == nil, "a stopwatch has no end, so no progress")

        rig.advance(12.5)
        #expect(rig.running.map(\.title) == ["Stopwatch 0:12"])
        #expect(rig.module.lap(id) == 12.5)
        rig.advance(7.5)
        #expect(rig.module.lap(id) == 7.5)
        #expect(rig.running.map(\.title) == ["Stopwatch 0:20"])
        let snapshot = try #require(rig.module.timers.first)
        #expect(snapshot.kind == .stopwatch)
        #expect(snapshot.laps == [12.5, 7.5])
        #expect(snapshot.elapsed == 20)
        #expect(snapshot.remaining == nil)

        #expect(rig.module.pause(id))
        #expect(rig.module.lap(id) == nil, "no lap while paused")
        #expect(rig.scheduler.jobs.isEmpty)
        rig.advance(3600)
        #expect(rig.module.timers.first?.elapsed == 20)
        #expect(rig.sink.pings.isEmpty, "a stopwatch never finishes on its own")
    }

    @Test func aStopwatchKeepsABoundedNumberOfLaps() throws {
        let rig = rig()
        let id = try #require(rig.module.startStopwatch())
        for _ in 0..<TimerModule.maxLaps {
            rig.advance(1)
            #expect(rig.module.lap(id) == 1)
        }
        rig.advance(1)
        #expect(rig.module.lap(id) == nil)
        #expect(rig.module.timers.first?.laps.count == TimerModule.maxLaps)
    }

    @Test func timersAndStopwatchesShareACapThatThePomodoroDoesNotCountAgainst() throws {
        let rig = rig(maxTimers: 2)
        let first = try #require(rig.module.startCountdown(60))
        try #require(rig.module.startStopwatch() != nil)

        #expect(rig.module.startCountdown(60) == nil)
        #expect(rig.module.startStopwatch() == nil)
        #expect(rig.module.startPomodoro() != nil)

        #expect(rig.module.cancel(first))
        #expect(rig.module.startCountdown(60) != nil, "cancelling frees a slot")
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
