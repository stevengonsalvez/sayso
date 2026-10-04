import Foundation
import Testing
@testable import SaysoCore

@Test func onlyCriticalActivitiesInterruptAPin() {
    var engine = SaysoActivityEngine()
    engine.publish(SaysoActivity(moduleID: "media", stackID: "np", kind: .ambient, title: "Song"))
    engine.pin(moduleID: "media", stackID: "np")

    engine.publish(SaysoActivity(moduleID: "notes", stackID: "save", kind: .confirmation, title: "Save?"))
    #expect(engine.primary?.title == "Song")

    engine.publish(SaysoActivity(
        moduleID: "control", stackID: "ask", kind: .confirmation, title: "Delete?", interruption: .critical
    ))
    #expect(engine.primary?.title == "Delete?")
}
