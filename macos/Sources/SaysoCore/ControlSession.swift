import Foundation

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
        case .observed: .effectObserved
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
