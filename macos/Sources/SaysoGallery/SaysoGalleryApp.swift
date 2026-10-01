import AppKit
import SwiftUI
import SaysoCore
import SaysoGalleryUI

private let demoDescriptors = [
    SaysoModuleDescriptor(
        id: "clip", title: "Clipboard", capabilities: [.clipboard],
        surfaces: Set(SaysoModuleSurface.allCases)
    ),
    SaysoModuleDescriptor(id: "timer", title: "Timer", surfaces: Set(SaysoModuleSurface.allCases)),
    SaysoModuleDescriptor(
        id: "media", title: "Media", capabilities: [.automation],
        surfaces: [.compact, .peek, .expanded, .detached]
    ),
]

final class GalleryAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct SaysoGalleryApp: App {
    @NSApplicationDelegateAdaptor(GalleryAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Sayso Gallery") {
            SaysoGalleryRootView(scenarios: SaysoGallery.scenarios(for: demoDescriptors))
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1200, height: 800)
    }
}
