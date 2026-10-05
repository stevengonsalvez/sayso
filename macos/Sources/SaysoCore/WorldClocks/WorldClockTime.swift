import Foundation

public enum WorldClockHourCycle: Equatable, Sendable {
    case twelve
    case twentyFour

    /// The user's 12 or 24 hour preference as carried by their locale.
    public init(locale: Locale) {
        switch locale.hourCycle {
        case .zeroToEleven, .oneToTwelve: self = .twelve
        case .zeroToTwentyThree, .oneToTwentyFour: self = .twentyFour
        @unknown default: self = .twentyFour
        }
    }
}

/// The time in one chosen zone at one instant.
public struct WorldClockReading: Equatable, Sendable {
    public let zone: WorldClockZone
    /// "09:05" on a 24 hour clock, "9:05 AM" on a 12 hour clock.
    public let time: String
    /// Calendar days ahead of the local zone: 1 when it is already tomorrow there, -1 when still yesterday.
    public let dayOffset: Int

    /// "Tokyo 09:05 +1d"; the day suffix appears only when the date differs from the local one.
    public var title: String {
        let day = dayOffset == 0 ? "" : dayOffset > 0 ? " +\(dayOffset)d" : " \(dayOffset)d"
        return "\(zone.city) \(time)\(day)"
    }
}

enum WorldClockTime {
    static func reading(
        for zone: WorldClockZone, in timeZone: TimeZone, local: TimeZone, at date: Date, hourCycle: WorldClockHourCycle
    ) -> WorldClockReading {
        let there = wallClock(date, in: timeZone)
        let here = wallClock(date, in: local)
        return WorldClockReading(
            zone: zone, time: format(there.minuteOfDay, hourCycle), dayOffset: there.day - here.day
        )
    }

    /// Day number and minute of day on the wall clock in `timeZone`. The UTC offset at that instant carries DST,
    /// so the result never depends on the host's locale or calendar settings.
    private static func wallClock(_ date: Date, in timeZone: TimeZone) -> (day: Int, minuteOfDay: Int) {
        // Clamped far beyond any real clock so an absurd injected instant cannot trap on Int overflow.
        let utc = min(max(date.timeIntervalSince1970, -1e13), 1e13).rounded(.down)
        let seconds = Int(utc) + timeZone.secondsFromGMT(for: date)
        let day = Int((Double(seconds) / 86_400).rounded(.down))
        return (day, (seconds - day * 86_400) / 60)
    }

    private static func format(_ minuteOfDay: Int, _ hourCycle: WorldClockHourCycle) -> String {
        let (hour, minute) = (minuteOfDay / 60, minuteOfDay % 60)
        let minutes = minute < 10 ? "0\(minute)" : "\(minute)"
        switch hourCycle {
        case .twentyFour:
            return "\(hour < 10 ? "0" : "")\(hour):\(minutes)"
        case .twelve:
            let twelve = hour % 12 == 0 ? 12 : hour % 12
            return "\(twelve):\(minutes) \(hour < 12 ? "AM" : "PM")"
        }
    }
}
