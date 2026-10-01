import Testing
import SaysoCore
@testable import SaysoGalleryUI

private func scenario(
    health: SaysoModuleHealth, mode: SaysoAccessibilityMode = .standard
) throws -> SaysoGalleryScenario {
    let clip = SaysoModuleDescriptor(id: "clip", title: "Clipboard", capabilities: [.clipboard])
    return try #require(
        SaysoGallery.scenarios(for: [clip]).first {
            $0.health == health && $0.accessibility == mode && $0.surface == .expanded
        }
    )
}

@Test func permissionRequiredShowsGrantPromptAndNoRetry() throws {
    let p = SaysoGalleryCardPresentation(scenario: try scenario(health: .permissionRequired))
    #expect(p.showsGrantPrompt)
    #expect(!p.showsRetry)
}

@Test func failedAndQuarantinedShowErrorWithRetry() throws {
    for health in [SaysoModuleHealth.failed, .quarantined] {
        let p = SaysoGalleryCardPresentation(scenario: try scenario(health: health))
        #expect(p.showsRetry)
        #expect(p.tone == .error)
        #expect(!p.showsGrantPrompt)
    }
}

@Test func disabledIsMutedAndOffersNoActions() throws {
    let p = SaysoGalleryCardPresentation(scenario: try scenario(health: .disabled))
    #expect(p.isMuted)
    #expect(!p.showsRetry && !p.showsGrantPrompt)
}

@Test func readyHasNoPromptsAndIsNotMuted() throws {
    let p = SaysoGalleryCardPresentation(scenario: try scenario(health: .ready))
    #expect(!p.isMuted && !p.showsRetry && !p.showsGrantPrompt)
    #expect(p.statusLabel == "Ready")
}

@Test func accessibilityModesDriveMotionAndContrast() throws {
    let standard = SaysoGalleryCardPresentation(scenario: try scenario(health: .ready))
    let still = SaysoGalleryCardPresentation(scenario: try scenario(health: .ready, mode: .reduceMotion))
    let contrast = SaysoGalleryCardPresentation(scenario: try scenario(health: .ready, mode: .increaseContrast))
    #expect(standard.animationsEnabled && !standard.highContrast)
    #expect(!still.animationsEnabled)
    #expect(contrast.highContrast)
}
