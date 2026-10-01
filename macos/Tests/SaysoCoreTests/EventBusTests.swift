import Foundation
import Testing
@testable import SaysoCore

private struct TranscriptCompleted: SaysoEvent { let text: String }
private struct ClipboardChanged: SaysoEvent { let text: String }

private final class Seen: @unchecked Sendable { var values: [String] = [] }

@Test func eventsReachOnlyMatchingSubscribersInPublishOrderUntilCancelled() {
    let bus = SaysoEventBus()
    let seen = Seen()
    let subscription = bus.subscribe(TranscriptCompleted.self) { seen.values.append("t:" + $0.text) }
    _ = bus.subscribe(ClipboardChanged.self) { seen.values.append("c:" + $0.text) }

    bus.publish(TranscriptCompleted(text: "a"))
    bus.publish(ClipboardChanged(text: "b"))
    bus.publish(TranscriptCompleted(text: "c"))
    #expect(seen.values == ["t:a", "c:b", "t:c"])

    subscription.cancel()
    subscription.cancel()
    bus.publish(TranscriptCompleted(text: "d"))
    #expect(seen.values == ["t:a", "c:b", "t:c"])
    #expect(bus.subscriberCount == 1)
}

@Test func handlersMayPublishFurtherEventsWithoutDeadlockAndStayOrdered() {
    let bus = SaysoEventBus()
    let seen = Seen()
    _ = bus.subscribe(TranscriptCompleted.self) {
        seen.values.append("t:" + $0.text)
        bus.publish(ClipboardChanged(text: $0.text))
    }
    _ = bus.subscribe(ClipboardChanged.self) { seen.values.append("c:" + $0.text) }

    bus.publish(TranscriptCompleted(text: "x"))
    #expect(seen.values == ["t:x", "c:x"])
}
