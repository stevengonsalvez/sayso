import Foundation
import Testing
@testable import SaysoCore

@Test func settingsPersistPreferredAudioInputUIDAndDefaultWhenMissing() throws {
    var settings = SaysoSettings()
    settings.preferredAudioInputUID = AudioInputDeviceUID(rawValue: "usb-mic")

    let saved = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(SaysoSettings.self, from: saved).preferredAudioInputUID == settings.preferredAudioInputUID)

    let legacy = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
    var withoutInput = legacy
    withoutInput.removeValue(forKey: "preferredAudioInputUID")
    let legacyData = try JSONSerialization.data(withJSONObject: withoutInput)
    #expect(try JSONDecoder().decode(SaysoSettings.self, from: legacyData).preferredAudioInputUID == nil)
}
