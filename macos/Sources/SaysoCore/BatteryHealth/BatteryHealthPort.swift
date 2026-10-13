import Foundation

/// This Mac's own battery, raw: the snapshot works out health and text from it. A figure the system would not give
/// is nil, so one missing figure never blanks the others.
public struct MacBatteryReading: Equatable, Sendable {
    /// What the battery held when new, in mAh.
    public var designCapacity: Int?
    /// What the battery holds now when full, in mAh.
    public var maxCapacity: Int?
    public var cycleCount: Int?
    public var temperatureCelsius: Double?
    /// Taking charge right now; a full or held battery on power is not charging.
    public var isCharging: Bool?
    public var isExternalPowerConnected: Bool?
    /// To full while charging, to empty on battery; nil while the system is still estimating.
    public var minutesRemaining: Int?

    public init(
        designCapacity: Int?,
        maxCapacity: Int?,
        cycleCount: Int?,
        temperatureCelsius: Double?,
        isCharging: Bool?,
        isExternalPowerConnected: Bool?,
        minutesRemaining: Int?
    ) {
        self.designCapacity = designCapacity
        self.maxCapacity = maxCapacity
        self.cycleCount = cycleCount
        self.temperatureCelsius = temperatureCelsius
        self.isCharging = isCharging
        self.isExternalPowerConnected = isExternalPowerConnected
        self.minutesRemaining = minutesRemaining
    }
}

/// Another battery the system reports: a UPS or a peripheral such as a keyboard or mouse.
public struct DeviceBattery: Equatable, Sendable {
    /// Stable while the device stays connected; unique in one reading.
    public var id: String
    public var name: String
    public var percent: Int

    public init(id: String, name: String, percent: Int) {
        self.id = id
        self.name = name
        self.percent = percent
    }

    /// `Magic Keyboard 74%`; a blank name reads as a Bluetooth device, the only kind that comes without one.
    public var text: String {
        let words = name.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return "\(words.isEmpty ? "Bluetooth device" : words) \(min(max(percent, 0), 100))%"
    }
}

/// One read: this Mac's battery, nil when it has none, and every other battery the system reports.
public struct BatteryHealthReading: Equatable, Sendable {
    public var battery: MacBatteryReading?
    public var devices: [DeviceBattery]

    public init(battery: MacBatteryReading?, devices: [DeviceBattery]) {
        self.battery = battery
        self.devices = devices
    }
}

public enum BatteryHealthPortError: Error, Equatable, Sendable {
    /// The system lists a battery but would not give its properties.
    case unavailable
}

/// Boundary to the system's battery registry. An adapter only reads public power source and registry properties: it
/// never talks to a Bluetooth device, so it needs no permission.
public protocol BatteryHealthPort: Sendable {
    func read() throws(BatteryHealthPortError) -> BatteryHealthReading
}
