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

public struct SaysoActivity: Equatable, Sendable {
    public let moduleID: String
    public let stackID: String
    public let kind: SaysoActivityKind
    public let title: String
    /// Seconds after publish when the activity disappears; nil means persistent.
    public let expiresAfter: TimeInterval?

    public init(
        moduleID: String,
        stackID: String,
        kind: SaysoActivityKind,
        title: String,
        expiresAfter: TimeInterval? = nil
    ) {
        self.moduleID = moduleID
        self.stackID = stackID
        self.kind = kind
        self.title = title
        self.expiresAfter = expiresAfter
    }
}
