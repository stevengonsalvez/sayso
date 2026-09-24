import Foundation
import Testing
@testable import SaysoCore

@Test func folderControlRequiresAnExistingExplicitDirectory() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let snapshot = DesktopSnapshot(
        processIdentifier: 42,
        applicationName: "Finder",
        windowTitle: "",
        focusedRole: "AXOutline",
        focusedValue: "",
        isProtected: false
    )

    let step = try ControlPlanner.plan(command: "open folder \(directory.path)", snapshot: snapshot)
    #expect(step.action == .openFolder(url: directory.standardizedFileURL.resolvingSymlinksInPath()))
    #expect(!ControlPolicy.requiresActiveTarget(for: step.action))
    #expect(ControlPolicy.canAutoRun(step))
    #expect(!ControlPlanner.requiresInstalledApplicationCatalog(for: "open folder \(directory.path)"))

    #expect(throws: SaysoError.self) { try ControlPlanner.plan(command: "open folder Documents", snapshot: snapshot) }
    #expect(throws: SaysoError.self) { try ControlPlanner.plan(command: "open folder /does/not/exist", snapshot: snapshot) }
}
