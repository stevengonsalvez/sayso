import Foundation

/// A global shortcut was pressed or released; consumers decide what the action means.
public struct ShortcutTriggered: SaysoEvent, Equatable {
    public let action: SaysoShortcutAction
    public let isKeyDown: Bool
    public init(action: SaysoShortcutAction, isKeyDown: Bool) {
        self.action = action
        self.isKeyDown = isKeyDown
    }
}
