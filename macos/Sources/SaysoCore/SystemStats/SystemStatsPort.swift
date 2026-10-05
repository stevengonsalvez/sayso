import Foundation

/// Cumulative CPU ticks since boot, summed over every core. Only the difference between two readings means
/// anything; each counter wraps at `UInt32.max`.
public struct SystemCPUTicks: Equatable, Sendable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

/// The kernel's own view of how hard memory is pressed, not a threshold on the used fraction.
public enum SystemMemoryPressure: String, Equatable, Sendable {
    case normal
    case warning
    case critical
}

/// One read of the machine, raw: the module clamps it and works out the CPU load from two of these.
public struct SystemStatsReading: Equatable, Sendable {
    public var cpuTicks: SystemCPUTicks
    /// App, wired and compressed memory over physical memory.
    public var memoryUsedFraction: Double
    public var memoryPressure: SystemMemoryPressure
    /// Nil on a Mac with no internal battery.
    public var batteryFraction: Double?
    /// True while external power is connected, whether or not the battery is taking charge right now (a full or
    /// held battery is plugged in but not charging). Nil on a Mac with no internal battery.
    public var isPluggedIn: Bool?
    /// Space free for important use on the startup volume, which counts purgeable space macOS can clear.
    public var diskFreeBytes: Int64

    public init(
        cpuTicks: SystemCPUTicks,
        memoryUsedFraction: Double,
        memoryPressure: SystemMemoryPressure,
        batteryFraction: Double?,
        isPluggedIn: Bool?,
        diskFreeBytes: Int64
    ) {
        self.cpuTicks = cpuTicks
        self.memoryUsedFraction = memoryUsedFraction
        self.memoryPressure = memoryPressure
        self.batteryFraction = batteryFraction
        self.isPluggedIn = isPluggedIn
        self.diskFreeBytes = diskFreeBytes
    }
}

public enum SystemStatsPortError: Error, Equatable, Sendable {
    /// The system did not answer one of the reads.
    case unavailable
}

/// Boundary to the machine's counters; the adapter owns the kernel, IOKit and file system calls.
public protocol SystemStatsPort: Sendable {
    func read() throws(SystemStatsPortError) -> SystemStatsReading
}
