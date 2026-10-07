import CoreAudio
import CoreMediaIO
import Foundation

/// Lists microphones through CoreAudio and cameras through CoreMediaIO, reading only public device properties: the
/// device list, each device's name and UID, whether it has input streams, and `DeviceIsRunningSomewhere`, which is
/// true while any process has the device on. Nothing is opened, recorded or sampled, so macOS asks for no Microphone
/// or Camera permission, and the system does not say which process uses a device.
///
/// Known limit: `DeviceIsRunningSomewhere` is per device, not per direction, so a device with both input and output
/// (a USB headset, for example) reads as on while only its speaker plays.
public struct CoreAudioMediaPrivacyPort: PrivacyDevicePort {
    public init() {}

    /// Throws only when a system device list cannot be read. A device that vanishes between the list and its
    /// properties, or whose on state cannot be read, is left out rather than guessed.
    public func devices() throws(PrivacyDevicePortError) -> [PrivacyDevice] {
        try microphones() + cameras()
    }

    // MARK: CoreAudio

    private func microphones() throws(PrivacyDevicePortError) -> [PrivacyDevice] {
        try audioDeviceIDs().compactMap { id in
            guard hasInputStreams(id), let running = audioUInt32(id, kAudioDevicePropertyDeviceIsRunningSomewhere) else { return nil }
            return PrivacyDevice(
                id: audioString(id, kAudioDevicePropertyDeviceUID) ?? "coreaudio-\(id)",
                name: audioString(id, kAudioObjectPropertyName) ?? "Microphone",
                kind: .microphone,
                isRunning: running != 0
            )
        }
    }

    private func audioDeviceIDs() throws(PrivacyDevicePortError) -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = audioAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { throw .unavailable }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { throw .unavailable }
        // The list can shrink between the two calls.
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private func hasInputStreams(_ id: AudioObjectID) -> Bool {
        var address = audioAddress(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private func audioUInt32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = audioAddress(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func audioString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = audioAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        // Copy semantics: the caller owns the string.
        return status == noErr ? value?.takeRetainedValue() as String? : nil
    }

    private func audioAddress(
        _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    // MARK: CoreMediaIO

    private func cameras() throws(PrivacyDevicePortError) -> [PrivacyDevice] {
        try cameraDeviceIDs().compactMap { id in
            guard let running = cameraUInt32(id, kCMIODevicePropertyDeviceIsRunningSomewhere) else { return nil }
            return PrivacyDevice(
                id: cameraString(id, kCMIODevicePropertyDeviceUID) ?? "cmio-\(id)",
                name: cameraString(id, kCMIOObjectPropertyName) ?? "Camera",
                kind: .camera,
                isRunning: running != 0
            )
        }
    }

    private func cameraDeviceIDs() throws(PrivacyDevicePortError) -> [CMIOObjectID] {
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var address = cameraAddress(kCMIOHardwarePropertyDevices)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { throw .unavailable }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &ids) == noErr else { throw .unavailable }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    private func cameraUInt32(_ id: CMIOObjectID, _ selector: Int) -> UInt32? {
        var address = cameraAddress(selector)
        var value: UInt32 = 0
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value)
        return status == noErr ? value : nil
    }

    private func cameraString(_ id: CMIOObjectID, _ selector: Int) -> String? {
        var address = cameraAddress(selector)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &value) {
            CMIOObjectGetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, $0)
        }
        // Copy semantics: the caller owns the string.
        return status == noErr ? value?.takeRetainedValue() as String? : nil
    }

    private func cameraAddress(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }
}
