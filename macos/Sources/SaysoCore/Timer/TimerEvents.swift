import Foundation

/// Emitted at a moment the user should notice, so a sound or haptic can follow without the timer
/// knowing how it is played.
public struct TimerPing: SaysoEvent, Equatable {
    public enum Reason: Equatable, Sendable {
        case finished
    }

    public let timerID: TimerID
    public let reason: Reason

    public init(timerID: TimerID, reason: Reason) {
        self.timerID = timerID
        self.reason = reason
    }
}
