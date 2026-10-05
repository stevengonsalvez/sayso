#if os(macOS)
import Foundation
import IOKit.pwr_mgt

/// Keeps the display, and so the Mac, from idle sleep through a named IOKit power assertion.
/// The system drops a process's assertions when it exits, so a crash cannot leave the Mac awake.
public struct IOPMAssertionPort: PowerAssertionPort {
    public init() {}

    public func createAssertion(named name: String) -> PowerAssertion? {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &id
        )
        guard result == kIOReturnSuccess else { return nil }
        let held = id
        return PowerAssertion { IOPMAssertionRelease(held) }
    }
}
#endif
