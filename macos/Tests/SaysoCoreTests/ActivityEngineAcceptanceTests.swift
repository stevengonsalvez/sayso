import Foundation
import Testing
@testable import SaysoCore

@Test func sameModuleAndStackReplacesInPlaceAndRanksByCostToMiss() {
    var engine = SaysoActivityEngine()

    engine.publish(SaysoActivity(moduleID: "media", stackID: "now-playing", kind: .ambient, title: "Song A"))
    engine.publish(SaysoActivity(moduleID: "timer", stackID: "focus", kind: .activeTask, title: "Focus 24:00"))
    engine.publish(SaysoActivity(moduleID: "media", stackID: "now-playing", kind: .ambient, title: "Song B"))

    #expect(engine.stack.map(\.title) == ["Focus 24:00", "Song B"])

    engine.publish(SaysoActivity(moduleID: "files", stackID: "copy", kind: .completion, title: "Copied"))
    engine.publish(SaysoActivity(moduleID: "control", stackID: "ask", kind: .confirmation, title: "Delete?"))
    engine.publish(SaysoActivity(moduleID: "dictation", stackID: "run", kind: .failure, title: "Mic lost"))

    #expect(engine.stack.map(\.kind) == [.confirmation, .failure, .completion, .activeTask, .ambient])
    #expect(engine.primary?.title == "Delete?")
}
