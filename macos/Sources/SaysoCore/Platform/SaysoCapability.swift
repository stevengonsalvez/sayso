import Foundation

public enum SaysoCapability: String, CaseIterable, Sendable {
    case clipboard, files, microphone, accessibility, camera, calendar, notifications
    case automation, shell, network, fullDiskAccess, experimentalSystem
}
