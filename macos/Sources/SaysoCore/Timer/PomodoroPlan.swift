import Foundation

public enum TimerPhase: Equatable, Sendable {
    case focus, shortBreak, longBreak

    var title: String {
        switch self {
        case .focus: "Focus"
        case .shortBreak: "Short break"
        case .longBreak: "Long break"
        }
    }
}

/// Phase lengths of a Pomodoro cycle: focus, then a short break, with a long break after every Nth focus.
public struct PomodoroPlan: Equatable, Sendable {
    public static let standard = PomodoroPlan(focus: 25 * 60, shortBreak: 5 * 60, longBreak: 15 * 60, longBreakEvery: 4)

    public let focus: TimeInterval
    public let shortBreak: TimeInterval
    public let longBreak: TimeInterval
    public let longBreakEvery: Int

    /// Phases shorter than a second and a long-break interval below one are raised to those minimums,
    /// so a phase can never end the moment it starts.
    public init(focus: TimeInterval, shortBreak: TimeInterval, longBreak: TimeInterval, longBreakEvery: Int) {
        self.focus = Self.atLeastOneSecond(focus)
        self.shortBreak = Self.atLeastOneSecond(shortBreak)
        self.longBreak = Self.atLeastOneSecond(longBreak)
        self.longBreakEvery = max(1, longBreakEvery)
    }

    func duration(of phase: TimerPhase) -> TimeInterval {
        switch phase {
        case .focus: focus
        case .shortBreak: shortBreak
        case .longBreak: longBreak
        }
    }

    /// The phase after `phase`, given how many focus sessions are complete once it ends.
    func phase(after phase: TimerPhase, completedFocusSessions: Int) -> TimerPhase {
        guard phase == .focus else { return .focus }
        return completedFocusSessions % longBreakEvery == 0 ? .longBreak : .shortBreak
    }

    private static func atLeastOneSecond(_ seconds: TimeInterval) -> TimeInterval {
        seconds.isFinite ? max(1, seconds) : 1
    }
}
