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
private func distinctSampleCount(_ rep: NSBitmapImageRep, step: Int) -> Int {
    var seen = Set<String>()
    for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
        for x in stride(from: 0, to: rep.pixelsWide, by: step) { seen.insert(String(describing: rep.colorAt(x: x, y: y))) }
    }
    return seen.count
}

@MainActor
private func hostedBitmap(width: Int, height: Int) throws -> NSBitmapImageRep {
    let host = NSHostingView(rootView: SaysoGalleryView(scenarios: scenarios))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.titled], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false  // ARC owns the window; the default would over-release it on close
    defer { window.close() }
    window.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    host.layoutSubtreeIfNeeded()
    // Bounded poll: pump the run loop until the lazy grid has drawn content, at most 5s.
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        host.layoutSubtreeIfNeeded()
        if let probe = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: probe)
            if distinctSampleCount(probe, step: 4) > 40 { break }
        }
    }
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep
}

@MainActor
@Test func hostedBrowserDrawsCardsNotJustChrome() throws {
    let rep = try hostedBitmap(width: 1100, height: 800)
    #expect(distinctSampleCount(rep, step: 4) > 40)
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
