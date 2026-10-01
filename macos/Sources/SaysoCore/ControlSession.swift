import Foundation

public struct JevControlRunState: Equatable, Sendable {
    public let goal: String
    public private(set) var recentActions: [JevCycleRecentAction]

    public init(goal: String, recentActions: [JevCycleRecentAction] = []) throws {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SaysoError.invalidAction("Say a control command.") }
        self.goal = trimmed
        self.recentActions = Array(recentActions.suffix(10))
    }

    public mutating func record(action: String, result: String, screenChanged: Bool) {
        recentActions.append(.init(action: action, result: result, screenChanged: screenChanged))
        if recentActions.count > 10 { recentActions.removeFirst(recentActions.count - 10) }
    }
}

/// A pending "Which one" question may only absorb a prompt, short reply that names an offered choice.
/// Anything else is a new command, so one low-confidence plan can never swallow later commands.
public enum ControlClarification {
    public static let maximumAge: TimeInterval = 60
    private static let maximumReplyWords = 4
    private static let ordinals = [
        ["1", "one", "first"], ["2", "two", "second"], ["3", "three", "third"]
    ]

    /// `choices` use the "1: Calculator" form produced by `JevControlBridge.cycleAlternatives`.
    public static func isAnswer(_ reply: String, to choices: [String], askedAt: Date, now: Date = Date()) -> Bool {
        guard now.timeIntervalSince(askedAt) <= maximumAge else { return false }
        let words = normalizedWords(reply)
        guard !words.isEmpty, words.count <= maximumReplyWords else { return false }
        let phrase = " \(words.joined(separator: " ")) "
        return choices.enumerated().contains { index, choice in
            let label = normalizedWords(String(choice.split(separator: ":", maxSplits: 1).last ?? ""))
            let namesLabel = !label.isEmpty && phrase.contains(" \(label.joined(separator: " ")) ")
            return namesLabel || (index < ordinals.count && !Set(words).isDisjoint(with: ordinals[index]))
        }
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

public struct ControlSessionLimits: Codable, Equatable, Sendable {
    public let maxActions: Int
    public let maxConsecutiveNoEffect: Int

    public init(maxActions: Int = 12, maxConsecutiveNoEffect: Int = 2) {
        self.maxActions = max(1, maxActions)
        self.maxConsecutiveNoEffect = max(1, maxConsecutiveNoEffect)
    }
}

public enum ControlSessionPhase: String, Codable, Equatable, Sendable {
    case idle
    case running
    case finished
}

public enum ControlSessionResult: String, Codable, Equatable, Sendable {
    case completed
    case cancelled
    case failed
    case actionBudgetExhausted
    case noEffectBudgetExhausted
}

public enum ControlSessionStepResult: String, Codable, Equatable, Sendable {
    case effectObserved
    case noEffectObserved
    /// Action ran but its effect could not be attributed either way.
    case effectUnknown
    case actionFailed

    public init(_ effect: ControlEffect) {
        self = switch effect {
        case .observed, .alreadySatisfied: .effectObserved
        case .notObserved: .noEffectObserved
        case .unknown: .effectUnknown
        }
    }
}

public struct ControlSessionState: Codable, Equatable, Sendable {
    public let phase: ControlSessionPhase
    public let result: ControlSessionResult?
    public let actionCount: Int
    public let consecutiveNoEffectCount: Int
    public let limits: ControlSessionLimits

    public var canRunAction: Bool { phase == .running }
}

public actor ControlSession {
    private let limits: ControlSessionLimits
    private var phase: ControlSessionPhase = .idle
    private var result: ControlSessionResult?
    private var actionCount = 0
    private var consecutiveNoEffectCount = 0

    public init(limits: ControlSessionLimits = .init()) {
        self.limits = limits
    }

    @discardableResult
    public func start() -> ControlSessionState {
        guard phase == .idle else { return state() }
        return beginCommand()
    }

    /// Starts a deliberately new user command with its own bounded action budget.
    /// Unlike `start()`, this is the only explicit path that may replace a terminal session.
    @discardableResult
    public func beginCommand() -> ControlSessionState {
        phase = .running
        result = nil
        actionCount = 0
        consecutiveNoEffectCount = 0
        return state()
    }

    @discardableResult
    public func record(_ stepResult: ControlSessionStepResult) -> ControlSessionState {
        guard phase == .running else { return state() }

        actionCount += 1
        switch stepResult {
        case .effectObserved:
            consecutiveNoEffectCount = 0
        case .noEffectObserved:
            consecutiveNoEffectCount += 1
        case .effectUnknown, .actionFailed:
            break
        }

        if consecutiveNoEffectCount >= limits.maxConsecutiveNoEffect {
            finish(.noEffectBudgetExhausted)
        } else if actionCount >= limits.maxActions {
            finish(.actionBudgetExhausted)
        }
        return state()
    }

    @discardableResult
    public func cancel() -> ControlSessionState {
        guard phase == .running else { return state() }
        finish(.cancelled)
        return state()
    }

    @discardableResult
    public func fail() -> ControlSessionState {
        guard phase == .running else { return state() }
        finish(.failed)
        return state()
    }

    @discardableResult
    public func complete() -> ControlSessionState {
        guard phase == .running else { return state() }
        finish(.completed)
        return state()
    }

    public func currentState() -> ControlSessionState {
        state()
    }

    private func finish(_ result: ControlSessionResult) {
        phase = .finished
        self.result = result
    }

    private func state() -> ControlSessionState {
        .init(
            phase: phase,
            result: result,
            actionCount: actionCount,
            consecutiveNoEffectCount: consecutiveNoEffectCount,
            limits: limits
        )
    }
}
