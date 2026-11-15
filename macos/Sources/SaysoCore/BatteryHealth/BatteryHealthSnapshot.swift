import Foundation

/// How worn the battery is, from its health percent.
public enum BatteryCondition: Equatable, Sendable {
    case normal
    case serviceSoon
    case replaceSoon
    /// A capacity is missing or zero, so no percent can be given.
    case unknown

    /// At or above this whole percent the battery is normal...
    public static let normalPercent = 80
    /// ...at or above this it needs service soon, and below it replacing soon.
    public static let servicePercent = 60

    init(percent: Int?) {
        guard let percent else {
            self = .unknown
            return
        }
        self = percent >= Self.normalPercent ? .normal : percent >= Self.servicePercent ? .serviceSoon : .replaceSoon
    }

    public var text: String {
        switch self {
        case .normal: "Normal"
        case .serviceSoon: "Service soon"
        case .replaceSoon: "Replace soon"
        case .unknown: "Unknown"
        }
    }
}

/// One read as the UI shows it. Every text is in a fixed format, so it never depends on the locale.
public struct BatteryHealthSnapshot: Equatable, Sendable {
    /// Nil on a Mac with no battery.
    public let battery: MacBatteryReading?
    public let devices: [DeviceBattery]
    public let sampledAt: Date

    /// A temperature outside this range is a missing or broken reading (a raw zero reads -273 °C), not a battery.
    static let plausibleCelsius = -40.0...120.0

    public init(battery: MacBatteryReading?, devices: [DeviceBattery], sampledAt: Date) {
        self.battery = battery
        self.devices = devices
        self.sampledAt = sampledAt
    }

    /// Max capacity over design capacity, as a whole percent clamped to 0...100; nil when either is missing, zero or
    /// negative, so missing data never reads 0% and nothing divides by zero.
    public var healthPercent: Int? {
        guard let max = battery?.maxCapacity, let design = battery?.designCapacity, max > 0, design > 0 else { return nil }
        // Clamped before converting, so an absurd capacity can never overflow Int.
        return Int(min(Double(max) / Double(design) * 100, 100).rounded())
    }

    /// Nil on a Mac with no battery. Worked out from the whole percent shown, so the label never disagrees with it.
    public var condition: BatteryCondition? { battery.map { _ in BatteryCondition(percent: healthPercent) } }

    /// A plausible reading in degrees Celsius, else nil.
    public var temperatureCelsius: Double? {
        guard let celsius = battery?.temperatureCelsius, Self.plausibleCelsius.contains(celsius) else { return nil }
        return celsius
    }

    public var healthText: String {
        guard let condition else { return Self.noBattery }
        return healthPercent.map { "\($0)% · \(condition.text)" } ?? condition.text
    }

    public var cyclesText: String {
        guard let battery else { return Self.noBattery }
        guard let count = battery.cycleCount, count >= 0 else { return "Unknown" }
        return Self.grouped(count)
    }

    public var temperatureText: String {
        guard battery != nil else { return Self.noBattery }
        return temperatureCelsius.map { String(format: "%.1f °C", $0) } ?? "Unknown"
    }

    public var powerText: String {
        guard let battery else { return Self.noBattery }
        let minutes = battery.minutesRemaining.flatMap { $0 > 0 ? Self.duration($0) : nil }
        if battery.isCharging == true { return minutes.map { "Charging · \($0) to full" } ?? "Charging" }
        switch battery.isExternalPowerConnected {
        case true?: return "Plugged in, not charging"
        case false?: return minutes.map { "On battery · \($0) left" } ?? "On battery"
        case nil: return "Unknown"
        }
    }

    static let noBattery = "No battery"

    /// `1,234,567`, the same in every locale.
    static func grouped(_ value: Int) -> String {
        let digits = String(value)
        var groups: [Substring] = []
        var end = digits.endIndex
        while end > digits.startIndex {
            let start = digits.index(end, offsetBy: -3, limitedBy: digits.startIndex) ?? digits.startIndex
            groups.insert(digits[start..<end], at: 0)
            end = start
        }
        return groups.joined(separator: ",")
    }

    /// `45 min`, `2 h`, `3 h 20 min`.
    static func duration(_ minutes: Int) -> String {
        let (hours, rest) = minutes.quotientAndRemainder(dividingBy: 60)
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}
