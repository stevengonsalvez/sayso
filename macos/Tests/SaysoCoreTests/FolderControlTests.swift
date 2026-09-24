import Foundation
import Testing
@testable import SaysoCore

@Test func folderControlRequiresAnExistingExplicitDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let directory = root.appendingPathComponent("Folder", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let linkedDirectory = root.appendingPathComponent("LinkedFolder", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: directory)
    let plainFile = root.appendingPathComponent("note.txt")
    try Data().write(to: plainFile)
    let appBundle = root.appendingPathComponent("Unsafe.app", isDirectory: true)
    try FileManager.default.createDirectory(at: appBundle, withIntermediateDirectories: true)
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

    let linkedStep = try ControlPlanner.plan(command: "open folder \(linkedDirectory.path)", snapshot: snapshot)
    if case let .openFolder(url) = linkedStep.action {
        #expect(url.path == directory.path)
    } else {
        Issue.record("Expected linked folder action")
    }

    let homeStep = try ControlPlanner.plan(command: "open folder ~/", snapshot: snapshot)
    if case let .openFolder(url) = homeStep.action {
        #expect(url.path == FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path)
    } else {
        Issue.record("Expected home folder action")
    }

    #expect(throws: SaysoError.invalidAction("Open folder requires a path.")) { try ControlPlanner.plan(command: "open folder", snapshot: snapshot) }
    #expect(throws: SaysoError.self) { try ControlPlanner.plan(command: "open folder Documents", snapshot: snapshot) }
    #expect(throws: SaysoError.invalidAction("No folder exists at '/does/not/exist'.")) { try ControlPlanner.plan(command: "open folder /does/not/exist", snapshot: snapshot) }
    #expect(throws: SaysoError.invalidAction("No folder exists at '\(plainFile.path)'.")) { try ControlPlanner.plan(command: "open folder \(plainFile.path)", snapshot: snapshot) }
    #expect(throws: SaysoError.invalidAction("Open folder does not launch app or package bundles.")) { try ControlPlanner.plan(command: "open folder \(appBundle.path)", snapshot: snapshot) }
}
