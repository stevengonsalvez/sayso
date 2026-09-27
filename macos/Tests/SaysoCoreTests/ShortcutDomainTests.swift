import Foundation
import Testing
import SpeakHotKeys
@testable import SaysoCore

@Test func defaultShortcutActionsHaveValidConfigurations() {
    let actions = SaysoShortcutAction.allCases
    #expect(actions.count == 3)

    let dictation = SaysoShortcutAction.dictation
    #expect(dictation.displayName == "Start / Stop Dictation")
    #expect(dictation.defaultsKey == "sayso.dictation-hotkey")
    #expect(dictation.carbonID == 1)
    #expect(dictation.defaultHotKey == .custom(keyCode: 49, modifiers: .option))

    let control = SaysoShortcutAction.control
    #expect(control.displayName == "Start / Stop Desktop Control")
    #expect(control.defaultsKey == "sayso.control-hotkey")
    #expect(control.carbonID == 2)
    #expect(control.defaultHotKey == .custom(keyCode: 49, modifiers: [.control, .option]))

    let notch = SaysoShortcutAction.toggleNotch
    #expect(notch.displayName == "Toggle Notch HUD")
    #expect(notch.defaultsKey == "sayso.toggle-notch-hotkey")
    #expect(notch.carbonID == 3)
    #expect(notch.defaultHotKey == .custom(keyCode: 45, modifiers: [.control, .option]))
}

@Test func defaultShortcutsHaveNoConflicts() {
    let conflicts = ShortcutConflictDetector.detectConflicts(
        dictation: SaysoShortcutAction.dictation.defaultHotKey,
        control: SaysoShortcutAction.control.defaultHotKey,
        toggleNotch: SaysoShortcutAction.toggleNotch.defaultHotKey
    )
    #expect(conflicts.isEmpty)
}

@Test func duplicateShortcutsTriggerConflict() {
    let duplicate = HotKey.custom(keyCode: 49, modifiers: .option)
    let conflicts = ShortcutConflictDetector.detectConflicts(
        dictation: duplicate,
        control: duplicate,
        toggleNotch: .custom(keyCode: 45, modifiers: [.control, .option])
    )
    #expect(conflicts.count == 1)
    #expect(conflicts.first?.action == .dictation)
    #expect(conflicts.first?.message.contains("Start / Stop Desktop Control") == true)
}

@Test func systemShortcutTriggersConflict() {
    let copyShortcut = HotKey.custom(keyCode: 8, modifiers: [.command])
    let conflicts = ShortcutConflictDetector.detectConflicts(
        dictation: copyShortcut,
        control: SaysoShortcutAction.control.defaultHotKey,
        toggleNotch: SaysoShortcutAction.toggleNotch.defaultHotKey
    )
    #expect(conflicts.count == 1)
    #expect(conflicts.first?.action == .dictation)
    #expect(conflicts.first?.message.contains("⌘C Copy") == true)
}

@Test func shortcutActionEncodesAndDecodes() throws {
    for action in SaysoShortcutAction.allCases {
        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(SaysoShortcutAction.self, from: data)
        #expect(decoded == action)
    }
}
