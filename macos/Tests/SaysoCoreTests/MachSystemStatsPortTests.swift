import Foundation
import Testing
@testable import SaysoCore

private final class ManualScheduler: SaysoScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [@Sendable () -> Void] = []

    func schedule(at date: Date, _ action: @escaping @Sendable () -> Void) -> SaysoSubscription {
        lock.withLock { pending = [action] }
        return SaysoSubscription { [weak self] in self?.lock.withLock { self?.pending = [] } }
    }

    /// Runs the one pending job now, whatever its due time.
    func runNext() {
        let job = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { pending = [] }
            return pending.first
        }
        job?()
    }
}

private final class Clock: @unchecked Sendable { var now = Date() }

/// Keeps one core busy until the kernel publishes new CPU ticks, at least `seconds` and at most 5 s. The ticks
/// usually move every few milliseconds but can stall for most of a second on a saturated machine.
private func spinUntilTicksMove(from start: SystemCPUTicks, atLeast seconds: TimeInterval) throws {
    let port = MachSystemStatsPort()
    let begun = Date()
    var x = 0.0
    while true {
        x += sin(x)
        let waited = Date().timeIntervalSince(begun)
        if waited >= 5 { break }
        if waited >= seconds, try port.read().cpuTicks != start { break }
    }
    #expect(x.isFinite)
}

/// Runs against this Mac's real kernel, IOKit and file system: no fakes. Ranges only, since the values move.
@Suite struct MachSystemStatsPortTests {
    @Test func twoRealSamplesThroughTheModuleGiveACPULoadBetweenZeroAndOne() throws {
        let scheduler = ManualScheduler(), clock = Clock()
        let module = SystemStatsModule(port: MachSystemStatsPort(), scheduler: scheduler, now: { clock.now })
        let host = SaysoModuleHost(modules: [module])
        host.enable("system-stats")
        scheduler.runNext()
        let first = try #require(module.snapshot, "the real port answered")
        #expect(first.cpuLoad == nil, "one sample is not a load")
        try spinUntilTicksMove(from: MachSystemStatsPort().read().cpuTicks, atLeast: 0.3)
        // Only the module's clock jumps, so its second job counts as due; the ticks cover the real 0.3 s.
        clock.now += SystemStatsModule.idleIntervalSeconds
        scheduler.runNext()
        let load = try #require(module.snapshot?.cpuLoad)
        #expect((0...1).contains(load))
        #expect(load > 0, "a core was kept busy between the samples")
        host.disable("system-stats")
    }

    @Test func cpuTicksOnlyMoveForward() throws {
        let port = MachSystemStatsPort()
        let before = try port.read().cpuTicks
        try spinUntilTicksMove(from: before, atLeast: 0.1)
        let after = try port.read().cpuTicks
        let deltas: [UInt32] = [
            after.user &- before.user, after.system &- before.system, after.idle &- before.idle, after.nice &- before.nice,
        ]
        let elapsed = deltas.reduce(UInt64(0)) { $0 + UInt64($1) }
        #expect(elapsed > 0)
        #expect(elapsed < 1_000_000, "seconds of ticks at most, not a wrapped counter")
    }

    @Test func memoryUsedIsAFractionStrictlyBetweenZeroAndOne() throws {
        let reading = try MachSystemStatsPort().read()
        #expect(reading.memoryUsedFraction > 0)
        #expect(reading.memoryUsedFraction < 1)
    }

    @Test func diskFreeIsPositiveAndLessThanTheVolume() throws {
        let reading = try MachSystemStatsPort().read()
        let total = try #require(try URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity)
        #expect(reading.diskFreeBytes > 0)
        #expect(reading.diskFreeBytes < Int64(total))
    }

    @Test func aBatteryIfPresentHasALevelAndAPowerState() throws {
        let reading = try MachSystemStatsPort().read()
        if let battery = reading.batteryFraction {
            #expect((0...1).contains(battery))
            #expect(reading.isPluggedIn != nil)
        } else {
            #expect(reading.isPluggedIn == nil, "no battery, no power state")
        }
        print("SYSTEM-STATS-REAL battery=\(String(describing: reading.batteryFraction)) pluggedIn=\(String(describing: reading.isPluggedIn)) memory=\(reading.memoryUsedFraction) pressure=\(reading.memoryPressure) diskFree=\(reading.diskFreeBytes)")
    }
}
