import Foundation
import Testing
@testable import SaysoCore

/// The calculator evaluates only what the user types and reads nothing else, so it is on unless turned off: a
/// missing or malformed stored value means on, like system stats.
@Test func theCalculatorIsOnForNewAndUpgradingUsers() throws {
    #expect(SaysoSettings().calculatorEnabled)
    let olderSettings = Data("{\"mode\":\"dictation\",\"systemStatsEnabled\":false}".utf8)
    #expect(try JSONDecoder().decode(SaysoSettings.self, from: olderSettings).calculatorEnabled)
    let malformed = Data("{\"calculatorEnabled\":\"no\"}".utf8)
    #expect(try JSONDecoder().decode(SaysoSettings.self, from: malformed).calculatorEnabled)
}

@Test func turningTheCalculatorOffSurvivesARelaunch() throws {
    let suite = "CalculatorSettingTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var settings = SaysoSettings()
    settings.calculatorEnabled = false
    UserDefaultsSettingsStore(defaults: defaults).save(settings)

    #expect(!UserDefaultsSettingsStore(defaults: defaults).load().calculatorEnabled)
}
