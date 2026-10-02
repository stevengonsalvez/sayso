import Foundation

/// Turns model manager state snapshots into install events; the app feeds it from the managers' published state.
public final class ModelInstallReporter: @unchecked Sendable {
    public enum Phase: Equatable, Sendable { case idle, installing, installed, failed }

    private struct Track { var phase: Phase = .idle; var fraction: Double? }

    private let bus: SaysoEventBus
    private let lock = NSLock()
    private var tracks: [String: Track] = [:]

    public init(bus: SaysoEventBus) { self.bus = bus }

    public func observe(modelID: String, displayName: String, phase: Phase, fraction: Double?) {
        enum Outcome { case progress, finished(Bool), cancelled, nothing }
        // Whole percents only, so tiny fraction changes do not flood observers.
        let fraction = fraction.map { ($0 * 100).rounded() / 100 }
        let outcome = lock.withLock { () -> Outcome in
            var track = tracks[modelID] ?? Track()
            defer { tracks[modelID] = track }
            switch phase {
            case .installing:
                let changed = track.phase != .installing || track.fraction != fraction
                track.phase = .installing
                track.fraction = fraction
                return changed ? .progress : .nothing
            case .installed, .failed:
                let wasInstalling = track.phase == .installing
                track.phase = phase
                track.fraction = nil
                return wasInstalling ? .finished(phase == .installed) : .nothing
            case .idle:
                let wasInstalling = track.phase == .installing
                track.phase = .idle
                track.fraction = nil
                return wasInstalling ? .cancelled : .nothing
            }
        }
        switch outcome {
        case .progress: bus.publish(ModelInstallProgress(modelID: modelID, displayName: displayName, fraction: fraction))
        case .finished(let ok): bus.publish(ModelInstallFinished(modelID: modelID, displayName: displayName, succeeded: ok))
        case .cancelled: bus.publish(ModelInstallCancelled(modelID: modelID))
        case .nothing: break
        }
    }
}
