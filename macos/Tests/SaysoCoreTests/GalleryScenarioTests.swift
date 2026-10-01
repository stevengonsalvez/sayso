import Foundation
import Testing
@testable import SaysoCore

@Test func galleryCoversEverySurfaceStateAndAccessibilityModeOfEachModule() {
    let clip = SaysoModuleDescriptor(
        id: "clip", title: "Clipboard", capabilities: [.clipboard], surfaces: [.compact, .expanded, .settings]
    )
    let timer = SaysoModuleDescriptor(id: "timer", title: "Timer", surfaces: [.compact, .peek])

    let scenarios = SaysoGallery.scenarios(for: [clip, timer])

    #expect(Set(scenarios.map(\.id)).count == scenarios.count)

    let clipStates = Set(scenarios.filter { $0.moduleID == "clip" }.map(\.health))
    #expect(clipStates == [.ready, .disabled, .permissionRequired, .degraded, .failed, .quarantined])
    let timerStates = Set(scenarios.filter { $0.moduleID == "timer" }.map(\.health))
    #expect(timerStates == [.ready, .disabled, .degraded, .failed, .quarantined])

    let clipSurfaces = Set(scenarios.filter { $0.moduleID == "clip" }.map(\.surface))
    #expect(clipSurfaces == [.compact, .expanded, .settings])

    let modes = Set(scenarios.map(\.accessibility))
    #expect(modes == [.standard, .reduceMotion, .increaseContrast])

    #expect(scenarios.filter { $0.moduleID == "clip" }.count == 3 * 6 * 3)
    #expect(scenarios.filter { $0.moduleID == "timer" }.count == 2 * 5 * 3)
}
