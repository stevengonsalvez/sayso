import Foundation

/// Nondeterministic boundary: the Carbon/AppKit hotkey manager registers behind this.
public protocol ShortcutRegistering: Sendable {
    /// Cancelling the returned subscription must unregister the hotkey.
    func register(_ action: SaysoShortcutAction, onTrigger: @escaping @Sendable (Bool) -> Void) -> SaysoSubscription
}
