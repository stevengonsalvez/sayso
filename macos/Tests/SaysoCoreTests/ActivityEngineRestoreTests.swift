import Foundation
import Testing
@testable import SaysoCore

@Test func expiringAlertOnSameStackRestoresThePersistentActivityItShadowed() {
    let t0 = Date(timeIntervalSince1970: 1_000)
    var engine = SaysoActivityEngine()
    engine.publish(SaysoActivity(moduleID: "timer", stackID: "main", kind: .activeTask, title: "Focus"), at: t0)
    engine.publish(
        SaysoActivity(moduleID: "timer", stackID: "main", kind: .completion, title: "Done", expiresAfter: 3),
        at: t0
    )
    #expect(engine.stack.map(\.title) == ["Done"])

    engine.tick(at: t0.addingTimeInterval(3))
    #expect(engine.stack.map(\.title) == ["Focus"])
}

@Test func pinIsClearedWhenItsTargetLeavesTheStack() {
    var engine = SaysoActivityEngine()
    engine.publish(SaysoActivity(moduleID: "media", stackID: "np", kind: .ambient, title: "Song"))
    engine.pin(moduleID: "media", stackID: "np")
    engine.dismiss(moduleID: "media", stackID: "np")

    engine.publish(SaysoActivity(moduleID: "dictation", stackID: "run", kind: .failure, title: "Mic lost"))
    engine.publish(SaysoActivity(moduleID: "media", stackID: "np", kind: .ambient, title: "Song"))
    #expect(engine.primary?.title == "Mic lost")
}

@Test func pinnedConfirmationWinsOverAnEarlierConfirmation() {
    var engine = SaysoActivityEngine()
    engine.publish(SaysoActivity(moduleID: "a", stackID: "q", kind: .confirmation, title: "A?"))
    engine.publish(SaysoActivity(moduleID: "b", stackID: "q", kind: .confirmation, title: "B?"))
    engine.pin(moduleID: "b", stackID: "q")
    #expect(engine.primary?.title == "B?")
}
