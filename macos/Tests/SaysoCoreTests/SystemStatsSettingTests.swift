import Foundation
import Testing
@testable import SaysoCore

/// System stats only read counters and were always on, so they stay on unless the user turns them off: a missing or
/// malformed stored value means on, the opposite of the opt-in modules.
@Test func systemStatsAreOnForNewAndUpgradingUsers() throws {
    #expect(SaysoSettings().systemStatsEnabled)
    let olderSettings = Data("{\"mode\":\"dictation\",\"clipboardModuleEnabled\":true,\"nowPlayingEnabled\":true}".utf8)
    #expect(try JSONDecoder().decode(SaysoSettings.self, from: olderSettings).systemStatsEnabled)
    let malformed = Data("{\"systemStatsEnabled\":\"no\"}".utf8)
    #expect(try JSONDecoder().decode(SaysoSettings.self, from: malformed).systemStatsEnabled)
}

@Test func turningSystemStatsOffSurvivesARelaunch() throws {
    let suite = "SystemStatsSettingTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var settings = SaysoSettings()
    settings.systemStatsEnabled = false
    UserDefaultsSettingsStore(defaults: defaults).save(settings)

    #expect(!UserDefaultsSettingsStore(defaults: defaults).load().systemStatsEnabled)
}
