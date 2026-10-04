import Foundation
import Testing
@testable import SaysoCore

private final class FakeRegistrar: ShortcutRegistering, @unchecked Sendable {
    var handlers: [SaysoShortcutAction: @Sendable (Bool) -> Void] = [:]
    func register(_ action: SaysoShortcutAction, onTrigger: @escaping @Sendable (Bool) -> Void) -> SaysoSubscription {
        handlers[action] = onTrigger
        return SaysoSubscription { [weak self] in self?.handlers[action] = nil }
    }
    func press(_ action: SaysoShortcutAction, down: Bool = true) { handlers[action]?(down) }
}

private final class Seen: @unchecked Sendable { var triggers: [ShortcutTriggered] = [] }

private func makeHost(_ registrar: FakeRegistrar) -> (SaysoModuleHost, Seen) {
    let bus = SaysoEventBus()
    let seen = Seen()
    _ = bus.subscribe(ShortcutTriggered.self) { seen.triggers.append($0) }
    return (SaysoModuleHost(modules: [ShortcutsModule(registrar: registrar)], events: bus), seen)
}

@Test func enablingRegistersEveryActionAndPressesBecomeTypedEvents() {
    let registrar = FakeRegistrar()
    let (host, seen) = makeHost(registrar)
    host.enable("shortcuts")

    #expect(Set(registrar.handlers.keys) == Set(SaysoShortcutAction.allCases))

    registrar.press(.dictation)
    registrar.press(.control, down: true)
    registrar.press(.control, down: false)
    #expect(seen.triggers == [
        ShortcutTriggered(action: .dictation, isKeyDown: true),
        ShortcutTriggered(action: .control, isKeyDown: true),
        ShortcutTriggered(action: .control, isKeyDown: false),
    ])
}

@Test func disablingReleasesEveryRegistrationSoNoHotkeyStaysLive() {
    let registrar = FakeRegistrar()
    let (host, seen) = makeHost(registrar)
    host.enable("shortcuts")
    host.disable("shortcuts")

    #expect(registrar.handlers.isEmpty)
    registrar.press(.dictation)
    #expect(seen.triggers.isEmpty)
}

@Test func shortcutsModulePassesTheGenericAcceptanceHarness() {
    #expect(SaysoModuleAcceptance.violations(for: ShortcutsModule(registrar: FakeRegistrar())) == [])
}
