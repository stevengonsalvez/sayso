import AppKit
import SwiftUI
import Testing
import SaysoCore
@testable import SaysoGalleryUI

@MainActor
@Test func galleryBrowserRendersScenariosAtTheProposedSize() throws {
    let scenarios = SaysoGallery.scenarios(for: [
        SaysoModuleDescriptor(id: "clip", title: "Clipboard", capabilities: [.clipboard]),
        SaysoModuleDescriptor(id: "timer", title: "Timer"),
    ])
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
