import Combine
import Foundation
import Testing
@testable import SaysoCore

private final class Seen: @unchecked Sendable { var events: [DictationLifecycleEvent] = [] }

@Test func phaseChangesBecomeLifecycleEventsOnTheBusUntilTheBridgeIsReleased() {
    let subject = PassthroughSubject<SessionPhase, Never>()
    let bus = SaysoEventBus(), seen = Seen()
    _ = bus.subscribe(DictationLifecycleEvent.self) { seen.events.append($0) }
    var bridge: DictationPhaseBridge? = DictationPhaseBridge(phases: subject.eraseToAnyPublisher(), bus: bus)

    subject.send(.listening)
    subject.send(.processing)
    subject.send(.idle)
    #expect(seen.events == [.listening, .processing, .ended(.finished)])

    bridge = nil
    subject.send(.listening)
    #expect(seen.events.count == 3)
    _ = bridge
}
