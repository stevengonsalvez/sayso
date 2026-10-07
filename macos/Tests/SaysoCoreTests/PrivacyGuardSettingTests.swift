import Foundation
import Testing
@testable import SaysoCore

/// The privacy guard only reads whether a device is on, so it is on unless the user turns it off: a missing or
/// malformed stored value means on, like system stats.
@Test func thePrivacyGuardIsOnForNewAndUpgradingUsers() throws {
    #expect(SaysoSettings().privacyGuardEnabled)
    let olderSettings = Data("{\"mode\":\"dictation\",\"systemStatsEnabled\":false,\"fileToolsEnabled\":false}".utf8)
    #expect(try JSONDecoder().decode(SaysoSettings.self, from: olderSettings).privacyGuardEnabled)
    let malformed = Data("{\"privacyGuardEnabled\":\"no\"}".utf8)
    #expect(try JSONDecoder().decode(SaysoSettings.self, from: malformed).privacyGuardEnabled)
}

@Test func turningThePrivacyGuardOffSurvivesARelaunch() throws {
    let suite = "PrivacyGuardSettingTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var settings = SaysoSettings()
    settings.privacyGuardEnabled = false
    UserDefaultsSettingsStore(defaults: defaults).save(settings)

    #expect(!UserDefaultsSettingsStore(defaults: defaults).load().privacyGuardEnabled)
}
