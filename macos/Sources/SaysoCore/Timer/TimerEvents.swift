import Foundation

/// Emitted at a moment the user should notice, so a sound or haptic can follow without the timer
/// knowing how it is played.
public struct TimerPing: SaysoEvent, Equatable {
    public let timerID: TimerID

    public init(timerID: TimerID) {
        self.timerID = timerID
    }
}
