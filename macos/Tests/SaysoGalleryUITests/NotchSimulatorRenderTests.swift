import AppKit
import SwiftUI
import Testing
import SaysoCore
@testable import SaysoGalleryUI

private let size = NSSize(width: 980, height: 560)

@MainActor
private func distinctColors(_ rep: NSBitmapImageRep, step: Int = 4, in rect: NSRect? = nil) -> Int {
    let area = rect ?? NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
    var seen = Set<String>()
    for y in stride(from: Int(area.minY), to: Int(area.maxY), by: step) {
        for x in stride(from: Int(area.minX), to: Int(area.maxX), by: step) {
            seen.insert(String(describing: rep.colorAt(x: x, y: y)))
        }
    }
    return seen.count
}

@MainActor
private func render<V: View>(_ view: V) throws -> NSBitmapImageRep {
    let host = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    host.layoutSubtreeIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep
}

@MainActor
private func save(_ rep: NSBitmapImageRep, as name: String) throws {
    guard let dir = ProcessInfo.processInfo.environment["SAYSO_GALLERY_PNG_DIR"],
          let data = rep.representation(using: .png, properties: [:]) else { return }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
}

@MainActor
private func model(_ surface: NotchSurfaceMachine.Surface) -> SaysoNotchSimulatorModel {
    let model = SaysoNotchSimulatorModel(startsHidden: surface == .hidden)
    model.inject(.persistentTask)
    switch surface {
    case .hidden, .closed: break
    case .peek:
        model.hover(.entered)
        model.advance(0.06)
    case .expanded:
        model.click(.background)
    }
    return model
}

@MainActor
@Test(arguments: [NotchSurfaceMachine.Surface.hidden, .closed, .peek, .expanded])
func simulatorRendersNonBlankForEverySurface(surface: NotchSurfaceMachine.Surface) throws {
    let sim = model(surface)
    #expect(sim.surface == surface)
    let rep = try render(SaysoNotchSimulatorView(model: sim))
    #expect(distinctColors(rep) > 12)
    try save(rep, as: "simulator-\(surface).png")
}

@MainActor
@Test func expandedSurfaceDrawsMoreThanTheClosedPill() throws {
    let stage = NSRect(x: 230, y: 0, width: 750, height: 200)  // notch stage, right of the side panel
    let closed = try render(SaysoNotchSimulatorView(model: model(.closed)))
    let expanded = try render(SaysoNotchSimulatorView(model: model(.expanded)))
    #expect(distinctColors(expanded, step: 2, in: stage) > distinctColors(closed, step: 2, in: stage))
}

@MainActor
@Test func criticalConfirmationRendersOverTheExpandedSurface() throws {
    let sim = model(.expanded)
    sim.inject(.criticalConfirmation)
    let rep = try render(SaysoNotchSimulatorView(model: sim))
    #expect(distinctColors(rep) > 12)
    try save(rep, as: "simulator-critical.png")
}

@MainActor
@Test func galleryRootOffersBrowserAndSimulatorTabs() throws {
    #expect(SaysoGalleryRootView.Tab.allCases.map(\.title) == ["Browser", "Simulator"])
    let rep = try render(SaysoGalleryRootView(scenarios: [], initialTab: .simulator))
    #expect(distinctColors(rep) > 12)
}
