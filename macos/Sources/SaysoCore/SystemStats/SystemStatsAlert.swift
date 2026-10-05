import Foundation

/// A condition worth a notch line. Each has its own line, so dismissing one never hides another.
/// Every condition enters at one threshold and clears at a safer one, so a reading that wobbles around the
/// threshold never makes the line flap.
enum SystemStatsAlert: String, CaseIterable, Sendable {
    case battery
    case memory
    case disk

    /// Battery at or below this whole percent, and not plugged in, is notable...
    static let batteryLowPercent = 20
    /// ...until it is back at this percent or plugged in.
    static let batteryRecoveredPercent = 25
    /// Less free disk than this is notable...
    static let diskLowBytes: Int64 = 5_000_000_000
    /// ...until at least this much is free again.
    static let diskRecoveredBytes: Int64 = 6_000_000_000

    var stackID: String { "system-stats-\(rawValue)" }

    init?(stackID: String) {
        guard let alert = Self.allCases.first(where: { $0.stackID == stackID }) else { return nil }
        self = alert
    }

    /// True enters, false clears, nil keeps whatever state the condition is already in.
    func verdict(for stats: SystemStatsSnapshot) -> Bool? {
        switch self {
        case .battery:
            // No battery, or no power state to say it is not charging: nothing to warn about.
            guard let percent = stats.batteryPercent, stats.isPluggedIn == false else { return false }
            if percent <= Self.batteryLowPercent { return true }
            return percent >= Self.batteryRecoveredPercent ? false : nil
        case .memory:
            switch stats.memoryPressure {
            case .critical: return true
            case .normal: return false
            case .warning: return nil
            }
        case .disk:
            if stats.diskFreeBytes < Self.diskLowBytes { return true }
            return stats.diskFreeBytes >= Self.diskRecoveredBytes ? false : nil
        }
    }

    func title(for stats: SystemStatsSnapshot) -> String {
        switch self {
        case .battery:
            return "Battery \(stats.batteryPercent ?? 0)%, not plugged in"
        case .memory:
            let used = stats.memoryUsedFraction.map { "\(SystemStatsSnapshot.percent($0))% used" }
            return ["Memory pressure \(stats.memoryPressure.rawValue)", used].compactMap { $0 }.joined(separator: ", ")
        case .disk:
            return "Disk almost full, \(SystemStatsSnapshot.gigabytes(stats.diskFreeBytes)) GB free"
        }
    }
}
