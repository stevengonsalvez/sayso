import Foundation
import Testing
@testable import SaysoCore

@Test func hotKeyActivationSettingsPersistAndClampSafely() throws {
    var settings = SaysoSettings()
    settings.hotKeyActivation = .both
    settings.hotKeyHoldThresholdSeconds = 0.6

    let saved = try JSONEncoder().encode(settings)
    let restored = try JSONDecoder().decode(SaysoSettings.self, from: saved)
    #expect(restored.hotKeyActivation == .both)
    #expect(restored.hotKeyHoldThresholdSeconds == 0.6)

    var malformed = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
    malformed["hotKeyHoldThresholdSeconds"] = 99
    let decoded = try JSONDecoder().decode(
        SaysoSettings.self,
        from: JSONSerialization.data(withJSONObject: malformed)
    )
    #expect(decoded.hotKeyHoldThresholdSeconds == 1)
}

@Test func hotKeyActivationModesExposeOnlyTheirConfiguredGestures() {
    #expect(DictationHotKeyActivation.tapToToggle.usesTapToggle)
    #expect(!DictationHotKeyActivation.tapToToggle.usesPressAndHold)
    #expect(!DictationHotKeyActivation.pressAndHold.usesTapToggle)
    #expect(DictationHotKeyActivation.pressAndHold.usesPressAndHold)
    #expect(DictationHotKeyActivation.both.usesTapToggle)
    #expect(DictationHotKeyActivation.both.usesPressAndHold)
}
