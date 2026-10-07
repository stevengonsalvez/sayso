import Foundation

public enum PrivacyDeviceKind: String, CaseIterable, Sendable {
    case microphone
    case camera
}

/// One input device as the system lists it. `isRunning` says only that some process has the device switched on;
/// the system does not say which, and nothing here tries to find out.
public struct PrivacyDevice: Equatable, Sendable {
    /// Stable for as long as the device stays connected; unique within its kind.
    public var id: String
    public var name: String
    public var kind: PrivacyDeviceKind
    public var isRunning: Bool

    public init(id: String, name: String, kind: PrivacyDeviceKind, isRunning: Bool) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isRunning = isRunning
    }
}

public enum PrivacyDevicePortError: Error, Equatable, Sendable {
    /// The system would not list its devices.
    case unavailable
}

/// Boundary to the system's device lists. An adapter only reads public device properties: it never opens, records or
/// samples a device, so it needs no Microphone or Camera permission.
public protocol PrivacyDevicePort: Sendable {
    /// Every input-capable audio device and every video device, each with whether any process has it on now.
    func devices() throws(PrivacyDevicePortError) -> [PrivacyDevice]
}
