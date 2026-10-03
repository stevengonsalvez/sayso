import Foundation

public struct ShortcutsModule: SaysoModule {
    public let descriptor = SaysoModuleDescriptor(
        id: "shortcuts", title: "Shortcuts", capabilities: [.accessibility], surfaces: [.settings]
    )
    private let registrar: ShortcutRegistering

    public init(registrar: ShortcutRegistering) { self.registrar = registrar }

    public func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        Runtime(registrar: registrar, context: context)
    }

    private final class Runtime: SaysoModuleRuntime, SaysoResourceAccounting, @unchecked Sendable {
        let registrar: ShortcutRegistering
        let context: SaysoModuleContext
        private let lock = NSLock()
        private var registrations: [SaysoSubscription] = []

        init(registrar: ShortcutRegistering, context: SaysoModuleContext) {
            self.registrar = registrar
            self.context = context
        }

        var retainedResources: Int { lock.withLock { registrations.count } }

        func start() {
            let made = SaysoShortcutAction.allCases.map { action in
                registrar.register(action) { [context] isKeyDown in
                    context.emit(ShortcutTriggered(action: action, isKeyDown: isKeyDown))
                }
            }
            lock.withLock { registrations = made }
        }

        func stop() {
            let pending = lock.withLock { () -> [SaysoSubscription] in
                defer { registrations = [] }
                return registrations
            }
            pending.forEach { $0.cancel() }
        }
    }
}
