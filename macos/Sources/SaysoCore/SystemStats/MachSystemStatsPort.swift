#if os(macOS)
import Darwin
import Foundation
import IOKit.ps

/// Reads this Mac through public interfaces only, never a private framework or a shelled-out tool: Mach host
/// statistics for CPU ticks and memory, the kernel's memory pressure level through sysctl, IOKit power sources for
/// the battery and URL resource values for disk space. `read()` takes about a millisecond; `diskFreeBytes()` asks
/// the file system for purgeable space and was measured at 28 to 569 ms. Call both off the main thread.
public struct MachSystemStatsPort: SystemStatsPort {
    /// Taken once: every `mach_host_self()` call adds a reference to the host port that would otherwise need
    /// releasing, and a per-sample leak would overflow its reference count over days.
    private static let host = mach_host_self()
    private let volumePath: String

    public init(volumePath: String = "/") { self.volumePath = volumePath }

    public func read() throws(SystemStatsPortError) -> SystemStatsReading {
        guard let ticks = Self.cpuTicks() else { throw .unavailable }
        let battery = Self.battery()
        return SystemStatsReading(
            cpuTicks: ticks,
            memoryUsedFraction: Self.memoryUsedFraction(),
            memoryPressure: Self.memoryPressure(),
            batteryFraction: battery?.fraction,
            isPluggedIn: battery?.isPluggedIn
        )
    }

    /// Ticks since boot for all cores together.
    static func cpuTicks() -> SystemCPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        // Indexed by CPU_STATE_USER, CPU_STATE_SYSTEM, CPU_STATE_IDLE, CPU_STATE_NICE.
        return SystemCPUTicks(user: ticks.0, system: ticks.1, idle: ticks.2, nice: ticks.3)
    }

    /// What Activity Monitor calls Memory Used: app memory (anonymous pages less purgeable ones), wired and
    /// compressed, over physical memory. Cached files are not counted, since macOS gives them up on demand.
    static func memoryUsedFraction() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        let physical = Double(ProcessInfo.processInfo.physicalMemory)
        guard physical > 0 else { return nil }
        let anonymous = UInt64(stats.internal_page_count)
        let app = anonymous - min(UInt64(stats.purgeable_count), anonymous)
        let pages = app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return Double(pages) * Double(pageSize) / physical
    }

    /// The level the kernel hands to memory pressure dispatch sources: 1 normal, 2 warning, 4 critical.
    static func memoryPressure() -> SystemMemoryPressure? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        switch level {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return nil
        }
    }

    /// The internal battery's level and whether external power is connected; nil on a Mac without one.
    static func battery() -> (fraction: Double, isPluggedIn: Bool?)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  description[kIOPSIsPresentKey] as? Bool != false,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
            else { continue }
            let state = description[kIOPSPowerSourceStateKey] as? String
            return (Double(current) / Double(maximum), state.map { $0 == kIOPSACPowerValue })
        }
        return nil
    }

    /// A fresh URL per read: resource values are cached on the URL object, and a queue without a run loop
    /// would never see that cache cleared.
    public func diskFreeBytes() -> Int64? {
        let values = try? URL(fileURLWithPath: volumePath).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
#endif
