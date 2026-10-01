import Foundation
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

// MARK: System accessibility settings

@Test func pulseIsDisabledByScenarioModeOrSystemReduceMotion() throws {
    let standard = SaysoGalleryCardPresentation(scenario: try scenario(health: .ready))
    let still = SaysoGalleryCardPresentation(scenario: try scenario(health: .ready, mode: .reduceMotion))
    #expect(standard.pulseEnabled(systemReduceMotion: false))
    #expect(!standard.pulseEnabled(systemReduceMotion: true))
    #expect(!still.pulseEnabled(systemReduceMotion: false))
    #expect(!still.pulseEnabled(systemReduceMotion: true))
}

@Test func highContrastHonoursScenarioModeOrSystemSetting() throws {
    let standard = SaysoGalleryCardPresentation(scenario: try scenario(health: .ready))
    let contrast = SaysoGalleryCardPresentation(scenario: try scenario(health: .ready, mode: .increaseContrast))
    #expect(!standard.usesHighContrast(systemIncreaseContrast: false))
    #expect(standard.usesHighContrast(systemIncreaseContrast: true))
    #expect(contrast.usesHighContrast(systemIncreaseContrast: false))
}

// MARK: Action pills

@Test func actionPillsAreOnlyOfferedWhenAHandlerExists() throws {
    let grant = SaysoGalleryCardPresentation(scenario: try scenario(health: .permissionRequired))
    let retry = SaysoGalleryCardPresentation(scenario: try scenario(health: .failed))
    #expect(grant.offersGrantAction(hasHandler: true))
    #expect(!grant.offersGrantAction(hasHandler: false))
    #expect(!grant.offersRetryAction(hasHandler: true))
    #expect(retry.offersRetryAction(hasHandler: true))
    #expect(!retry.offersRetryAction(hasHandler: false))
    #expect(!retry.offersGrantAction(hasHandler: true))
}

@Test func actionSummaryNamesTheActionAndScenario() {
    #expect(SaysoGalleryCardPresentation.actionSummary(.grant, scenarioID: "clip.peek") == "Grant requested: clip.peek")
    #expect(SaysoGalleryCardPresentation.actionSummary(.retry, scenarioID: "timer.detail") == "Retry requested: timer.detail")
}

// MARK: WCAG contrast

private func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
private func luminance(_ rgb: (r: Double, g: Double, b: Double)) -> Double {
    0.2126 * linear(rgb.r) + 0.7152 * linear(rgb.g) + 0.0722 * linear(rgb.b)
}
private func contrastRatio(_ a: Double, _ b: Double) -> Double {
    (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

/// White text at `alpha` composited over the lightest card background (worst case for white text).
private func secondaryContrast(_ p: SaysoGalleryCardPresentation, highContrast: Bool) -> Double {
    let bg = SaysoGalleryCardPresentation.surfaceTop
    let a = p.secondaryTextOpacity(highContrast: highContrast)
    let fg = (r: a + (1 - a) * bg.r, g: a + (1 - a) * bg.g, b: a + (1 - a) * bg.b)
    return contrastRatio(luminance(fg), luminance(bg))
}

@Test func secondaryTextMeetsWCAGAANormalTextWhenIncreaseContrastIsOn() throws {
    for health in [SaysoModuleHealth.ready, .disabled, .permissionRequired, .degraded, .failed, .quarantined] {
        let p = SaysoGalleryCardPresentation(scenario: try scenario(health: health))
        let ratio = secondaryContrast(p, highContrast: true)
        #expect(ratio >= 4.5, "\(health) contrast \(ratio)")
    }
}

@Test func standardSecondaryTextOfEnabledCardsMeetsWCAGAA() throws {
    let p = SaysoGalleryCardPresentation(scenario: try scenario(health: .ready))
    #expect(secondaryContrast(p, highContrast: false) >= 4.5)
}
