import Foundation

/// Cost-to-miss ordering: a higher raw value outranks a lower one.
public enum SaysoActivityKind: Int, Comparable, Sendable {
    case ambient = 0
    case activeTask
    case completion
    case failure
    case confirmation

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Only a critical activity may break through a user pin.
public enum SaysoInterruptionPolicy: Sendable {
    case normal
    case critical
}

public struct SaysoActivity: Equatable, Sendable {
    public let moduleID: String
    public let stackID: String
    public let kind: SaysoActivityKind
    public let title: String
    /// Seconds after publish when the activity disappears; nil means persistent.
    public let expiresAfter: TimeInterval?
    public let actions: [SaysoAction]
    public let interruption: SaysoInterruptionPolicy

    public init(
        moduleID: String,
        stackID: String,
        kind: SaysoActivityKind,
        title: String,
        expiresAfter: TimeInterval? = nil,
        actions: [SaysoAction] = [],
        interruption: SaysoInterruptionPolicy = .normal
    ) {
        self.moduleID = moduleID
        self.stackID = stackID
        self.kind = kind
        self.title = title
        self.expiresAfter = expiresAfter
        self.actions = actions
        self.interruption = interruption
    }
}
