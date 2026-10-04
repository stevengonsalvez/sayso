import Combine
import Foundation

/// Publishes dictation lifecycle events for every session phase change until released.
public final class DictationPhaseBridge {
    private var tracker = DictationPhaseTracker()
    private var cancellable: AnyCancellable?

    public init(phases: AnyPublisher<SessionPhase, Never>, bus: SaysoEventBus) {
        cancellable = phases.sink { [weak self] phase in
            guard let self else { return }
            for event in self.tracker.observe(phase) { bus.publish(event) }
        }
    }
}
