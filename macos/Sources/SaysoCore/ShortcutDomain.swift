import Foundation
import SpeakHotKeys

/// Actions that can be triggered via global or local keyboard shortcuts.
public enum SaysoShortcutAction: String, CaseIterable, Identifiable, Codable, Sendable {
    case dictation
    case control
    case toggleNotch

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .dictation: return "Start / Stop Dictation"
        case .control: return "Start / Stop Desktop Control"
        case .toggleNotch: return "Toggle Notch HUD"
        }
    }

    public var explanatoryText: String {
        switch self {
        case .dictation:
            return "Double-tap Fn to start or stop dictating into the focused app."
        case .control:
            return "Triple-tap Fn to start or stop listening for desktop control commands."
        case .toggleNotch:
            return "Show, hide, or expand the Notch HUD overlay on your screen."
        }
    }

    public var defaultHotKey: HotKey {
        switch self {
        case .dictation:
            return .fnKey
        case .control:
            return .fnKey
        case .toggleNotch:
            return .custom(keyCode: 45, modifiers: [.control, .option]) // ⌃⌥ N
        }
    }

    public var customFallbackHotKey: HotKey {
        switch self {
        case .dictation:
            return .custom(keyCode: 49, modifiers: .option)
        case .control:
            return .custom(keyCode: 49, modifiers: [.control, .option])
        case .toggleNotch:
            return defaultHotKey
        }
    }

    public var defaultsKey: String {
        switch self {
        case .dictation: return "sayso.dictation-hotkey"
        case .control: return "sayso.control-hotkey"
        case .toggleNotch: return "sayso.toggle-notch-hotkey"
        }
    }

    public var carbonID: UInt32 {
        switch self {
        case .dictation: return 1
        case .control: return 2
        case .toggleNotch: return 3
        }
    }
}

public struct SaysoShortcutBindings: Equatable, Sendable {
    public let dictation: HotKey
    public let control: HotKey
    public let toggleNotch: HotKey

    public init(dictation: HotKey, control: HotKey, toggleNotch: HotKey) {
        self.dictation = dictation
        self.control = control
        self.toggleNotch = toggleNotch
    }
}

public enum ShortcutHint {
    public static func compact(for action: SaysoShortcutAction, hotKey: HotKey) -> String {
        guard hotKey.isFnKey else { return hotKey.displayString }
        return action == .control ? "Triple Fn" : "Double Fn"
    }

    public static func accessibility(for action: SaysoShortcutAction, hotKey: HotKey) -> String {
        if hotKey.isFnKey {
            return action == .control ? "Triple tap Fn" : "Double tap Fn"
        }
        return "Press \(hotKey.displayString)"
    }

    public static func explanation(for action: SaysoShortcutAction, hotKey: HotKey) -> String {
        switch action {
        case .dictation:
            return "\(accessibility(for: action, hotKey: hotKey)) to start or stop dictating into the focused app."
        case .control:
            return "\(accessibility(for: action, hotKey: hotKey)) to start or stop listening for desktop control commands."
        case .toggleNotch:
            return "Show, hide, or expand the Notch HUD overlay on your screen."
        }
    }
}

public enum ShortcutDefaultsMigration {
    public static let currentVersion = 1

    private static let historicalDictation = HotKey.custom(keyCode: 49, modifiers: .option)
    private static let historicalControl = HotKey.custom(keyCode: 49, modifiers: [.control, .option])

    public static func migrate(
        dictation: HotKey?,
        control: HotKey?,
        toggleNotch: HotKey?,
        fromVersion: Int
    ) -> SaysoShortcutBindings {
        let shouldMigrate = fromVersion < currentVersion
        return .init(
            dictation: shouldMigrate && (dictation == nil || dictation == historicalDictation)
                ? SaysoShortcutAction.dictation.defaultHotKey
                : dictation ?? SaysoShortcutAction.dictation.defaultHotKey,
            control: shouldMigrate && (control == nil || control == historicalControl)
                ? SaysoShortcutAction.control.defaultHotKey
                : control ?? SaysoShortcutAction.control.defaultHotKey,
            toggleNotch: toggleNotch ?? SaysoShortcutAction.toggleNotch.defaultHotKey
        )
    }
}

public enum ShortcutGestureAction: Equatable, Sendable {
    case dictation
    case control
    case voiceEdit
}

public enum ShortcutGestureRouter {
    public static func monitoredHotKey(dictation: HotKey, control: HotKey) -> HotKey {
        dictation
    }

    public static func needsSeparateControlMonitor(dictation: HotKey, control: HotKey) -> Bool {
        !dictation.isFnKey && control.isFnKey
    }

    public static func action(
        for gesture: HotKeyGesture,
        monitoredHotKey: HotKey,
        dictation: HotKey,
        control: HotKey
    ) -> ShortcutGestureAction? {
        if monitoredHotKey.isFnKey {
            if gesture == .doubleTap, dictation.isFnKey { return .dictation }
            if gesture == .tripleTap, control.isFnKey { return .control }
            return nil
        }
        guard monitoredHotKey == dictation else { return nil }
        if gesture == .singleTap { return .dictation }
        if gesture == .doubleTap { return .voiceEdit }
        return nil
    }
}

/// Represents a detected conflict between keyboard shortcuts.
public struct ShortcutConflict: Identifiable, Equatable, Sendable {
    public let id: String
    public let action: SaysoShortcutAction
    public let message: String

    public init(action: SaysoShortcutAction, conflictingWith other: SaysoShortcutAction) {
        self.id = "\(action.rawValue)-\(other.rawValue)"
        self.action = action
        self.message = "\(action.displayName) uses the same shortcut as \(other.displayName)."
    }

    public init(action: SaysoShortcutAction, systemShortcut: String) {
        self.id = "\(action.rawValue)-system-\(systemShortcut)"
        self.action = action
        self.message = "\(action.displayName) conflicts with macOS system shortcut (\(systemShortcut))."
    }
}

/// Helper for detecting conflicts among configured shortcuts and against standard macOS shortcuts.
public enum ShortcutConflictDetector {
    public static func detectConflicts(
        dictation: HotKey,
        control: HotKey,
        toggleNotch: HotKey
    ) -> [ShortcutConflict] {
        var conflicts: [ShortcutConflict] = []

        if dictation == control, !dictation.isFnKey {
            conflicts.append(ShortcutConflict(action: .dictation, conflictingWith: .control))
        }
        if dictation == toggleNotch {
            conflicts.append(ShortcutConflict(action: .dictation, conflictingWith: .toggleNotch))
        }
        if control == toggleNotch {
            conflicts.append(ShortcutConflict(action: .control, conflictingWith: .toggleNotch))
        }

        let systemShortcuts: [(UInt16, HotKey.ModifierSet, String)] = [
            (8, [.command], "⌘C Copy"),
            (9, [.command], "⌘V Paste"),
            (7, [.command], "⌘X Cut"),
            (6, [.command], "⌘Z Undo"),
            (0, [.command], "⌘A Select All"),
            (12, [.command], "⌘Q Quit"),
            (13, [.command], "⌘W Close"),
            (1, [.command], "⌘S Save"),
            (4, [.command], "⌘H Hide"),
            (46, [.command], "⌘M Minimize"),
        ]

        let pairs: [(SaysoShortcutAction, HotKey)] = [
            (.dictation, dictation),
            (.control, control),
            (.toggleNotch, toggleNotch),
        ]

        for (action, hotKey) in pairs {
            if case let .custom(keyCode, modifiers) = hotKey {
                for (sysCode, sysMod, name) in systemShortcuts {
                    if keyCode == sysCode && modifiers == sysMod {
                        conflicts.append(ShortcutConflict(action: action, systemShortcut: name))
                    }
                }
            }
        }

        return conflicts
    }
}
