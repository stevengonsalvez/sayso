import Foundation

/// What the app does when a shortcut fires; kept as a port so routing is testable and decoupled from key handling.
public protocol ShortcutIntentHandling: Sendable {
    func dictationShortcutPressed()
    func controlShortcutPressed()
    func controlShortcutReleased()
    func toggleNotchShortcutPressed()
}
