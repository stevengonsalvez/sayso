import Foundation
import Testing
@testable import SaysoCore

private final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 5_000) }

private final class FakeScheduler: SaysoScheduling, @unchecked Sendable {
    struct Job { let id: Int; let at: Date; let action: @Sendable () -> Void }
    var jobs: [Job] = []
    var nextID = 0
    var cancelled = 0
    func schedule(at date: Date, _ action: @escaping @Sendable () -> Void) -> SaysoSubscription {
        nextID += 1
        let id = nextID
        jobs.append(Job(id: id, at: date, action: action))
        return SaysoSubscription { [weak self] in
            self?.jobs.removeAll { $0.id == id }
            self?.cancelled += 1
        }
    }
    func fire(_ index: Int = 0) {
        let job = jobs.remove(at: index)
        job.action()
    }
}

private final class Slot: @unchecked Sendable { var context: SaysoModuleContext? }
private final class Quiet: SaysoModuleRuntime, @unchecked Sendable {
    func start() {}
    func stop() {}
}
private struct Alerter: SaysoModule {
    let slot: Slot
    let descriptor = SaysoModuleDescriptor(id: "alerts", title: "Alerts")
    func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime { slot.context = context; return Quiet() }
}

private func setup() -> (SaysoModuleHost, SaysoExpiryTicker, FakeScheduler, Clock, Slot) {
    let clock = Clock(), scheduler = FakeScheduler(), slot = Slot()
    let host = SaysoModuleHost(modules: [Alerter(slot: slot)], now: { clock.now })
    let ticker = SaysoExpiryTicker(host: host, scheduler: scheduler)
    host.enable("alerts")
    return (host, ticker, scheduler, clock, slot)
}

@Test func engineReportsTheEarliestPendingExpiry() {
    let t0 = Date(timeIntervalSince1970: 100)
    var engine = SaysoActivityEngine()
    #expect(engine.nextExpiry == nil)
    engine.publish(SaysoActivity(moduleID: "a", stackID: "p", kind: .activeTask, title: "persistent"), at: t0)
    #expect(engine.nextExpiry == nil)
    engine.publish(SaysoActivity(moduleID: "a", stackID: "x", kind: .completion, title: "x", expiresAfter: 30), at: t0)
    engine.publish(SaysoActivity(moduleID: "a", stackID: "y", kind: .completion, title: "y", expiresAfter: 10), at: t0)
    #expect(engine.nextExpiry == t0.addingTimeInterval(10))
}

@Test func tickerSchedulesNothingWithoutExpiringActivitiesAndOneJobWhenThereAre() {
    let (_, ticker, scheduler, clock, slot) = setup()
    _ = ticker
    #expect(scheduler.jobs.isEmpty)

    slot.context?.publish(stackID: "p", kind: .activeTask, title: "persistent")
    #expect(scheduler.jobs.isEmpty)

    slot.context?.publish(stackID: "a", kind: .completion, title: "Copied", expiresAfter: 5)
    #expect(scheduler.jobs.map(\.at) == [clock.now.addingTimeInterval(5)])

    slot.context?.publish(stackID: "b", kind: .completion, title: "Saved", expiresAfter: 2)
    #expect(scheduler.jobs.map(\.at) == [clock.now.addingTimeInterval(2)])
}

@Test func firingTheJobExpiresAlertsAndReschedulesForTheNextOne() {
    let (host, ticker, scheduler, clock, slot) = setup()
    _ = ticker
    slot.context?.publish(stackID: "a", kind: .completion, title: "A", expiresAfter: 2)
    slot.context?.publish(stackID: "b", kind: .completion, title: "B", expiresAfter: 8)

    clock.now += 2
    scheduler.fire()
    #expect(host.engine.stack.map(\.title) == ["B"])
    #expect(scheduler.jobs.map(\.at) == [clock.now.addingTimeInterval(6)])

    clock.now += 6
    scheduler.fire()
    #expect(host.engine.stack.isEmpty)
    #expect(scheduler.jobs.isEmpty)
}

@Test func disablingTheModuleCancelsItsPendingJob() {
    let (host, ticker, scheduler, _, slot) = setup()
    _ = ticker
    slot.context?.publish(stackID: "a", kind: .completion, title: "A", expiresAfter: 5)
    #expect(scheduler.jobs.count == 1)

    host.disable("alerts")
    #expect(scheduler.jobs.isEmpty)
}

@Test func tickerKeepsAnObserverInstalledBeforeIt() {
    final class Count: @unchecked Sendable { var value = 0 }
    let clock = Clock(), scheduler = FakeScheduler(), slot = Slot(), count = Count()
    let host = SaysoModuleHost(modules: [Alerter(slot: slot)], now: { clock.now })
    host.onActivitiesChanged = { count.value += 1 }
    let ticker = SaysoExpiryTicker(host: host, scheduler: scheduler)
    _ = ticker
    host.enable("alerts")

    slot.context?.publish(stackID: "a", kind: .completion, title: "A", expiresAfter: 5)
    #expect(count.value == 1)
    #expect(scheduler.jobs.count == 1)
}
