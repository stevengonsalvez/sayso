import Foundation
import Testing
@testable import SaysoCore

@Test func userPinBeatsAutomationExceptCriticalConfirmation() {
    var engine = SaysoActivityEngine()
    engine.publish(SaysoActivity(moduleID: "media", stackID: "now-playing", kind: .ambient, title: "Song"))
    engine.pin(moduleID: "media", stackID: "now-playing")

    engine.publish(SaysoActivity(moduleID: "dictation", stackID: "run", kind: .failure, title: "Mic lost"))
    #expect(engine.primary?.title == "Song")

    engine.publish(SaysoActivity(moduleID: "control", stackID: "ask", kind: .confirmation, title: "Delete?", interruption: .critical))
    #expect(engine.primary?.title == "Delete?")

    engine.dismiss(moduleID: "control", stackID: "ask")
    #expect(engine.primary?.title == "Song")

    engine.unpin()
    #expect(engine.primary?.title == "Mic lost")
}
