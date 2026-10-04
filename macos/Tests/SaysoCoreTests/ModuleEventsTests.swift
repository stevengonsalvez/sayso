import Foundation
import Testing
@testable import SaysoCore

private struct ProbeTranscript: SaysoEvent { let text: String }

private final class Inbox: @unchecked Sendable { var received: [String] = [] }
private final class Slots: @unchecked Sendable { var contexts: [String: SaysoModuleContext] = [:] }

private final class Quiet: SaysoModuleRuntime, @unchecked Sendable {
    func start() {}
    func stop() {}
}

private struct Listener: SaysoModule {
    let descriptor = SaysoModuleDescriptor(id: "history", title: "History")
    let inbox: Inbox
    let slots: Slots
    func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        slots.contexts["history"] = context
        _ = context.subscribe(ProbeTranscript.self) { [inbox] in inbox.received.append($0.text) }
        return Quiet()
    }
}

private struct Emitter: SaysoModule {
    let descriptor = SaysoModuleDescriptor(id: "dictation", title: "Dictation")
    let slots: Slots
    func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        slots.contexts["dictation"] = context
        return Quiet()
    }
}

@Test func modulesCoordinateThroughEventsAndDisabledModulesStopReceiving() {
    let inbox = Inbox(), slots = Slots()
    let bus = SaysoEventBus()
    let host = SaysoModuleHost(modules: [Listener(inbox: inbox, slots: slots), Emitter(slots: slots)], events: bus)
    host.enable("history")
    host.enable("dictation")

    slots.contexts["dictation"]?.emit(ProbeTranscript(text: "one"))
    #expect(inbox.received == ["one"])

    host.disable("history")
    #expect(bus.subscriberCount == 0)
    slots.contexts["dictation"]?.emit(ProbeTranscript(text: "two"))
    #expect(inbox.received == ["one"])
}

@Test func staleContextCannotSubscribeOrEmitAfterDisable() {
    let inbox = Inbox(), slots = Slots()
    let bus = SaysoEventBus()
    let host = SaysoModuleHost(modules: [Listener(inbox: inbox, slots: slots), Emitter(slots: slots)], events: bus)
    host.enable("history")
    host.enable("dictation")
    let stale = slots.contexts["dictation"]!
    host.disable("dictation")

    stale.emit(ProbeTranscript(text: "ghost"))
    #expect(inbox.received.isEmpty)

    _ = stale.subscribe(ProbeTranscript.self) { _ in }
    #expect(bus.subscriberCount == 1)
}
