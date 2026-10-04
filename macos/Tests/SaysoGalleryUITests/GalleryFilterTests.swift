import Testing
import SaysoCore
@testable import SaysoGalleryUI

private let scenarios = SaysoGallery.scenarios(for: [
    SaysoModuleDescriptor(id: "clip", title: "Clipboard", capabilities: [.clipboard], surfaces: [.compact, .expanded]),
    SaysoModuleDescriptor(id: "timer", title: "Timer", surfaces: [.compact, .peek]),
])

@Test func emptyFilterKeepsEveryScenario() {
    #expect(SaysoGalleryFilter().apply(to: scenarios) == scenarios)
}

@Test func filtersByModuleSurfaceHealthAndAccessibility() {
    var filter = SaysoGalleryFilter(moduleIDs: ["timer"])
    #expect(filter.apply(to: scenarios).allSatisfy { $0.moduleID == "timer" })

    filter.surfaces = [.peek]
    #expect(filter.apply(to: scenarios).allSatisfy { $0.surface == .peek && $0.moduleID == "timer" })

    filter.healths = [.failed]
    filter.accessibility = [.increaseContrast]
    let result = filter.apply(to: scenarios)
    #expect(result.count == 1)
    #expect(result.first?.health == .failed && result.first?.accessibility == .increaseContrast)
}

@Test func filtersCombineAsIntersectionAndCanYieldNothing() {
    // timer declares no capabilities, so it never has a permissionRequired scenario
    let filter = SaysoGalleryFilter(moduleIDs: ["timer"], healths: [.permissionRequired])
    #expect(filter.apply(to: scenarios).isEmpty)
}

@Test func resetClearsAllCriteria() {
    var filter = SaysoGalleryFilter(moduleIDs: ["clip"], surfaces: [.compact], healths: [.ready], accessibility: [.standard])
    #expect(filter.isActive)
    filter = SaysoGalleryFilter()
    #expect(!filter.isActive)
}
