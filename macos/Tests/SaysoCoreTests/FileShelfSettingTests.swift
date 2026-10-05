import Foundation
import Testing
@testable import SaysoCore

/// The file shelf holds read access to files the user hands it, so it stays off unless the user turns it on.
@Test func fileShelfIsOffForNewAndUpgradingUsers() throws {
    #expect(!SaysoSettings().fileShelfEnabled)
    let olderSettings = Data("{\"mode\":\"dictation\",\"clipboardModuleEnabled\":true}".utf8)
    #expect(try !JSONDecoder().decode(SaysoSettings.self, from: olderSettings).fileShelfEnabled)
    let malformed = Data("{\"fileShelfEnabled\":\"yes\"}".utf8)
    #expect(try !JSONDecoder().decode(SaysoSettings.self, from: malformed).fileShelfEnabled)
}

@Test func turningTheFileShelfOnSurvivesARelaunch() throws {
    let suite = "FileShelfSettingTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var settings = SaysoSettings()
    settings.fileShelfEnabled = true
    UserDefaultsSettingsStore(defaults: defaults).save(settings)

    #expect(UserDefaultsSettingsStore(defaults: defaults).load().fileShelfEnabled)
}
