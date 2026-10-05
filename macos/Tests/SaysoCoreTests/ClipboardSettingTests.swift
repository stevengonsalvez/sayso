import Foundation
import Testing
@testable import SaysoCore

/// The clipboard module reads the pasteboard, so it stays off unless the user turns it on.
@Test func clipboardModuleIsOffForNewAndUpgradingUsers() throws {
    #expect(!SaysoSettings().clipboardModuleEnabled)
    let olderSettings = Data("{\"mode\":\"dictation\",\"desktopControlEnabled\":true}".utf8)
    #expect(try !JSONDecoder().decode(SaysoSettings.self, from: olderSettings).clipboardModuleEnabled)
    let malformed = Data("{\"clipboardModuleEnabled\":\"yes\"}".utf8)
    #expect(try !JSONDecoder().decode(SaysoSettings.self, from: malformed).clipboardModuleEnabled)
}

@Test func turningTheClipboardModuleOnSurvivesARelaunch() throws {
    let suite = "ClipboardSettingTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var settings = SaysoSettings()
    settings.clipboardModuleEnabled = true
    UserDefaultsSettingsStore(defaults: defaults).save(settings)

    #expect(UserDefaultsSettingsStore(defaults: defaults).load().clipboardModuleEnabled)
}
