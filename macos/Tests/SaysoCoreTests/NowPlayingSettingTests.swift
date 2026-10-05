import Foundation
import Testing
@testable import SaysoCore

/// Now Playing asks Music and Spotify for their track, which makes macOS show an Automation prompt, so it stays
/// off unless the user turns it on.
@Test func nowPlayingIsOffForNewAndUpgradingUsers() throws {
    #expect(!SaysoSettings().nowPlayingEnabled)
    let olderSettings = Data("{\"mode\":\"dictation\",\"clipboardModuleEnabled\":true,\"fileShelfEnabled\":true}".utf8)
    #expect(try !JSONDecoder().decode(SaysoSettings.self, from: olderSettings).nowPlayingEnabled)
    let malformed = Data("{\"nowPlayingEnabled\":\"yes\"}".utf8)
    #expect(try !JSONDecoder().decode(SaysoSettings.self, from: malformed).nowPlayingEnabled)
}

@Test func turningNowPlayingOnSurvivesARelaunch() throws {
    let suite = "NowPlayingSettingTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var settings = SaysoSettings()
    settings.nowPlayingEnabled = true
    UserDefaultsSettingsStore(defaults: defaults).save(settings)

    #expect(UserDefaultsSettingsStore(defaults: defaults).load().nowPlayingEnabled)
}
