import Foundation
import Testing
@testable import SaysoCore

@Test func temporaryAlertOutranksThenExpiresAndRestoresPreviousPrimary() {
    let t0 = Date(timeIntervalSince1970: 1_000)
    var engine = SaysoActivityEngine()
    engine.publish(SaysoActivity(moduleID: "timer", stackID: "focus", kind: .activeTask, title: "Focus"), at: t0)
    engine.publish(
        SaysoActivity(moduleID: "files", stackID: "copy", kind: .completion, title: "Copied", expiresAfter: 3),
        at: t0
    )

    #expect(engine.primary?.title == "Copied")

    engine.tick(at: t0.addingTimeInterval(2.9))
    #expect(engine.primary?.title == "Copied")

    engine.tick(at: t0.addingTimeInterval(3))
    #expect(engine.primary?.title == "Focus")
    #expect(engine.stack.map(\.title) == ["Focus"])
}
