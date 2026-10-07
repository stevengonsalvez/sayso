import Foundation

/// UI test launch hook: `--ui-test-privacy mic|camera|both` swaps the real device reader for a fixed fake list of
/// one microphone and one camera, with the named ones on, so a UI test never depends on a real device being in use.
/// Honoured only together with `--ui-test-fresh-settings`, so a real launch always reads the real devices.
public enum PrivacyGuardUITestHook {
    /// The fake reader for a UI test launch, or nil to use the real one. A missing or unknown value gives a fake with
    /// nothing on, never the real devices.
    public static func port(arguments: [String]) -> PrivacyDevicePort? {
        guard arguments.contains("--ui-test-fresh-settings"), let flag = arguments.firstIndex(of: "--ui-test-privacy")
        else { return nil }
        let value = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : ""
        return FixedPrivacyDevicePort(list: [
            PrivacyDevice(id: "ui-test-mic", name: "UI Test Microphone", kind: .microphone, isRunning: value == "mic" || value == "both"),
            PrivacyDevice(id: "ui-test-camera", name: "UI Test Camera", kind: .camera, isRunning: value == "camera" || value == "both"),
        ])
    }
}

private struct FixedPrivacyDevicePort: PrivacyDevicePort {
    let list: [PrivacyDevice]

    func devices() throws(PrivacyDevicePortError) -> [PrivacyDevice] { list }
}
