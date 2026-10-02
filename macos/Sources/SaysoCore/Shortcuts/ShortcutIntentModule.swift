import Foundation

/// Turns `ShortcutTriggered` events into intents. Mirrors the app's original shortcut switch exactly:
/// dictation and toggle-notch react to key down only; control reacts to both edges.
public struct ShortcutIntentModule: SaysoModule {
    public let descriptor = SaysoModuleDescriptor(id: "shortcut-intents", title: "Shortcut actions", surfaces: [.settings])
    private let handler: ShortcutIntentHandling

    public init(handler: ShortcutIntentHandling) { self.handler = handler }

    public func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        Runtime(handler: handler, context: context)
    }

    private final class Runtime: SaysoModuleRuntime, SaysoResourceAccounting, @unchecked Sendable {
        let handler: ShortcutIntentHandling
        let context: SaysoModuleContext
        private let lock = NSLock()
        private var subscription: SaysoSubscription?

        init(handler: ShortcutIntentHandling, context: SaysoModuleContext) {
            self.handler = handler
            self.context = context
        }

        var retainedResources: Int { lock.withLock { subscription == nil ? 0 : 1 } }

        func start() {
            let made = context.subscribe(ShortcutTriggered.self) { [handler] event in
                switch (event.action, event.isKeyDown) {
                case (.dictation, true): handler.dictationShortcutPressed()
                case (.control, true): handler.controlShortcutPressed()
                case (.control, false): handler.controlShortcutReleased()
                case (.toggleNotch, true): handler.toggleNotchShortcutPressed()
                default: break
                }
            }
            lock.withLock { subscription = made }
        }

        func stop() {
            let made = lock.withLock { () -> SaysoSubscription? in
                defer { subscription = nil }
                return subscription
            }
            made?.cancel()
        }
    }
}
