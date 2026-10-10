import Foundation
import Testing
@testable import SaysoCore

/// The real adapter. Hardware tests assert only what holds on any Mac: a CI virtual machine has no battery and no
/// peripherals, so every check about a battery or device applies only where the system reports one, and an empty
/// reading must pass. The parsing tests feed registry dictionaries shaped like this Mac's and need no hardware.
@Suite(.timeLimit(.minutes(2))) struct IOKitBatteryHealthPortTests {
    // MARK: This Mac

    @Test func readingThisMacNeverThrowsAndAnyReportedBatteryIsPlausible() throws {
        let reading = try IOKitBatteryHealthPort().read()
        if let battery = reading.battery {
            #expect((battery.designCapacity ?? 0) > 0, "\(battery)")
            #expect((battery.cycleCount ?? -1) >= 0, "\(battery)")
            let celsius = try #require(battery.temperatureCelsius, "\(battery)")
            #expect((-20.0...90.0).contains(celsius), "\(battery)")
        }
        let snapshot = BatteryHealthSnapshot(battery: reading.battery, devices: reading.devices, sampledAt: Date())
        // Logged so the proof ledger can quote what this Mac reported, not only that it passed.
        let design: String = reading.battery?.designCapacity.map { String($0) } ?? "nil"
        let max: String = reading.battery?.maxCapacity.map { String($0) } ?? "nil"
        let devices: [String] = reading.devices.map { $0.text }
        let fields: [String] = [
            "design=\(design)", "max=\(max)", "health=\"\(snapshot.healthText)\"", "cycles=\"\(snapshot.cyclesText)\"",
            "temperature=\"\(snapshot.temperatureText)\"", "power=\"\(snapshot.powerText)\"", "devices=\(devices)",
        ]
        print("BATTERY-PORT-OBSERVED " + fields.joined(separator: " "))
    }

    @Test func everyReportedDeviceHasAnIdANameAndAPercentInRange() throws {
        let devices = try IOKitBatteryHealthPort().read().devices
        for device in devices {
            #expect(!device.id.isEmpty, "\(device)")
            #expect(!device.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(device)")
            #expect((0...100).contains(device.percent), "\(device)")
        }
        #expect(Set(devices.map(\.id)).count == devices.count, "one entry per device: \(devices)")
    }

    @Test func readingTwiceGivesTheSameBatteryAndDevices() throws {
        let port = IOKitBatteryHealthPort()
        let first = try port.read(), second = try port.read()
        #expect((first.battery == nil) == (second.battery == nil))
        #expect(first.battery?.designCapacity == second.battery?.designCapacity)
        #expect(first.devices.map(\.id).sorted() == second.devices.map(\.id).sorted())
    }

    /// The adapter may import only Foundation and IOKit, and may name no Bluetooth API: IOBluetooth and CoreBluetooth
    /// can make macOS ask for Bluetooth permission. Peripheral levels come from plain registry properties only.
    @Test func theBatteryHealthSourcesUseNoBluetoothAPI() throws {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SaysoCore/BatteryHealth", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.map(\.lastPathComponent).contains("IOKitBatteryHealthPort.swift"))
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let imports = text.split(separator: "\n").filter { $0.hasPrefix("import ") }.map { String($0.dropFirst(7)) }
            #expect(Set(imports).isSubset(of: ["Foundation", "IOKit", "IOKit.ps"]), "\(file.lastPathComponent) imports \(imports)")
            for name in ["IOBluetooth", "CoreBluetooth", "CBCentralManager", "CBPeripheral"] {
                #expect(!text.contains(name), "\(file.lastPathComponent) names \(name)")
            }
        }
    }

    // MARK: Parsing the registry

    /// The keys and values this Mac's `ioreg -rn AppleSmartBattery` printed on 2026-10-07.
    private static var thisMac: [String: Any] { [
        "BatteryInstalled": true, "DesignCapacity": 8_694, "AppleRawMaxCapacity": 6_830, "MaxCapacity": 100,
        "CycleCount": 721, "Temperature": 3_048, "VirtualTemperature": 3_159, "IsCharging": false,
        "ExternalConnected": true, "TimeRemaining": 65_535,
    ] }

    private static func registry(_ change: (inout [String: Any]) -> Void) -> [String: Any] {
        var copy = thisMac
        change(&copy)
        return copy
    }

    @Test func theRawMaxCapacityIsUsedAndAPercentMaxCapacityIsNeverTakenForMilliampHours() throws {
        let battery = try #require(IOKitBatteryHealthPort.battery(registry: Self.thisMac))
        #expect(battery.designCapacity == 8_694)
        #expect(battery.maxCapacity == 6_830, "MaxCapacity is 100, a percent on Apple silicon")
        #expect(battery.cycleCount == 721)
        #expect(battery.isCharging == false)
        #expect(battery.isExternalPowerConnected == true)

        let intel = try #require(IOKitBatteryHealthPort.battery(registry: Self.registry {
            $0["AppleRawMaxCapacity"] = nil
            $0["MaxCapacity"] = 4_100
        }))
        #expect(intel.maxCapacity == 4_100, "without the raw figure, a MaxCapacity in mAh is used")

        let percentOnly = try #require(IOKitBatteryHealthPort.battery(registry: Self.registry { $0["AppleRawMaxCapacity"] = nil }))
        #expect(percentOnly.maxCapacity == nil, "a MaxCapacity of 100 or less is a percent, so health is unknown, not 1%")
    }

    /// Apple's AppleSmartBattery.cpp: "OSX historically uses SmartBattery format directly" for Temperature, which the
    /// Smart Battery Data Specification gives in tenths of a kelvin; VirtualTemperature on Apple silicon is published
    /// in hundredths of a degree Celsius. On this Mac 3048 (31.65 °C) sat beside a VirtualTemperature of 3159
    /// (31.59 °C); read as hundredths of a degree it would have been 30.48 °C.
    @Test func temperatureIsReadAsTenthsOfAKelvin() throws {
        let celsius = try #require(IOKitBatteryHealthPort.battery(registry: Self.thisMac)?.temperatureCelsius)
        #expect(abs(celsius - 31.65) < 0.001)
        #expect(IOKitBatteryHealthPort.battery(registry: Self.registry { $0["Temperature"] = 0 })?.temperatureCelsius == nil)
        #expect(IOKitBatteryHealthPort.battery(registry: Self.registry { $0["Temperature"] = nil })?.temperatureCelsius == nil)
    }

    @Test func timeRemainingOf65535MeansStillEstimating() {
        #expect(IOKitBatteryHealthPort.battery(registry: Self.thisMac)?.minutesRemaining == nil)
        #expect(IOKitBatteryHealthPort.battery(registry: Self.registry { $0["TimeRemaining"] = 200 })?.minutesRemaining == 200)
        #expect(IOKitBatteryHealthPort.battery(registry: Self.registry { $0["TimeRemaining"] = 0 })?.minutesRemaining == nil)
    }

    @Test func aBatteryThatIsNotInstalledIsNoBatteryAndMissingKeysAreNil() throws {
        #expect(IOKitBatteryHealthPort.battery(registry: Self.registry { $0["BatteryInstalled"] = false }) == nil)
        let bare = try #require(IOKitBatteryHealthPort.battery(registry: [:]))
        #expect(bare == MacBatteryReading(
            designCapacity: nil, maxCapacity: nil, cycleCount: nil, temperatureCelsius: nil,
            isCharging: nil, isExternalPowerConnected: nil, minutesRemaining: nil
        ))
    }

    @Test func otherPowerSourcesListAUPSButNeverTheInternalBattery() {
        let ups: [String: Any] = ["Type": "UPS", "Name": "Back-UPS 700", "Current Capacity": 37, "Max Capacity": 50, "Power Source ID": 7]
        #expect(IOKitBatteryHealthPort.device(powerSource: ups) == DeviceBattery(id: "power-source-7", name: "Back-UPS 700", percent: 74))
        let internalBattery: [String: Any] = ["Type": "InternalBattery", "Name": "InternalBattery-0", "Current Capacity": 100, "Max Capacity": 100]
        #expect(IOKitBatteryHealthPort.device(powerSource: internalBattery) == nil)
        #expect(IOKitBatteryHealthPort.device(powerSource: ["Type": "UPS", "Name": "Broken", "Current Capacity": 5, "Max Capacity": 0]) == nil)
    }

    @Test func aPeripheralListedBothWaysIsShownOnce() {
        let keyboard = DeviceBattery(id: "20-91-df-e7-52-3d", name: "Magic Keyboard", percent: 74)
        let fromPowerSources = [
            DeviceBattery(id: "power-source-9", name: "magic keyboard", percent: 74),
            DeviceBattery(id: "power-source-7", name: "Back-UPS 700", percent: 74),
        ]
        #expect(IOKitBatteryHealthPort.merge(peripherals: [keyboard], powerSources: fromPowerSources).map(\.id) == [
            "20-91-df-e7-52-3d", "power-source-7",
        ])
    }
}
