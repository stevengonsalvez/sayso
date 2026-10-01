import AppKit
import SwiftUI
import Testing
import SaysoCore
@testable import SaysoGalleryUI

private let scenarios = SaysoGallery.scenarios(for: [
    SaysoModuleDescriptor(id: "clip", title: "Clipboard", capabilities: [.clipboard]),
    SaysoModuleDescriptor(id: "timer", title: "Timer"),
])

/// ImageRenderer skips ScrollView, lazy stacks and native controls, so the real browser is
/// drawn through a live NSHostingView instead.
@MainActor
private func hostedBitmap(width: Int, height: Int) throws -> NSBitmapImageRep {
    let host = NSHostingView(rootView: SaysoGalleryView(scenarios: scenarios))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.titled], backing: .buffered, defer: false
    )
    window.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    host.layoutSubtreeIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep
}

@MainActor
@Test func hostedBrowserDrawsCardsNotJustChrome() throws {
    let rep = try hostedBitmap(width: 1100, height: 800)
    var seen = Set<String>()
    for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 4) { seen.insert(String(describing: rep.colorAt(x: x, y: y))) }
    }
    #expect(seen.count > 40)
    if let dir = ProcessInfo.processInfo.environment["SAYSO_GALLERY_PNG_DIR"],
       let data = rep.representation(using: .png, properties: [:]) {
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("browser-hosted.png"))
    }
}

@MainActor
@Test func galleryBrowserRendersScenariosAtTheProposedSize() throws {
    let renderer = ImageRenderer(content: SaysoGalleryView(scenarios: scenarios).frame(width: 1000, height: 700))
    renderer.scale = 1
    let rep = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
    #expect(rep.pixelsWide == 1000 && rep.pixelsHigh == 700)

    var seen = Set<String>()
    for y in stride(from: 0, to: rep.pixelsHigh, by: 5) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 5) { seen.insert(String(describing: rep.colorAt(x: x, y: y))) }
    }
    #expect(seen.count > 5)

    if let dir = ProcessInfo.processInfo.environment["SAYSO_GALLERY_PNG_DIR"],
       let data = rep.representation(using: .png, properties: [:]) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("browser.png"))
    }
}
