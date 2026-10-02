import Foundation
import Testing
@testable import SaysoCore

private final class FakeHandler: ShortcutIntentHandling, @unchecked Sendable {
    var calls: [String] = []
    func dictationShortcutPressed() { calls.append("dictation") }
    func controlShortcutPressed() { calls.append("control-down") }
    func controlShortcutReleased() { calls.append("control-up") }
    func toggleNotchShortcutPressed() { calls.append("toggle-notch") }
}

private func setup() -> (SaysoModuleHost, SaysoEventBus, FakeHandler) {
    let bus = SaysoEventBus(), handler = FakeHandler()
    let host = SaysoModuleHost(modules: [ShortcutIntentModule(handler: handler)], events: bus)
    host.enable("shortcut-intents")
    return (host, bus, handler)
}

@Test func keyDownAndUpMapToTheSameIntentsAsTheOriginalShortcutSwitch() {
    let (_, bus, handler) = setup()
    bus.publish(ShortcutTriggered(action: .dictation, isKeyDown: true))
    bus.publish(ShortcutTriggered(action: .dictation, isKeyDown: false))
    bus.publish(ShortcutTriggered(action: .control, isKeyDown: true))
    bus.publish(ShortcutTriggered(action: .control, isKeyDown: false))
    bus.publish(ShortcutTriggered(action: .toggleNotch, isKeyDown: true))
    bus.publish(ShortcutTriggered(action: .toggleNotch, isKeyDown: false))

    #expect(handler.calls == ["dictation", "control-down", "control-up", "toggle-notch"])
}

@Test func disabledIntentModuleIgnoresShortcuts() {
    let (host, bus, handler) = setup()
    host.disable("shortcut-intents")
    bus.publish(ShortcutTriggered(action: .dictation, isKeyDown: true))
    #expect(handler.calls.isEmpty)
    #expect(bus.subscriberCount == 0)
}

@Test func shortcutIntentModulePassesTheGenericAcceptanceHarness() {
    #expect(SaysoModuleAcceptance.violations(for: ShortcutIntentModule(handler: FakeHandler())) == [])
}
