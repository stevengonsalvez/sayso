import Foundation

/// Cost-to-miss ordering: a higher raw value outranks a lower one.
public enum SaysoActivityKind: Int, Comparable, CaseIterable, Sendable {
    /// Glanceable status that costs nothing to miss, such as a clock; shown only when nothing else is.
    case background = -2
    /// Live media status, such as the playing track: outranks a clock, yields to every ambient offer.
    case media = -1
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
    /// Fraction 0...1, clamped; nil when unknown or not applicable.
    public let progress: Double?

    public init(
        moduleID: String,
        stackID: String,
        kind: SaysoActivityKind,
        title: String,
        expiresAfter: TimeInterval? = nil,
        actions: [SaysoAction] = [],
        interruption: SaysoInterruptionPolicy = .normal,
        progress: Double? = nil
    ) {
        self.moduleID = moduleID
        self.stackID = stackID
        self.kind = kind
        self.title = title
        self.expiresAfter = expiresAfter
        self.actions = actions
        self.interruption = interruption
        self.progress = progress.flatMap { $0.isNaN ? nil : min(max($0, 0), 1) }
    }
}
