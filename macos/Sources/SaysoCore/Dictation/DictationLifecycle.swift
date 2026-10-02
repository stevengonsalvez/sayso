import Foundation

public enum DictationLifecycleEvent: SaysoEvent, Equatable {
    public enum Ending: Equatable, Sendable { case finished, cancelled, failed }
    case listening
    case processing
    case ended(Ending)
}

/// Turns raw `SessionPhase` changes into one lifecycle event per transition, hiding repeats and idle-at-rest.
public struct DictationPhaseTracker: Sendable {
    private enum State { case none, requesting, listening, processing }
    private var state = State.none

    public init() {}

    public mutating func observe(_ phase: SessionPhase) -> [DictationLifecycleEvent] {
        switch phase {
        case .requestingPermission:
            if state == .none { state = .requesting }
            return []
        case .listening:
            guard state != .listening else { return [] }
            state = .listening
            return [.listening]
        case .processing:
            guard state != .processing else { return [] }
            state = .processing
            return [.processing]
        case .idle:
            defer { state = .none }
            switch state {
            case .processing: return [.ended(.finished)]
            case .listening, .requesting: return [.ended(.cancelled)]
            case .none: return []
            }
        case .failed:
            defer { state = .none }
            return state == .none ? [] : [.ended(.failed)]
        case .speaking:
            return []
        }
    }
}
