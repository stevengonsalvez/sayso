import Foundation
import Testing
@testable import SaysoCore

/// File tools read only the files the user names and only when a tool is pressed, so they are on unless turned off:
/// a missing or malformed stored value means on, like the calculator.
@Test func fileToolsAreOnForNewAndUpgradingUsers() throws {
    #expect(SaysoSettings().fileToolsEnabled)
    let olderSettings = Data("{\"mode\":\"dictation\",\"colorPickerEnabled\":false}".utf8)
    #expect(try JSONDecoder().decode(SaysoSettings.self, from: olderSettings).fileToolsEnabled)
    let malformed = Data("{\"fileToolsEnabled\":\"no\"}".utf8)
    #expect(try JSONDecoder().decode(SaysoSettings.self, from: malformed).fileToolsEnabled)
}

@Test func turningFileToolsOffSurvivesARelaunch() throws {
    let suite = "FileToolsSettingTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var settings = SaysoSettings()
    settings.fileToolsEnabled = false
    UserDefaultsSettingsStore(defaults: defaults).save(settings)

    #expect(!UserDefaultsSettingsStore(defaults: defaults).load().fileToolsEnabled)
}

/// The app gates the module through `setEnabled`; off before any enable keeps it idle, and off after a job clears
/// the outcome, the notice and its timer.
@Test func theSettingGateKeepsFileToolsOffAndPurgesThemWhenTurnedOff() throws {
    let module = FileToolsModule(
        port: FileSystemToolsPort(), scheduler: SaysoDispatchScheduler(queue: DispatchQueue(label: "file-tools-setting-test")),
        worker: FileToolsWorker { $0() }
    )
    let host = SaysoModuleHost(modules: [module])
    host.setEnabled(module.descriptor.id, false)
    #expect(host.health(of: "file-tools") == .disabled)
    #expect(module.run(.zip, paths: "/does/not/matter.txt") == .off)

    host.setEnabled(module.descriptor.id, true)
    #expect(module.run(.zip, paths: "/sayso-file-tools-setting-test/missing.txt") == nil)
    #expect(module.status == .failed(.missing("missing.txt")))
    #expect(host.engine.stack.contains { $0.moduleID == "file-tools" })

    host.setEnabled(module.descriptor.id, false)
    #expect(host.health(of: "file-tools") == .disabled)
    #expect(module.status == .idle)
    #expect(!host.engine.stack.contains { $0.moduleID == "file-tools" })
    #expect(module.run(.zip, paths: "/does/not/matter.txt") == .off)
}
