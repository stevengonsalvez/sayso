import Foundation
import Testing
@testable import SaysoCore

private final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000_000) }

/// A battery at 92% of its design capacity, cool, plugged in and charging.
private let healthy = MacBatteryReading(
    designCapacity: 5_000, maxCapacity: 4_600, cycleCount: 123, temperatureCelsius: 30.04,
    isCharging: true, isExternalPowerConnected: true, minutesRemaining: 45
)

private extension MacBatteryReading {
    func with(_ change: (inout MacBatteryReading) -> Void) -> MacBatteryReading {
        var copy = self
        change(&copy)
        return copy
    }

    /// Max capacity for a given whole percent of a 5,000 mAh design.
    func health(_ percent: Int) -> MacBatteryReading { with { $0.maxCapacity = percent * 50 } }
    func temperature(_ celsius: Double?) -> MacBatteryReading { with { $0.temperatureCelsius = celsius } }
}

private let keyboard = DeviceBattery(id: "20-91-df-e7-52-3d", name: "Magic Keyboard", percent: 74)

/// Stands in for IOKit: returns whatever reading the test set, counting reads.
private final class FakeBattery: BatteryHealthPort, @unchecked Sendable {
    private let lock = NSLock()
    private var reading: BatteryHealthReading
    private var error: BatteryHealthPortError?
    private var readCount = 0

    init(_ battery: MacBatteryReading?, devices: [DeviceBattery] = []) {
        reading = BatteryHealthReading(battery: battery, devices: devices)
    }

    var reads: Int { lock.withLock { readCount } }

    func set(_ battery: MacBatteryReading?, devices: [DeviceBattery] = []) {
        lock.withLock { reading = BatteryHealthReading(battery: battery, devices: devices) }
    }

    func fail(_ error: BatteryHealthPortError?) { lock.withLock { self.error = error } }

    func read() throws(BatteryHealthPortError) -> BatteryHealthReading {
        lock.lock()
        defer { lock.unlock() }
        readCount += 1
        if let error { throw error }
        return reading
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
    let inner: BatteryHealthModule
    let captured: Captured
    var descriptor: SaysoModuleDescriptor { inner.descriptor }
    func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        let runtime = inner.makeRuntime(context: context)
        captured.runtimes.append(runtime)
        return runtime
    }
}

/// Every change to the notch, as this module's line titles.
private final class Painted: @unchecked Sendable {
    var changes: [[String]] = []
}

/// Another module that publishes whatever a test asks, to check how the battery lines rank against it.
private final class Neighbour: SaysoModule, SaysoModuleRuntime, @unchecked Sendable {
    let descriptor = SaysoModuleDescriptor(id: "neighbour", title: "Neighbour")
    var context: SaysoModuleContext?
    func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        self.context = context
        return self
    }
    func start() {}
    func stop() {}
    func publish(_ kind: SaysoActivityKind, _ title: String) {
        context?.publish(stackID: title, kind: kind, title: title)
    }
}

/// What the module reports through a bare context, so "reported once" can be counted exactly.
private final class Reports: @unchecked Sendable {
    var failures = 0
    var log: [String] = []
    var tapDuringNextPublish = false
}

private final class RuntimeBox: @unchecked Sendable {
    var runtime: SaysoModuleRuntime?
}

private struct Rig {
    let host: SaysoModuleHost
    let module: BatteryHealthModule
    let battery: FakeBattery
    let scheduler: FakeScheduler
    let clock: Clock
    let captured: Captured
    let painted: Painted
    let neighbour: Neighbour

    var lines: [SaysoActivity] { host.engine.stack.filter { $0.moduleID == "battery-health" } }
    var titles: [String] { lines.map(\.title).sorted() }

    @discardableResult
    func tap(_ actionID: String, on stackID: String) -> Bool {
        host.perform(actionID: actionID, stackID: stackID, moduleID: "battery-health")
    }

    /// Sets the battery and lets the next sample run.
    func sample(_ reading: MacBatteryReading?) {
        battery.set(reading)
        advance(nextSampleIn)
    }

    /// Seconds until the one pending job.
    var nextSampleIn: TimeInterval { (scheduler.jobs.first ?? clock.now).timeIntervalSince(clock.now) }

    func advance(_ seconds: TimeInterval) {
        clock.now += seconds
        scheduler.runDue(clock.now)
    }

    var retained: Int { (captured.runtimes.last as? SaysoResourceAccounting)?.retainedResources ?? -1 }
}

/// Enables the module next to a neighbour module and lets the first sample run.
private func rig(_ reading: MacBatteryReading? = healthy, devices: [DeviceBattery] = []) -> Rig {
    let clock = Clock(), scheduler = FakeScheduler(), captured = Captured(), painted = Painted()
    let battery = FakeBattery(reading, devices: devices)
    let module = BatteryHealthModule(port: battery, scheduler: scheduler, now: { clock.now })
    let neighbour = Neighbour()
    let host = SaysoModuleHost(modules: [Probe(inner: module, captured: captured), neighbour], now: { clock.now })
    host.onActivitiesChanged = { [weak host] in
        painted.changes.append(host?.engine.stack.filter { $0.moduleID == "battery-health" }.map(\.title) ?? [])
    }
    host.enable("neighbour")
    host.enable("battery-health")
    let rig = Rig(
        host: host, module: module, battery: battery, scheduler: scheduler, clock: clock, captured: captured,
        painted: painted, neighbour: neighbour
    )
    rig.advance(0)
    return rig
}

private let wornStack = BatteryHealthModule.wornStackID
private let hotStack = BatteryHealthModule.hotStackID

@Suite struct BatteryHealthModuleTests {
    // MARK: Health

    @Test func healthIsMaxOverDesignCapacityAsAWholePercentWithItsLabel() {
        func text(_ max: Int?, _ design: Int?) -> String {
            BatteryHealthSnapshot(
                battery: healthy.with { $0.maxCapacity = max; $0.designCapacity = design }, devices: [], sampledAt: .distantPast
            ).healthText
        }
        #expect(text(4_600, 5_000) == "92% · Normal")
        #expect(text(4_000, 5_000) == "80% · Normal", "80 is the lowest normal")
        #expect(text(3_975, 5_000) == "80% · Normal", "79.5 shows as 80, and the label follows the number shown")
        #expect(text(3_950, 5_000) == "79% · Service soon")
        #expect(text(3_000, 5_000) == "60% · Service soon", "60 is the lowest service soon")
        #expect(text(2_950, 5_000) == "59% · Replace soon")
        #expect(text(0, 5_000) == "Unknown", "a zero capacity is missing data, never 0%")
        #expect(text(6_830, 8_694) == "79% · Service soon")
    }

    @Test func healthIsClampedToZeroThroughOneHundred() {
        let fresh = BatteryHealthSnapshot(battery: healthy.with { $0.maxCapacity = 5_400 }, devices: [], sampledAt: .distantPast)
        #expect(fresh.healthPercent == 100, "a new battery can hold more than its design capacity")
        #expect(fresh.condition == .normal)
        let negative = BatteryHealthSnapshot(battery: healthy.with { $0.maxCapacity = -10 }, devices: [], sampledAt: .distantPast)
        #expect(negative.healthPercent == nil, "a negative capacity is not a reading")
    }

    @Test func missingOrZeroCapacitiesAreUnknownAndNeverDivideByZero() {
        for (max, design) in [(nil, 5_000), (4_000, nil), (nil, nil), (4_000, 0), (0, 5_000), (0, 0), (4_000, -1)] as [(Int?, Int?)] {
            let snapshot = BatteryHealthSnapshot(
                battery: healthy.with { $0.maxCapacity = max; $0.designCapacity = design }, devices: [], sampledAt: .distantPast
            )
            #expect(snapshot.healthPercent == nil, "\(String(describing: max)) / \(String(describing: design))")
            #expect(snapshot.condition == .unknown)
            #expect(snapshot.healthText == "Unknown")
            #expect(!snapshot.healthText.contains("0%"))
        }
    }

    @Test func conditionsReadNormalServiceSoonReplaceSoonAndUnknown() {
        #expect(BatteryCondition.normal.text == "Normal")
        #expect(BatteryCondition.serviceSoon.text == "Service soon")
        #expect(BatteryCondition.replaceSoon.text == "Replace soon")
        #expect(BatteryCondition.unknown.text == "Unknown")
    }

    // MARK: Cycles, temperature, power

    @Test func cycleCountHasThousandsSeparatorsInEveryLocale() {
        func cycles(_ count: Int?) -> String {
            BatteryHealthSnapshot(battery: healthy.with { $0.cycleCount = count }, devices: [], sampledAt: .distantPast).cyclesText
        }
        #expect(cycles(0) == "0")
        #expect(cycles(721) == "721")
        #expect(cycles(1_234) == "1,234")
        #expect(cycles(1_234_567) == "1,234,567")
        #expect(cycles(nil) == "Unknown")
        #expect(cycles(-1) == "Unknown", "a negative count is not a reading")
    }

    @Test func temperatureIsCelsiusToOneDecimal() {
        func temperature(_ celsius: Double?) -> String {
            BatteryHealthSnapshot(battery: healthy.temperature(celsius), devices: [], sampledAt: .distantPast).temperatureText
        }
        #expect(temperature(30.04) == "30.0 °C")
        #expect(temperature(31.66) == "31.7 °C")
        #expect(temperature(-5.26) == "-5.3 °C")
        #expect(temperature(nil) == "Unknown")
        #expect(temperature(.nan) == "Unknown")
        #expect(temperature(.infinity) == "Unknown")
        #expect(temperature(-273.15) == "Unknown", "a raw zero, which no working battery reads")
        #expect(temperature(500) == "Unknown")
    }

    @Test func powerSaysChargingPluggedInOrOnBatteryWithTheTimeWhenKnown() {
        func power(_ change: (inout MacBatteryReading) -> Void) -> String {
            BatteryHealthSnapshot(battery: healthy.with(change), devices: [], sampledAt: .distantPast).powerText
        }
        #expect(power { _ in } == "Charging · 45 min to full")
        #expect(power { $0.minutesRemaining = nil } == "Charging")
        #expect(power { $0.isCharging = false } == "Plugged in, not charging")
        #expect(power { $0.isCharging = false; $0.isExternalPowerConnected = false; $0.minutesRemaining = 200 } == "On battery · 3 h 20 min left")
        #expect(power { $0.isCharging = false; $0.isExternalPowerConnected = false; $0.minutesRemaining = 120 } == "On battery · 2 h left")
        #expect(power { $0.isCharging = false; $0.isExternalPowerConnected = false; $0.minutesRemaining = 0 } == "On battery", "no estimate yet")
        #expect(power { $0.isCharging = nil; $0.isExternalPowerConnected = nil } == "Unknown")
    }

    @Test func aMacWithNoBatteryReadsNoBatteryInEveryRowAndListsItsDevices() {
        let snapshot = BatteryHealthSnapshot(battery: nil, devices: [keyboard], sampledAt: .distantPast)
        #expect(snapshot.healthText == "No battery")
        #expect(snapshot.cyclesText == "No battery")
        #expect(snapshot.temperatureText == "No battery")
        #expect(snapshot.powerText == "No battery")
        #expect(snapshot.condition == nil)
        #expect(snapshot.devices.map(\.text) == ["Magic Keyboard 74%"])
    }

    @Test func deviceTextsAreClampedAndNamedEvenWhenBlank() {
        #expect(DeviceBattery(id: "a", name: "Mouse", percent: 140).text == "Mouse 100%")
        #expect(DeviceBattery(id: "a", name: "  ", percent: -3).text == "Bluetooth device 0%")
    }

    // MARK: Lines

    @Test func theFirstSampleIsAScheduledJobSoEnablingNeverReadsInline() {
        let clock = Clock(), scheduler = FakeScheduler(), battery = FakeBattery(healthy.health(50))
        let module = BatteryHealthModule(port: battery, scheduler: scheduler, now: { clock.now })
        let host = SaysoModuleHost(modules: [module], now: { clock.now })
        host.enable("battery-health")
        #expect(battery.reads == 0)
        #expect(module.snapshot == nil)
        #expect(scheduler.jobs == [clock.now])
    }

    @Test func aHealthyBatteryShowsNoLine() throws {
        let rig = rig(healthy, devices: [keyboard])
        for _ in 0..<5 { rig.advance(BatteryHealthModule.idleIntervalSeconds) }
        #expect(rig.battery.reads == 6)
        #expect(rig.lines.isEmpty)
        let neverPainted = rig.painted.changes.allSatisfy(\.isEmpty)
        #expect(neverPainted, "never painted a battery line")
        let snapshot = try #require(rig.module.snapshot)
        #expect(snapshot.healthText == "92% · Normal")
        #expect(snapshot.devices == [keyboard])
    }

    @Test func aMacWithNoBatteryNeverPublishesALine() throws {
        let rig = rig(nil)
        for _ in 0..<5 { rig.advance(BatteryHealthModule.idleIntervalSeconds) }
        let neverPainted = rig.painted.changes.allSatisfy(\.isEmpty)
        #expect(neverPainted, "never painted a battery line")
        #expect(try #require(rig.module.snapshot).healthText == "No battery")
    }

    @Test func healthBelowSixtyShowsOneWornLineThatIsNotRepublishedEverySample() throws {
        let rig = rig(healthy.health(55))
        let line = try #require(rig.lines.first)
        #expect(rig.lines.count == 1)
        #expect(line.stackID == wornStack)
        #expect(line.title == "Battery health 55% · Replace soon")
        #expect(line.kind == .ambient)
        #expect(line.expiresAfter == nil)
        #expect(line.actions.map(\.id) == ["dismiss"])
        let before = rig.painted.changes.count
        for _ in 0..<6 { rig.advance(BatteryHealthModule.idleIntervalSeconds) }
        #expect(rig.painted.changes.count == before, "same text, same line: no repaint")

        rig.sample(healthy.health(54))
        #expect(rig.titles == ["Battery health 54% · Replace soon"], "a new figure replaces the one line")
    }

    @Test func theWornLineNeverFlapsAroundSixty() {
        let rig = rig(healthy.health(59))
        #expect(rig.lines.count == 1)
        for percent in [60, 61, 59, 60, 61] {
            rig.sample(healthy.health(percent))
            #expect(rig.lines.count == 1, "\(percent)%: a wobble above 60 keeps the line")
        }
        rig.sample(healthy.health(BatteryHealthModule.wornRecoveredPercent))
        #expect(rig.lines.isEmpty, "clears only at \(BatteryHealthModule.wornRecoveredPercent)%")
        rig.sample(healthy.health(61))
        rig.sample(healthy.health(60))
        #expect(rig.lines.isEmpty, "and needs below 60 to return")
    }

    @Test func unknownHealthShowsNoLine() {
        let rig = rig(healthy.with { $0.maxCapacity = nil })
        #expect(rig.lines.isEmpty)
        #expect(rig.module.snapshot?.condition == .unknown)
    }

    @Test func aHotBatteryShowsALineFromFortyFiveAndClearsAtFortyTwo() throws {
        let rig = rig(healthy.temperature(44.9))
        #expect(rig.lines.isEmpty)
        rig.sample(healthy.temperature(45))
        let line = try #require(rig.lines.first)
        #expect(line.stackID == hotStack)
        #expect(line.title == "Battery is hot, over 45 °C")
        #expect(line.kind == .ambient)
        #expect(line.actions.map(\.id) == ["dismiss"])
        for celsius in [44.0, 46.5, 42.1, 44.9, 43.0] {
            rig.sample(healthy.temperature(celsius))
            #expect(rig.lines.count == 1, "\(celsius) °C: no flapping between 42 and 45")
        }
        let before = rig.painted.changes.count
        rig.sample(healthy.temperature(42.5))
        #expect(rig.painted.changes.count == before, "the title holds no moving figure, so a new reading repaints nothing")
        rig.sample(healthy.temperature(42))
        #expect(rig.lines.isEmpty)
        rig.sample(healthy.temperature(44.9))
        #expect(rig.lines.isEmpty, "needs 45 again to return")
    }

    @Test func anUnknownTemperatureCannotVouchForAHotLine() {
        let rig = rig(healthy.temperature(47))
        #expect(rig.lines.count == 1)
        rig.sample(healthy.temperature(nil))
        #expect(rig.lines.isEmpty)
    }

    @Test func wornAndHotAreTwoLinesAndDismissingOneKeepsTheOther() {
        let rig = rig(healthy.health(55).temperature(47))
        #expect(rig.titles == ["Battery health 55% · Replace soon", "Battery is hot, over 45 °C"])
        #expect(rig.tap("dismiss", on: hotStack))
        rig.advance(0)
        #expect(rig.titles == ["Battery health 55% · Replace soon"])
    }

    // MARK: Rank

    /// Ambient, like System stats lines: a battery that is worn or warm is worth a glance, not an interruption. Every
    /// higher rank (active task, completion, failure, confirmation) is drawn over it, so it can never hide a running
    /// timer, the privacy line, a notice or an approval; it ties with other ambient offers in publish order and
    /// Dismiss removes it. Above media and clocks, which published first cannot hide it.
    @Test func itRanksAboveMediaAndClocksAndBelowEveryHigherKind() {
        let clock = Clock(), scheduler = FakeScheduler(), captured = Captured()
        let battery = FakeBattery(healthy.health(55))
        let module = BatteryHealthModule(port: battery, scheduler: scheduler, now: { clock.now })
        let neighbour = Neighbour()
        let host = SaysoModuleHost(modules: [Probe(inner: module, captured: captured), neighbour], now: { clock.now })
        host.enable("neighbour")
        neighbour.publish(.media, "Song · Artist")
        neighbour.publish(.background, "Tokyo 09:00")
        host.enable("battery-health")
        scheduler.runDue(clock.now)
        #expect(host.engine.primary?.moduleID == "battery-health", "lower lines published first cannot hide it")

        for kind in [SaysoActivityKind.activeTask, .completion, .failure, .confirmation] {
            neighbour.publish(kind, "\(kind)")
            #expect(host.engine.primary?.title == "\(kind)", "\(kind) outranks the battery line")
            host.dismiss(moduleID: "neighbour", stackID: "\(kind)")
            #expect(host.engine.primary?.moduleID == "battery-health", "and the battery line returns after it")
        }
    }

    // MARK: Dismiss

    @Test func dismissHidesTheWornLineUntilHealthFallsFurther() {
        let rig = rig(healthy.health(55))
        #expect(rig.tap("dismiss", on: wornStack))
        #expect(rig.scheduler.jobs == [rig.clock.now], "the job applies the dismissal")
        let reads = rig.battery.reads
        rig.advance(0)
        #expect(rig.battery.reads == reads, "a repaint is not a sample")
        #expect(rig.lines.isEmpty)
        #expect(rig.module.snapshot?.healthText == "55% · Replace soon", "the row still says what is true")

        for percent in [55, 56, 55] { rig.sample(healthy.health(percent)) }
        #expect(rig.lines.isEmpty, "the same or a better figure stays hidden, so a one point wobble never brings it back")
        rig.sample(healthy.health(54))
        #expect(rig.titles == ["Battery health 54% · Replace soon"], "worse than when dismissed: it shows again")
    }

    @Test func dismissHidesTheHotLineUntilItClears() {
        let rig = rig(healthy.temperature(47))
        rig.tap("dismiss", on: hotStack)
        rig.advance(0)
        rig.sample(healthy.temperature(49))
        #expect(rig.lines.isEmpty, "still hot: stays hidden")
        rig.sample(healthy.temperature(41))
        rig.sample(healthy.temperature(46))
        #expect(rig.titles == ["Battery is hot, over 45 °C"], "cooled down, then hot again: it returns")
    }

    @Test func dismissWithNoLineShownChangesNothing() {
        let rig = rig(healthy)
        let jobs = rig.scheduler.jobs
        #expect(rig.tap("dismiss", on: wornStack) == false, "no line, no declared action")
        rig.captured.runtimes.last?.handle(stackID: wornStack, actionID: "dismiss")
        rig.captured.runtimes.last?.handle(stackID: "elsewhere", actionID: "dismiss")
        #expect(rig.scheduler.jobs == jobs, "nothing to hide, so nothing is armed early")
    }

    @Test func aDismissLandingWhileALineIsPublishingNeverLeavesAGhostLine() {
        let clock = Clock(), scheduler = FakeScheduler(), reports = Reports()
        let battery = FakeBattery(healthy.health(55))
        let module = BatteryHealthModule(port: battery, scheduler: scheduler, now: { clock.now })
        let box = RuntimeBox()
        let runtime = module.makeRuntime(context: SaysoModuleContext(
            moduleID: "battery-health",
            publish: { activity in
                // The user taps Dismiss on the old line between the sample deciding to repaint and the repaint.
                if reports.tapDuringNextPublish {
                    reports.tapDuringNextPublish = false
                    box.runtime?.handle(stackID: activity.stackID, actionID: "dismiss")
                }
                reports.log.append("show \(activity.title)")
            },
            dismiss: { reports.log.append("clear \($0)") }
        ))
        box.runtime = runtime
        func advance(_ seconds: TimeInterval) {
            clock.now += seconds
            scheduler.runDue(clock.now)
        }
        runtime.start()
        advance(0)
        #expect(reports.log == ["show Battery health 55% · Replace soon"])
        reports.tapDuringNextPublish = true
        battery.set(healthy.health(54))
        advance(BatteryHealthModule.idleIntervalSeconds)
        advance(0)
        #expect(reports.log.last == "clear \(wornStack)", "the dismissed line ends up cleared: \(reports.log)")
    }

    // MARK: Cadence

    @Test func unwatchedItSamplesOnceAMinuteWithOneJob() {
        let rig = rig()
        #expect(rig.battery.reads == 1)
        #expect(rig.scheduler.jobs == [rig.clock.now + BatteryHealthModule.idleIntervalSeconds])
        rig.advance(BatteryHealthModule.idleIntervalSeconds - 1)
        #expect(rig.battery.reads == 1)
        rig.advance(1)
        #expect(rig.battery.reads == 2)
        #expect(rig.scheduler.jobs.count == 1)
    }

    @Test func whileTheStudioPaneIsWatchedItSamplesEveryTenSeconds() {
        let rig = rig()
        rig.module.setObserved(true)
        #expect(rig.scheduler.jobs == [rig.clock.now + BatteryHealthModule.observedIntervalSeconds])
        rig.advance(BatteryHealthModule.observedIntervalSeconds)
        #expect(rig.battery.reads == 2)
        rig.module.setObserved(false)
        #expect(rig.scheduler.jobs == [rig.clock.now + BatteryHealthModule.idleIntervalSeconds])
        #expect(rig.scheduler.jobs.count == 1)
    }

    @Test func aWatchChangeNeverPushesAPendingDismissOrClockChangeLater() {
        let rig = rig(healthy.health(55))
        rig.tap("dismiss", on: wornStack)
        rig.module.setObserved(true)
        rig.module.setObserved(false)
        #expect(rig.scheduler.jobs == [rig.clock.now], "the dismissal still lands at once")
        rig.advance(0)
        #expect(rig.lines.isEmpty)

        rig.advance(1)
        rig.module.clockChanged()
        rig.module.setObserved(true)
        #expect(rig.scheduler.jobs == [rig.clock.now], "the clock change still samples at once")
    }

    @Test func aClockSetBackSamplesAtOnceInsteadOfWaitingForTheOldTime() {
        let rig = rig()
        rig.clock.now -= 3_600
        rig.module.clockChanged()
        #expect(rig.scheduler.jobs == [rig.clock.now], "the pending job was set against the old time")
        rig.advance(0)
        #expect(rig.battery.reads == 2)
        #expect(rig.scheduler.jobs == [rig.clock.now + BatteryHealthModule.idleIntervalSeconds])
    }

    // MARK: Failures

    @Test func aFailingReadIsReportedOnceBacksOffAndTheLineReturnsAfter() {
        let clock = Clock(), scheduler = FakeScheduler(), reports = Reports(), battery = FakeBattery(healthy.health(55))
        let module = BatteryHealthModule(port: battery, scheduler: scheduler, now: { clock.now })
        let runtime = module.makeRuntime(context: SaysoModuleContext(
            moduleID: "battery-health",
            publish: { reports.log.append("show \($0.title)") },
            reportFailure: { reports.failures += 1 },
            dismiss: { reports.log.append("clear \($0)") }
        ))
        func advance(_ seconds: TimeInterval) {
            clock.now += seconds
            scheduler.runDue(clock.now)
        }
        module.setObserved(true)
        runtime.start()
        advance(0)
        #expect(reports.log == ["show Battery health 55% · Replace soon"])

        battery.fail(.unavailable)
        advance(BatteryHealthModule.observedIntervalSeconds)
        #expect(reports.failures == 1)
        #expect(module.snapshot == nil, "a failed read cannot vouch for anything")
        #expect(reports.log.last == "clear \(wornStack)", "nor for the old line")
        #expect(scheduler.jobs == [clock.now + BatteryHealthModule.failureBackoffSeconds], "backs off even while watched")
        for _ in 0..<5 { advance(BatteryHealthModule.failureBackoffSeconds) }
        #expect(battery.reads == 7)
        #expect(reports.failures == 1, "a lasting failure is reported once, not on every sample")

        battery.fail(nil)
        advance(BatteryHealthModule.failureBackoffSeconds)
        #expect(module.snapshot?.healthText == "55% · Replace soon")
        #expect(reports.log.last == "show Battery health 55% · Replace soon")
        #expect(scheduler.jobs == [clock.now + BatteryHealthModule.observedIntervalSeconds])
    }

    @Test func aLastingFailureLeavesTheModuleDegradedNeverQuarantined() {
        let rig = rig()
        rig.battery.fail(.unavailable)
        rig.advance(BatteryHealthModule.idleIntervalSeconds)
        #expect(rig.host.health(of: "battery-health") == .degraded)
        for _ in 0..<40 { rig.advance(BatteryHealthModule.failureBackoffSeconds) }
        #expect(rig.host.health(of: "battery-health") != .quarantined)
        for _ in 0..<5 {
            rig.battery.fail(nil)
            rig.advance(BatteryHealthModule.failureBackoffSeconds)
            rig.battery.fail(.unavailable)
            rig.advance(BatteryHealthModule.idleIntervalSeconds)
        }
        #expect(rig.host.health(of: "battery-health") != .quarantined, "flaky reads within five minutes report at most once")
    }

    @Test func aFailureThatReturnsWithinFiveMinutesOfTheLastReportIsNotReportedAgain() {
        let clock = Clock(), scheduler = FakeScheduler(), reports = Reports(), battery = FakeBattery(healthy)
        let module = BatteryHealthModule(port: battery, scheduler: scheduler, now: { clock.now })
        let runtime = module.makeRuntime(context: SaysoModuleContext(
            moduleID: "battery-health", publish: { _ in }, reportFailure: { reports.failures += 1 }
        ))
        func advance(_ seconds: TimeInterval) {
            clock.now += seconds
            scheduler.runDue(clock.now)
        }
        runtime.start()
        battery.fail(.unavailable)
        advance(0)
        #expect(reports.failures == 1)
        battery.fail(nil)
        advance(BatteryHealthModule.failureBackoffSeconds)
        battery.fail(.unavailable)
        advance(BatteryHealthModule.idleIntervalSeconds)
        #expect(reports.failures == 1, "a new run of failures inside the window is not reported")
        battery.fail(nil)
        advance(BatteryHealthModule.failureBackoffSeconds)
        battery.fail(.unavailable)
        advance(BatteryHealthModule.failureReportWindowSeconds)
        #expect(reports.failures == 2, "a new run a full window after the last report is reported")
    }

    @Test func aFailedReadKeepsADismissal() {
        let rig = rig(healthy.health(55))
        rig.tap("dismiss", on: wornStack)
        rig.advance(0)
        rig.battery.fail(.unavailable)
        rig.advance(rig.nextSampleIn)
        rig.battery.fail(nil)
        rig.advance(rig.nextSampleIn)
        #expect(rig.lines.isEmpty, "dismissed and still worn: an outage in between does not bring it back")
    }

    // MARK: Off

    @Test func disableCancelsTheJobAndPurgesTheSnapshotAndLines() {
        let rig = rig(healthy.health(55).temperature(47))
        rig.module.setObserved(true)
        #expect(rig.retained == 1)
        #expect(rig.lines.count == 2)
        rig.host.disable("battery-health")
        #expect(rig.retained == 0)
        #expect(rig.scheduler.jobs.isEmpty)
        #expect(rig.module.snapshot == nil)
        #expect(rig.lines.isEmpty)
        let reads = rig.battery.reads
        rig.module.setObserved(false)
        rig.module.clockChanged()
        rig.advance(BatteryHealthModule.idleIntervalSeconds * 10)
        #expect(rig.scheduler.jobs.isEmpty, "a disabled module arms nothing")
        #expect(rig.battery.reads == reads, "and reads nothing")

        rig.tap("dismiss", on: wornStack)
        rig.host.enable("battery-health")
        rig.advance(0)
        #expect(rig.lines.count == 2, "a fresh start remembers no dismissal")
    }

    /// The app applies `batteryHealthEnabled` through `setEnabled` at launch and on every settings save.
    @Test func theSettingGateKeepsItOffAtLaunchAndPurgesItWhenTurnedOff() {
        let clock = Clock(), scheduler = FakeScheduler(), captured = Captured(), battery = FakeBattery(healthy.health(55))
        let module = BatteryHealthModule(port: battery, scheduler: scheduler, now: { clock.now })
        let host = SaysoModuleHost(modules: [Probe(inner: module, captured: captured)], now: { clock.now })
        let lines = { host.engine.stack.filter { $0.moduleID == "battery-health" } }

        host.setEnabled("battery-health", false)
        module.clockChanged()
        scheduler.runDue(clock.now)
        #expect(host.health(of: "battery-health") == .disabled)
        #expect(captured.runtimes.isEmpty, "off at launch never starts a runtime")
        #expect(scheduler.jobs.isEmpty)
        #expect(battery.reads == 0)

        host.setEnabled("battery-health", true)
        scheduler.runDue(clock.now)
        let runtime = captured.runtimes.last as? SaysoResourceAccounting
        #expect(lines().map(\.title) == ["Battery health 55% · Replace soon"])
        #expect(runtime?.retainedResources == 1)

        host.setEnabled("battery-health", false)
        #expect(host.health(of: "battery-health") == .disabled)
        #expect(runtime?.retainedResources == 0)
        #expect(scheduler.jobs.isEmpty)
        #expect(module.snapshot == nil, "turning it off forgets what it read")
        #expect(lines().isEmpty, "turning it off clears its notch line")
    }

    @Test func passesTheModuleAcceptanceContract() {
        let module = BatteryHealthModule(port: FakeBattery(nil), scheduler: FakeScheduler())
        #expect(SaysoModuleAcceptance.violations(for: module) == [])
        #expect(module.descriptor.id == "battery-health")
        #expect(module.descriptor.capabilities.isEmpty, "reading the battery registry needs no permission")
    }

    // MARK: UI test hook

    @Test func theUITestHookIsHonouredOnlyWithFreshSettings() throws {
        #expect(BatteryHealthUITestHook.port(arguments: ["app", "--ui-test-battery", "worn"]) == nil, "a real launch reads the real battery")
        #expect(BatteryHealthUITestHook.port(arguments: ["app", "--ui-test-fresh-settings"]) == nil)

        func snapshot(_ value: String?) throws -> BatteryHealthSnapshot {
            let arguments = ["app", "--ui-test-fresh-settings", "--ui-test-battery"] + (value.map { [$0] } ?? [])
            let port = try #require(BatteryHealthUITestHook.port(arguments: arguments))
            let reading = try port.read()
            return BatteryHealthSnapshot(battery: reading.battery, devices: reading.devices, sampledAt: .distantPast)
        }
        #expect(try snapshot("healthy").healthText == "92% · Normal")
        let worn = try snapshot("worn")
        #expect(worn.healthText == "55% · Replace soon")
        #expect(worn.cyclesText == "1,234")
        #expect(worn.temperatureText == "31.5 °C")
        #expect(worn.powerText == "On battery · 3 h 20 min left")
        #expect(try snapshot("hot").temperatureText == "46.5 °C")
        #expect(try snapshot("none").healthText == "No battery")
        #expect(try snapshot("bogus").healthText == "No battery", "an unknown value is a fake with no battery, never the real one")
        #expect(try snapshot(nil).healthText == "No battery")
    }
}
