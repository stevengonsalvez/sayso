import Foundation

/// What one kind of device is doing, after the module's debounce.
public enum PrivacyDeviceUse: Equatable, Sendable {
    case inUse
    case notInUse
    case noneFound

    public var text: String {
        switch self {
        case .inUse: "In use"
        case .notInUse: "Not in use"
        case .noneFound: "None found"
        }
    }
}

/// The last successful read, for the Studio pane.
public struct PrivacyGuardSnapshot: Equatable, Sendable {
    public let microphone: PrivacyDeviceUse
    public let camera: PrivacyDeviceUse
    public let sampledAt: Date

    public init(microphone: PrivacyDeviceUse, camera: PrivacyDeviceUse, sampledAt: Date) {
        self.microphone = microphone
        self.camera = camera
        self.sampledAt = sampledAt
    }
}
