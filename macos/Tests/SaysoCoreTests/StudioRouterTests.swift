import Testing
@testable import SaysoCore

private let clip = SaysoModuleDescriptor(
    id: "clip", title: "Clipboard", capabilities: [.clipboard], surfaces: [.compact, .detail, .settings]
)
private let timer = SaysoModuleDescriptor(id: "timer", title: "Timer", surfaces: [.compact])

private func route(_ id: String, _ health: SaysoModuleHealth) -> SaysoStudioRoute {
    SaysoStudioRouter.route(
        moduleID: id, descriptors: [clip, timer], health: { $0 == "clip" ? health : .ready }, isGranted: { _ in false }
    )
}

@Test func healthyModuleOpensItsDetailSurfaceElseSettingsElseExpandedElseCompact() {
    #expect(route("clip", .ready) == .module(id: "clip", surface: .detail))
    #expect(route("timer", .ready) == .module(id: "timer", surface: .compact))
}

@Test func permissionRequiredRoutesToTheGrantPromptForExactlyTheMissingCapabilities() {
    #expect(route("clip", .permissionRequired) == .permissionPrompt(id: "clip", capabilities: [.clipboard]))
}

@Test func disabledFailedAndQuarantinedModulesRouteToSettingsWhereTheyCanBeRecovered() {
    for health: SaysoModuleHealth in [.disabled, .failed, .quarantined] {
        #expect(route("clip", health) == .module(id: "clip", surface: .settings))
    }
}

@Test func unknownModuleFallsBackToTheModuleList() {
    #expect(route("nope", .ready) == .moduleList)
}
