#if os(macOS)
import Foundation
import IOKit
import IOKit.ps

/// Reads batteries through public IOKit only: the `AppleSmartBattery` registry entry for this Mac's battery,
/// `IOPSCopyPowerSourcesInfo` for other power sources such as a UPS, and the `BatteryPercent` registry property that
/// macOS publishes for some Bluetooth peripherals (Apple keyboards, mice and trackpads). No Bluetooth API is used, so
/// no permission is asked for; peripherals that macOS does not publish this way (AirPods, most third-party devices)
/// are not listed. Measured on this Mac: the battery read about 0.8 ms, the peripheral scan about 1.8 ms (medians).
public struct IOKitBatteryHealthPort: BatteryHealthPort {
    public init() {}

    public func read() throws(BatteryHealthPortError) -> BatteryHealthReading {
        BatteryHealthReading(
            battery: try Self.internalBattery(),
            devices: Self.merge(peripherals: Self.peripherals(), powerSources: Self.powerSources())
        )
    }

    /// Nil when the Mac has no battery entry; throws when there is one but its properties cannot be read.
    static func internalBattery() throws(BatteryHealthPortError) -> MacBatteryReading? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let registry = properties?.takeRetainedValue() as? [String: Any]
        else { throw .unavailable }
        return battery(registry: registry)
    }

    /// Nil when the registry says no battery is installed.
    static func battery(registry: [String: Any]) -> MacBatteryReading? {
        if registry["BatteryInstalled"] as? Bool == false { return nil }
        // Apple silicon publishes MaxCapacity as a percent (100) and the capacity in mAh as AppleRawMaxCapacity;
        // older Macs give mAh in MaxCapacity. A value of 100 or less is never taken for mAh.
        let raw = (registry["AppleRawMaxCapacity"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        let legacy = (registry["MaxCapacity"] as? Int).flatMap { $0 > 100 ? $0 : nil }
        // Tenths of a kelvin: AppleSmartBattery.cpp publishes the Smart Battery format unchanged on macOS. A raw zero
        // means no reading.
        let temperature = (registry["Temperature"] as? Int).flatMap { $0 > 0 ? Double($0) / 10 - 273.15 : nil }
        // 65535 means the system is still estimating.
        let minutes = (registry["TimeRemaining"] as? Int).flatMap { (1..<65_535).contains($0) ? $0 : nil }
        return MacBatteryReading(
            designCapacity: registry["DesignCapacity"] as? Int,
            maxCapacity: raw ?? legacy,
            cycleCount: registry["CycleCount"] as? Int,
            temperatureCelsius: temperature,
            isCharging: registry["IsCharging"] as? Bool,
            isExternalPowerConnected: registry["ExternalConnected"] as? Bool,
            minutesRemaining: minutes
        )
    }

    /// Every power source except this Mac's own battery, such as a UPS.
    static func powerSources() -> [DeviceBattery] {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return [] }
        return sources.compactMap { source in
            (IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]).flatMap(device(powerSource:))
        }
    }

    static func device(powerSource description: [String: Any]) -> DeviceBattery? {
        guard description[kIOPSTypeKey] as? String != kIOPSInternalBatteryType,
              let name = description[kIOPSNameKey] as? String,
              let current = description[kIOPSCurrentCapacityKey] as? Int,
              let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
        else { return nil }
        let id = (description[kIOPSPowerSourceIDKey] as? Int).map { "power-source-\($0)" } ?? "power-source-\(name)"
        let percent = Int((min(max(Double(current) / Double(maximum), 0), 1) * 100).rounded())
        return DeviceBattery(id: id, name: name, percent: percent)
    }

    /// Registry entries that carry `BatteryPercent`, one per Bluetooth address. A failed scan lists none rather than
    /// failing the whole read, so this Mac's own battery still shows.
    static func peripherals() -> [DeviceBattery] {
        var iterator: io_iterator_t = IO_OBJECT_NULL
        let matching = [kIOPropertyExistsMatchKey: "BatteryPercent"] as CFDictionary
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var devices: [DeviceBattery] = []
        while case let entry = IOIteratorNext(iterator), entry != IO_OBJECT_NULL {
            defer { IOObjectRelease(entry) }
            guard let percent = property(entry, "BatteryPercent") as? Int else { continue }
            let address = property(entry, "DeviceAddress") as? String
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(entry, &entryID)
            let id = address ?? "registry-\(entryID)"
            guard !devices.contains(where: { $0.id == id }) else { continue }
            let name = IORegistryEntrySearchCFProperty(
                entry, kIOServicePlane, "Product" as CFString, kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            ) as? String
            devices.append(DeviceBattery(id: id, name: name ?? "", percent: min(max(percent, 0), 100)))
        }
        return devices
    }

    /// Peripherals first; a power source with the same name as a listed peripheral is the same device seen twice.
    static func merge(peripherals: [DeviceBattery], powerSources: [DeviceBattery]) -> [DeviceBattery] {
        let names = Set(peripherals.map { $0.name.lowercased() })
        return peripherals + powerSources.filter { !names.contains($0.name.lowercased()) }
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
#endif
