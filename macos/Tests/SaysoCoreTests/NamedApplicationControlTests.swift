import Foundation
import Testing
@testable import SaysoCore

private let namedApplicationSnapshot = DesktopSnapshot(
    processIdentifier: 42,
    applicationName: "Editor",
    windowTitle: "Draft",
    focusedRole: "AXTextField",
    focusedValue: "",
    isProtected: false
)

private func installedApplication(
    _ name: String,
    bundleIdentifier: String,
    path: String
) -> InstalledDesktopApplication {
    .init(name: name, bundleIdentifier: bundleIdentifier, applicationURL: URL(fileURLWithPath: path))
}

@Test func namedApplicationCommandsResolveExactlyAndRequireReview() throws {
    let safari = installedApplication(
        "Safari",
        bundleIdentifier: "com.apple.Safari",
        path: "/Applications/Safari.app"
    )

    let open = try ControlPlanner.plan(
        command: "open SÁFARI",
        snapshot: namedApplicationSnapshot,
        installedApplications: [safari]
    )
    let switchTo = try ControlPlanner.plan(
        command: "switch to Safari",
        snapshot: namedApplicationSnapshot,
        installedApplications: [safari]
    )
    let spokenPunctuation = try ControlPlanner.plan(
        command: "open Safari!",
        snapshot: namedApplicationSnapshot,
        installedApplications: [safari]
    )
    let appFilename = try ControlPlanner.plan(
        command: "switch to Safari.app,",
        snapshot: namedApplicationSnapshot,
        installedApplications: [safari]
    )
    let expected = DesktopAction.activateApplication(
        bundleIdentifier: "com.apple.Safari",
        applicationURL: URL(fileURLWithPath: "/Applications/Safari.app")
    )

    #expect(open.action == expected)
    #expect(switchTo.action == expected)
    #expect(spokenPunctuation.action == expected)
    #expect(appFilename.action == expected)
    #expect(open.reason == "Exact installed application")
    #expect(ControlPolicy.requiresConfirmation(open))
    #expect(!ControlPolicy.canAutoRun(open))
}

@Test func namedApplicationResolverChoosesDuplicateBundleDeterministically() {
    let primary = installedApplication(
        "Safari",
        bundleIdentifier: "com.apple.Safari",
        path: "/Applications/Safari.app"
    )
    let duplicate = installedApplication(
        "Safari",
        bundleIdentifier: "com.apple.Safari",
        path: "/Applications/Utilities/Safari.app"
    )

    #expect(DesktopApplicationResolver.resolve("Safari", in: [duplicate, primary]) == .resolved(primary))
}

@Test func namedApplicationCommandsRejectAmbiguousAndNonExactNames() {
    let safari = installedApplication(
        "Safari",
        bundleIdentifier: "com.apple.Safari",
        path: "/Applications/Safari.app"
    )
    let workSafari = installedApplication(
        "Safari",
        bundleIdentifier: "com.example.WorkSafari",
        path: "/Applications/WorkSafari.app"
    )

    #expect(DesktopApplicationResolver.resolve("Safari", in: [workSafari, safari]) == .ambiguous([safari, workSafari]))
    #expect(throws: SaysoError.invalidAction("More than one installed application is named 'Safari'. Say an exact unique .app filename: Safari.app or WorkSafari.app, or remove a duplicate.")) {
        try ControlPlanner.plan(
            command: "open Safari",
            snapshot: namedApplicationSnapshot,
            installedApplications: [safari, workSafari]
        )
    }
    #expect(throws: SaysoError.self) {
        try ControlPlanner.plan(
            command: "switch to Saf",
            snapshot: namedApplicationSnapshot,
            installedApplications: [safari]
        )
    }
}

@Test func namedApplicationCatalogIsOnlyNeededForNamedTargets() {
    #expect(!ControlPlanner.requiresInstalledApplicationCatalog(for: "open https://example.com/docs"))
    #expect(!ControlPlanner.requiresInstalledApplicationCatalog(for: "open http://localhost:8080"))
    #expect(ControlPlanner.requiresInstalledApplicationCatalog(for: "open Safari"))
    #expect(ControlPlanner.requiresInstalledApplicationCatalog(for: "switch to Safari"))
    #expect(!ControlPlanner.requiresInstalledApplicationCatalog(for: "activate com.apple.Safari"))
    #expect(!ControlPlanner.requiresInstalledApplicationCatalog(for: "open"))
}

@Test func namedApplicationLaunchValidationChecksBundleAtPlannedPath() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let applicationURL = root.appending(path: "Test.app", directoryHint: .isDirectory)
    let contentsURL = applicationURL.appending(path: "Contents", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
    let info = ["CFBundleIdentifier": "ai.sayso.test-app"]
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contentsURL.appending(path: "Info.plist"))

    #expect(InstalledDesktopApplication.validatesLaunchTarget(
        bundleIdentifier: "ai.sayso.test-app",
        applicationURL: applicationURL
    ))
    #expect(!InstalledDesktopApplication.validatesLaunchTarget(
        bundleIdentifier: "ai.sayso.other-app",
        applicationURL: applicationURL
    ))
    #expect(!InstalledDesktopApplication.validatesLaunchTarget(
        bundleIdentifier: "ai.sayso.test-app",
        applicationURL: contentsURL
    ))
}

@Test func namedApplicationPlannerPreservesExplicitHTTPSNavigation() throws {
    let plan = try ControlPlanner.plan(
        command: "open https://example.com/docs",
        snapshot: namedApplicationSnapshot,
        installedApplications: []
    )

    #expect(plan.action == .open(url: URL(string: "https://example.com/docs")!))
}
