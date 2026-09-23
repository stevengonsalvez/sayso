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
    let expected = DesktopAction.activateApplication(
        bundleIdentifier: "com.apple.Safari",
        applicationURL: URL(fileURLWithPath: "/Applications/Safari.app")
    )

    #expect(open.action == expected)
    #expect(switchTo.action == expected)
    #expect(open.reason == "Exact installed application")
    #expect(ControlPolicy.requiresConfirmation(open))
    #expect(!ControlPolicy.canAutoRun(open))
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
    #expect(throws: SaysoError.self) {
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

@Test func namedApplicationPlannerPreservesExplicitHTTPSNavigation() throws {
    let plan = try ControlPlanner.plan(
        command: "open https://example.com/docs",
        snapshot: namedApplicationSnapshot,
        installedApplications: []
    )

    #expect(plan.action == .open(url: URL(string: "https://example.com/docs")!))
}
