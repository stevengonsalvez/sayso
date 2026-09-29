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
    #expect(dictation.defaultHotKey == .fnKey)

    let control = SaysoShortcutAction.control
    #expect(control.displayName == "Start / Stop Desktop Control")
    #expect(control.defaultsKey == "sayso.control-hotkey")
    #expect(control.carbonID == 2)
    #expect(control.defaultHotKey == .fnKey)

    let notch = SaysoShortcutAction.toggleNotch
    #expect(notch.displayName == "Toggle Notch HUD")
    #expect(notch.defaultsKey == "sayso.toggle-notch-hotkey")
    #expect(notch.carbonID == 3)
    #expect(notch.defaultHotKey == .custom(keyCode: 45, modifiers: [.control, .option]))
}

@Test func historicalShortcutDefaultsMigrateToFnGestures() {
    let migrated = ShortcutDefaultsMigration.migrate(
        dictation: .custom(keyCode: 49, modifiers: .option),
        control: .custom(keyCode: 49, modifiers: [.control, .option]),
        toggleNotch: .custom(keyCode: 45, modifiers: [.control, .option]),
        fromVersion: 0
    )

    #expect(migrated.dictation == .fnKey)
    #expect(migrated.control == .fnKey)
    #expect(migrated.toggleNotch == .custom(keyCode: 45, modifiers: [.control, .option]))
}

@Test func shortcutMigrationPreservesEveryCustomBinding() {
    let dictation = HotKey.custom(keyCode: 2, modifiers: [.command, .shift])
    let control = HotKey.custom(keyCode: 3, modifiers: [.control])
    let notch = HotKey.custom(keyCode: 4, modifiers: [.option])

    let migrated = ShortcutDefaultsMigration.migrate(
        dictation: dictation,
        control: control,
        toggleNotch: notch,
        fromVersion: 0
    )

    #expect(migrated == .init(dictation: dictation, control: control, toggleNotch: notch))
}

@Test func currentShortcutVersionNeverRewritesStoredBindings() {
    let historicalDictation = HotKey.custom(keyCode: 49, modifiers: .option)
    let historicalControl = HotKey.custom(keyCode: 49, modifiers: [.control, .option])

    let unchanged = ShortcutDefaultsMigration.migrate(
        dictation: historicalDictation,
        control: historicalControl,
        toggleNotch: nil,
        fromVersion: ShortcutDefaultsMigration.currentVersion
    )

    #expect(unchanged.dictation == historicalDictation)
    #expect(unchanged.control == historicalControl)
    #expect(unchanged.toggleNotch == SaysoShortcutAction.toggleNotch.defaultHotKey)
}

@Test func sharedFnDefaultsDoNotConflictBecauseGesturesDiffer() {
    let conflicts = ShortcutConflictDetector.detectConflicts(
        dictation: .fnKey,
        control: .fnKey,
        toggleNotch: SaysoShortcutAction.toggleNotch.defaultHotKey
    )

    #expect(conflicts.isEmpty)
}

@Test func fnGestureRouterSeparatesDictationAndControl() {
    #expect(ShortcutGestureRouter.monitoredHotKey(dictation: .fnKey, control: .fnKey) == .fnKey)
    #expect(ShortcutGestureRouter.action(for: .singleTap, monitoredHotKey: .fnKey, dictation: .fnKey, control: .fnKey) == nil)
    #expect(ShortcutGestureRouter.action(for: .doubleTap, monitoredHotKey: .fnKey, dictation: .fnKey, control: .fnKey) == .dictation)
    #expect(ShortcutGestureRouter.action(for: .tripleTap, monitoredHotKey: .fnKey, dictation: .fnKey, control: .fnKey) == .control)
}

@Test func customDictationRetainsSingleTapAndVoiceEditGestures() {
    let custom = HotKey.custom(keyCode: 2, modifiers: [.command, .shift])

    #expect(ShortcutGestureRouter.monitoredHotKey(dictation: custom, control: SaysoShortcutAction.control.defaultHotKey) == custom)
    #expect(ShortcutGestureRouter.needsSeparateControlMonitor(dictation: custom, control: .fnKey))
    #expect(ShortcutGestureRouter.action(for: .singleTap, monitoredHotKey: custom, dictation: custom, control: .fnKey) == .dictation)
    #expect(ShortcutGestureRouter.action(for: .doubleTap, monitoredHotKey: custom, dictation: custom, control: .fnKey) == .voiceEdit)
}

@Test func sharedFnBindingsUseOneGestureMonitor() {
    #expect(!ShortcutGestureRouter.needsSeparateControlMonitor(dictation: .fnKey, control: .fnKey))
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
