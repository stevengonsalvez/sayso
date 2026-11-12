import Foundation

/// UI test launch hook: `--ui-test-battery healthy|worn|hot|none` swaps the real battery reader for a fixed fake, so
/// a UI test never depends on this Mac having a battery (a CI virtual machine has none) or on its real health.
/// Honoured only together with `--ui-test-fresh-settings`, so a real launch always reads the real battery.
public enum BatteryHealthUITestHook {
    /// The fake reader for a UI test launch, or nil to use the real one. A missing or unknown value gives a fake with
    /// no battery, never the real one.
    public static func port(arguments: [String]) -> BatteryHealthPort? {
        guard arguments.contains("--ui-test-fresh-settings"), let flag = arguments.firstIndex(of: "--ui-test-battery")
        else { return nil }
        let value = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : ""
        return FixedBatteryHealthPort(reading: reading(value))
    }

    private static func reading(_ value: String) -> BatteryHealthReading {
        let base = MacBatteryReading(
            designCapacity: 5_000, maxCapacity: 4_600, cycleCount: 123, temperatureCelsius: 30,
            isCharging: true, isExternalPowerConnected: true, minutesRemaining: 45
        )
        var battery = base
        switch value {
        case "healthy":
            return BatteryHealthReading(battery: base, devices: [DeviceBattery(id: "ui-test-keyboard", name: "UI Test Keyboard", percent: 80)])
        case "worn":
            battery.maxCapacity = 2_750
            battery.cycleCount = 1_234
            battery.temperatureCelsius = 31.5
            battery.isCharging = false
            battery.isExternalPowerConnected = false
            battery.minutesRemaining = 200
        case "hot":
            battery.maxCapacity = 4_500
            battery.cycleCount = 300
            battery.temperatureCelsius = 46.5
            battery.isCharging = false
            battery.minutesRemaining = nil
        default:
            return BatteryHealthReading(battery: nil, devices: [])
        }
        return BatteryHealthReading(battery: battery, devices: [])
    }
}

private struct FixedBatteryHealthPort: BatteryHealthPort {
    let reading: BatteryHealthReading

    func read() throws(BatteryHealthPortError) -> BatteryHealthReading { reading }
}
