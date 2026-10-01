import AppKit
import SwiftUI
import Testing
import SaysoCore
@testable import SaysoGalleryUI

private let allSurfaces = Set(SaysoModuleSurface.allCases)
private let descriptors = [
    SaysoModuleDescriptor(id: "clip", title: "Clipboard", capabilities: [.clipboard], surfaces: allSurfaces),
    SaysoModuleDescriptor(id: "timer", title: "Timer", surfaces: allSurfaces),
    SaysoModuleDescriptor(id: "media", title: "Media", surfaces: allSurfaces),
]
private let scenarios = SaysoGallery.scenarios(for: descriptors)

@MainActor
private func bitmap(_ scenario: SaysoGalleryScenario) -> NSBitmapImageRep? {
    let renderer = ImageRenderer(content: SaysoGalleryScenarioCard(scenario: scenario))
    renderer.scale = 1
    return renderer.cgImage.map { NSBitmapImageRep(cgImage: $0) }
}

@MainActor
private func png(_ scenario: SaysoGalleryScenario) -> Data? {
    bitmap(scenario)?.representation(using: .png, properties: [:])
}

@MainActor
private func distinctColors(_ rep: NSBitmapImageRep) -> Int {
    var seen = Set<String>()
    for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
            seen.insert(String(describing: rep.colorAt(x: x, y: y)))
        }
    }
    return seen.count
}

@MainActor
private func pick(_ module: String, _ surface: SaysoModuleSurface, _ health: SaysoModuleHealth,
                  _ mode: SaysoAccessibilityMode = .standard) throws -> SaysoGalleryScenario {
    try #require(scenarios.first {
        $0.moduleID == module && $0.surface == surface && $0.health == health && $0.accessibility == mode
    })
}

@MainActor
@Test func everyScenarioRendersANonEmptyPNGAtItsSurfaceSize() throws {
    #expect(scenarios.count == 288)
    for scenario in scenarios {
        let rep = try #require(bitmap(scenario), "\(scenario.id) produced no image")
        let size = SaysoGalleryScenarioCard.size(for: scenario.surface)
        #expect(rep.pixelsWide == Int(size.width) && rep.pixelsHigh == Int(size.height), "\(scenario.id) size")
        let data = try #require(rep.representation(using: .png, properties: [:]))
        #expect(!data.isEmpty, "\(scenario.id) empty PNG")
        #expect(distinctColors(rep) > 3, "\(scenario.id) looks blank")
    }
}

@MainActor
@Test func surfaceSizesAreDistinctPerSurfaceKind() {
    let sizes = SaysoModuleSurface.allCases.map(SaysoGalleryScenarioCard.size(for:))
    #expect(Set(sizes.map { "\($0.width)x\($0.height)" }).count == SaysoModuleSurface.allCases.count)
    let compact = SaysoGalleryScenarioCard.size(for: .compact)
    #expect(compact.height < SaysoGalleryScenarioCard.size(for: .peek).height)
    #expect(compact.width < SaysoGalleryScenarioCard.size(for: .expanded).width)
}

@MainActor
@Test func renderingIsDeterministic() {
    for scenario in scenarios {
        #expect(png(scenario) == png(scenario), "\(scenario.id) differs between renders")
    }
}

@MainActor
@Test func healthAndContrastChangeThePixels() throws {
    for surface in [SaysoModuleSurface.compact, .expanded, .detail] {
        let ready = png(try pick("clip", surface, .ready))
        #expect(ready != png(try pick("clip", surface, .permissionRequired)), "\(surface) permission")
        #expect(ready != png(try pick("clip", surface, .failed)), "\(surface) failed")
        #expect(ready != png(try pick("clip", surface, .disabled)), "\(surface) disabled")
        #expect(ready != png(try pick("clip", surface, .ready, .increaseContrast)), "\(surface) contrast")
    }
}

/// Opt-in: SAYSO_GALLERY_PNG_DIR=<dir> swift test --filter writesSamplePNGs
@MainActor
@Test func writesSamplePNGsWhenRequested() throws {
    guard let dir = ProcessInfo.processInfo.environment["SAYSO_GALLERY_PNG_DIR"] else { return }
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for s in scenarios where s.id.hasPrefix("clip.") && s.accessibility == .standard {
        let data = try #require(png(s))
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(s.id).png"))
    }
}
