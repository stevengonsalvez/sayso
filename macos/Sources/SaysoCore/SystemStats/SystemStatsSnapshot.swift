import Foundation

/// One sample as the UI shows it: values clamped to their range, unknown values nil, text ready to draw.
public struct SystemStatsSnapshot: Equatable, Sendable {
    /// Fraction of CPU time busy since the previous sample; nil for the first sample, which has nothing to compare.
    public let cpuLoad: Double?
    public let memoryUsedFraction: Double?
    public let memoryPressure: SystemMemoryPressure
    public let batteryFraction: Double?
    /// Nil whenever `batteryFraction` is nil.
    public let isPluggedIn: Bool?
    public let diskFreeBytes: Int64
    public let sampledAt: Date

    public init(
        cpuLoad: Double?,
        memoryUsedFraction: Double?,
        memoryPressure: SystemMemoryPressure,
        batteryFraction: Double?,
        isPluggedIn: Bool?,
        diskFreeBytes: Int64,
        sampledAt: Date
    ) {
        self.cpuLoad = cpuLoad.flatMap(Self.unit)
        self.memoryUsedFraction = memoryUsedFraction.flatMap(Self.unit)
        self.memoryPressure = memoryPressure
        self.batteryFraction = batteryFraction.flatMap(Self.unit)
        self.isPluggedIn = self.batteryFraction == nil ? nil : isPluggedIn
        self.diskFreeBytes = max(diskFreeBytes, 0)
        self.sampledAt = sampledAt
    }

    /// Whole percent of the battery, the number the thresholds and the text both use.
    public var batteryPercent: Int? { batteryFraction.map(Self.percent) }

    public var cpuText: String { cpuLoad.map { "\(Self.percent($0))%" } ?? "Measuring" }

    public var memoryText: String {
        let used = memoryUsedFraction.map { "\(Self.percent($0))% used" } ?? "Unknown"
        return "\(used), pressure \(memoryPressure.rawValue)"
    }

    public var batteryText: String {
        guard let batteryPercent else { return "No battery" }
        guard let isPluggedIn else { return "\(batteryPercent)%" }
        return "\(batteryPercent)%, \(isPluggedIn ? "plugged in" : "on battery")"
    }

    public var diskText: String { "\(Self.gigabytes(diskFreeBytes)) GB free" }

    /// Decimal gigabytes with one decimal, as Finder counts them; fixed format so it never depends on the locale.
    static func gigabytes(_ bytes: Int64) -> String { String(format: "%.1f", Double(bytes) / 1_000_000_000) }

    static func percent(_ fraction: Double) -> Int { Int((fraction * 100).rounded()) }

    private static func unit(_ value: Double) -> Double? { value.isFinite ? min(max(value, 0), 1) : nil }
}
