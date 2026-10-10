import Foundation
import Testing
@testable import SaysoCore

/// Battery health only reads the battery registry, so it is on unless the user turns it off: a missing or malformed
/// stored value means on, like system stats.
@Test func batteryHealthIsOnForNewAndUpgradingUsers() throws {
    #expect(SaysoSettings().batteryHealthEnabled)
    let olderSettings = Data("{\"mode\":\"dictation\",\"systemStatsEnabled\":false,\"privacyGuardEnabled\":false}".utf8)
    #expect(try JSONDecoder().decode(SaysoSettings.self, from: olderSettings).batteryHealthEnabled)
    let malformed = Data("{\"batteryHealthEnabled\":\"no\"}".utf8)
    #expect(try JSONDecoder().decode(SaysoSettings.self, from: malformed).batteryHealthEnabled)
}

@Test func turningBatteryHealthOffSurvivesARelaunch() throws {
    let suite = "BatteryHealthSettingTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var settings = SaysoSettings()
    settings.batteryHealthEnabled = false
    UserDefaultsSettingsStore(defaults: defaults).save(settings)

    #expect(!UserDefaultsSettingsStore(defaults: defaults).load().batteryHealthEnabled)
}
