import Foundation
import Testing
@testable import SaysoCore

/// The colour picker reads only the pixel the user clicks, and only after a click on Pick, so it is on unless turned
/// off: a missing or malformed stored value means on, like the calculator.
@Test func theColorPickerIsOnForNewAndUpgradingUsers() throws {
    #expect(SaysoSettings().colorPickerEnabled)
    let olderSettings = Data("{\"mode\":\"dictation\",\"calculatorEnabled\":false}".utf8)
    #expect(try JSONDecoder().decode(SaysoSettings.self, from: olderSettings).colorPickerEnabled)
    let malformed = Data("{\"colorPickerEnabled\":\"no\"}".utf8)
    #expect(try JSONDecoder().decode(SaysoSettings.self, from: malformed).colorPickerEnabled)
}

@Test func turningTheColorPickerOffSurvivesARelaunch() throws {
    let suite = "ColorPickerSettingTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var settings = SaysoSettings()
    settings.colorPickerEnabled = false
    UserDefaultsSettingsStore(defaults: defaults).save(settings)

    #expect(!UserDefaultsSettingsStore(defaults: defaults).load().colorPickerEnabled)
}
