import Foundation
import Testing
@testable import SaysoCore

/// In-memory port; counts saves so a refused edit that still wrote fails the test.
private final class FakeStore: WorldClocksStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [WorldClockZone]
    private var saves = 0

    init(_ zones: [WorldClockZone] = []) { stored = zones }

    var zones: [WorldClockZone] { lock.withLock { stored } }
    var saveCount: Int { lock.withLock { saves } }

    func load() -> [WorldClockZone] { lock.withLock { stored } }
    func save(_ zones: [WorldClockZone]) { lock.withLock { stored = zones; saves += 1 } }
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

private final class Clock: @unchecked Sendable {
    var now: Date
    var local: TimeZone
    init(now: Date, local: TimeZone) { self.now = now; self.local = local }
}

private final class Captured: @unchecked Sendable {
    var runtimes: [SaysoModuleRuntime] = []
    var contexts: [SaysoModuleContext] = []
    var changes = 0
}

/// Hands the real runtime and context to the test so resource accounting and failures can be driven.
private struct Probe: SaysoModule {
    let inner: WorldClocksModule
    let captured: Captured
    var descriptor: SaysoModuleDescriptor { inner.descriptor }
    func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        let runtime = inner.makeRuntime(context: context)
        captured.runtimes.append(runtime)
        captured.contexts.append(context)
        return runtime
    }
}

/// Only these identifiers resolve, so "unknown" never depends on the host's time zone database.
private let knownZones = [
    "UTC", "Europe/London", "Europe/Paris", "America/New_York", "America/Los_Angeles", "Asia/Tokyo",
    "Asia/Kolkata", "Asia/Kathmandu", "Australia/Sydney",
]

private func resolve(_ identifier: String) -> TimeZone? {
    knownZones.contains(identifier) ? TimeZone(identifier: identifier) : nil
}

private func instant(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
}

private func zone(_ identifier: String, _ city: String) -> WorldClockZone {
    WorldClockZone(identifier: identifier, city: city)
}

private struct Rig {
    let host: SaysoModuleHost
    let module: WorldClocksModule
    let store: FakeStore
    let scheduler: FakeScheduler
    let clock: Clock
    let captured: Captured

    func advance(_ seconds: TimeInterval) {
        clock.now += seconds
        scheduler.runDue(clock.now)
    }

    var activities: [SaysoActivity] { host.engine.stack.filter { $0.moduleID == "world-clocks" } }
    var ids: [String] { module.zones.map(\.identifier) }
    var retained: Int { (captured.runtimes.last as? SaysoResourceAccounting)?.retainedResources ?? -1 }
}

private func rig(
    _ saved: [WorldClockZone] = [],
    at now: String = "2026-01-15T00:00:30Z",
    local: String = "UTC",
    hourCycle: WorldClockHourCycle = .twentyFour
) -> Rig {
    let store = FakeStore(saved), scheduler = FakeScheduler(), captured = Captured()
    let clock = Clock(now: instant(now), local: TimeZone(identifier: local)!)
    let module = WorldClocksModule(
        store: store, scheduler: scheduler, hourCycle: hourCycle,
        now: { clock.now }, localTimeZone: { clock.local }, resolveZone: resolve
    )
    let host = SaysoModuleHost(modules: [Probe(inner: module, captured: captured)], now: { clock.now })
    host.onActivitiesChanged = { captured.changes += 1 }
    host.enable("world-clocks")
    return Rig(host: host, module: module, store: store, scheduler: scheduler, clock: clock, captured: captured)
}

@Suite struct WorldClocksModuleTests {
    // MARK: Choosing zones

    @Test func addedZonesKeepTheirOrderAndAreSaved() throws {
        let rig = rig()
        try rig.module.add("Asia/Tokyo")
        try rig.module.add("Europe/London", city: "London office")

        #expect(rig.ids == ["Asia/Tokyo", "Europe/London"])
        #expect(rig.module.zones.map(\.city) == ["Tokyo", "London office"])
        #expect(rig.store.zones == rig.module.zones, "every change reaches the store")
    }

    @Test func theDefaultCityComesFromTheIdentifierAndLabelsAreTrimmedAndCapped() throws {
        let rig = rig()
        try rig.module.add("America/New_York", city: "   ")
        try rig.module.add("Asia/Tokyo", city: "  Shibuya  ")
        try rig.module.add("Europe/Paris", city: String(repeating: "x", count: 500))

        #expect(rig.module.zones.map(\.city) == ["New York", "Shibuya", String(repeating: "x", count: WorldClocksModule.maxCityLength)])
    }

    @Test func unknownIdentifiersAndDuplicatesAreRejectedWithoutSaving() throws {
        let rig = rig()
        try rig.module.add("Asia/Tokyo")
        let saves = rig.store.saveCount

        for bad in ["Mars/Olympus", "", "asia/tokyo", "Tokyo"] {
            #expect(throws: WorldClocksError.unknownZone, "\(bad)") { try rig.module.add(bad) }
        }
        #expect(throws: WorldClocksError.duplicate) { try rig.module.add("Asia/Tokyo", city: "Again") }
        #expect(rig.ids == ["Asia/Tokyo"])
        #expect(rig.store.saveCount == saves)
    }

    @Test func theSeventhZoneIsRejected() throws {
        let rig = rig()
        let six = ["UTC", "Europe/London", "Europe/Paris", "America/New_York", "America/Los_Angeles", "Asia/Tokyo"]
        for identifier in six { try rig.module.add(identifier) }
        #expect(WorldClocksModule.maxZones == 6)

        #expect(throws: WorldClocksError.full) { try rig.module.add("Asia/Kolkata") }
        #expect(rig.ids == six)
        #expect(rig.store.zones.count == 6)
    }

    @Test func zonesCanBeRemovedAndReordered() throws {
        let rig = rig()
        for identifier in ["Asia/Tokyo", "Europe/London", "America/New_York"] { try rig.module.add(identifier) }

        #expect(rig.module.move("America/New_York", to: 0))
        #expect(rig.ids == ["America/New_York", "Asia/Tokyo", "Europe/London"])
        #expect(rig.module.move("America/New_York", to: 2))
        #expect(rig.ids == ["Asia/Tokyo", "Europe/London", "America/New_York"])
        #expect(!rig.module.move("America/New_York", to: 3), "out of range")
        #expect(!rig.module.move("Asia/Kolkata", to: 0), "not in the list")

        #expect(rig.module.remove("Europe/London"))
        #expect(!rig.module.remove("Europe/London"), "already gone")
        #expect(rig.ids == ["Asia/Tokyo", "America/New_York"])
        #expect(rig.store.zones.map(\.identifier) == rig.ids)
    }

    @Test func aSavedListIsRestoredWithoutUnknownDuplicateOrExtraEntries() {
        let saved = [
            zone("Asia/Tokyo", "Tokyo"), zone("Mars/Olympus", "Mars"), zone("Asia/Tokyo", "Tokyo again"),
            zone("Europe/London", "London"), zone("UTC", "UTC"), zone("Europe/Paris", "Paris"),
            zone("America/New_York", "New York"), zone("Asia/Kolkata", "Kolkata"), zone("Australia/Sydney", "Sydney"),
        ]
        let rig = rig(saved)

        #expect(rig.ids == ["Asia/Tokyo", "Europe/London", "UTC", "Europe/Paris", "America/New_York", "Asia/Kolkata"])
        #expect(rig.store.saveCount == 0, "reading the saved list never rewrites it")
    }

    @Test func aDisabledModuleShowsNothingAndRefusesEditsButKeepsTheSavedList() throws {
        let rig = rig([zone("Asia/Tokyo", "Tokyo")])
        rig.host.disable("world-clocks")

        #expect(rig.module.zones.isEmpty)
        #expect(throws: WorldClocksError.disabled) { try rig.module.add("Europe/London") }
        #expect(!rig.module.remove("Asia/Tokyo"))
        #expect(rig.store.zones.map(\.identifier) == ["Asia/Tokyo"], "disabling is not a reason to forget the user's choice")

        rig.host.enable("world-clocks")
        #expect(rig.ids == ["Asia/Tokyo"])
    }

    @Test func passesTheModuleAcceptanceContract() {
        let module = WorldClocksModule(
            store: FakeStore([zone("Asia/Tokyo", "Tokyo")]), scheduler: FakeScheduler(), resolveZone: resolve
        )
        #expect(module.descriptor.id == "world-clocks")
        #expect(module.descriptor.capabilities.isEmpty, "reading the clock needs no permission")
        #expect(SaysoModuleAcceptance.violations(for: module) == [])
    }
}
