import CoreAudio
import CoreMediaIO
import Foundation
import Testing
@testable import SaysoCore

/// The real adapter against this Mac's CoreAudio and CoreMediaIO. Only device properties are read, here and in the
/// adapter: nothing is opened, recorded or sampled, and no permission is asked for.
@Suite struct CoreAudioMediaPrivacyPortTests {
    @Test func itListsEveryBuiltInMicrophoneAndCameraTheSystemReportsWithoutThrowing() throws {
        let devices = try CoreAudioMediaPrivacyPort().devices()
        let microphones = Set(devices.filter { $0.kind == .microphone }.map(\.id))
        let cameras = Set(devices.filter { $0.kind == .camera }.map(\.id))
        let builtInMicrophones = Probe.builtInAudioInputUIDs()
        let builtInCameras = Probe.builtInCameraUIDs()
        // A CI virtual machine has no camera and may have no microphone: a built-in device is required to be listed
        // only where the system reports one, so the test holds on any hardware.
        #expect(builtInMicrophones.isSubset(of: microphones), "every built-in microphone is listed: \(devices)")
        #expect(builtInCameras.isSubset(of: cameras), "every built-in camera is listed: \(devices)")
        for device in devices {
            #expect(!device.id.isEmpty, "\(device)")
            #expect(!device.name.isEmpty, "\(device)")
        }
        #expect(microphones.count == devices.filter { $0.kind == .microphone }.count, "one entry per microphone")
        #expect(cameras.count == devices.filter { $0.kind == .camera }.count, "one entry per camera")
        // Logged so the proof ledger can quote what this Mac reported, not only that it passed.
        print("PRIVACY-PORT-OBSERVED " + devices.map { "\($0.kind.rawValue)=\"\($0.name)\" running=\($0.isRunning)" }.joined(separator: " "))
    }

    @Test func listingTwiceGivesTheSameDevices() throws {
        let port = CoreAudioMediaPrivacyPort()
        let first = try port.devices().map { "\($0.kind.rawValue)|\($0.id)|\($0.name)" }
        let second = try port.devices().map { "\($0.kind.rawValue)|\($0.id)|\($0.name)" }
        #expect(first.sorted() == second.sorted())
    }

    /// `DeviceIsRunning` is this process's own use of a device, where `DeviceIsRunningSomewhere`, which the adapter
    /// reads, is any process's. Neither listing may leave this process using a device.
    @Test func listingNeverSwitchesADeviceOnInThisProcess() throws {
        let port = CoreAudioMediaPrivacyPort()
        _ = try port.devices()
        _ = try port.devices()
        let audio = Probe.audioDeviceIDs()
        let video = Probe.cameraDeviceIDs()
        for id in audio { #expect(Probe.audioIsRunningHere(id) == false, "audio device \(id)") }
        for id in video { #expect(Probe.cameraIsRunningHere(id) == false, "camera \(id)") }
    }

    /// The adapter and the rest of the module may import only Foundation, CoreAudio and CoreMediaIO, and may name no
    /// capture, recording or IO API, so nothing in it can open a device or make macOS ask for a permission.
    @Test func thePrivacyGuardSourcesUseNoCaptureOrRecordingAPI() throws {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SaysoCore/PrivacyGuard", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.map(\.lastPathComponent).contains("CoreAudioMediaPrivacyPort.swift"))
        let forbidden = [
            "AVFoundation", "AVCapture", "AVAudio", "AudioUnit", "AudioComponent", "AudioOutputUnit", "AUGraph",
            "AudioQueue", "AudioDeviceStart", "AudioDeviceCreateIOProc", "IOProc", "CMIODeviceStartStream",
            "CMIOStreamCopyBufferQueue", "CMSampleBuffer", "ScreenCaptureKit", "requestAccess", "authorizationStatus",
        ]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let imports = text.split(separator: "\n").filter { $0.hasPrefix("import ") }.map { String($0.dropFirst(7)) }
            #expect(Set(imports).isSubset(of: ["Foundation", "CoreAudio", "CoreMediaIO"]), "\(file.lastPathComponent) imports \(imports)")
            for name in forbidden {
                #expect(!text.contains(name), "\(file.lastPathComponent) names \(name)")
            }
        }
    }
}

/// The test's own property reads, independent of the adapter's.
private enum Probe {
    static func audioDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func audioUInt32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func audioIsRunningHere(_ id: AudioObjectID) -> Bool? {
        audioUInt32(id, kAudioDevicePropertyDeviceIsRunning).map { $0 != 0 }
    }

    static func builtInAudioInputUIDs() -> Set<String> {
        Set(audioDeviceIDs().compactMap { id -> String? in
            guard audioUInt32(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn else { return nil }
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain
            )
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
            address.mSelector = kAudioDevicePropertyDeviceUID
            address.mScope = kAudioObjectPropertyScopeGlobal
            var uid: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard withUnsafeMutablePointer(to: &uid, { AudioObjectGetPropertyData(id, &address, 0, nil, &uidSize, $0) }) == noErr
            else { return nil }
            return uid?.takeRetainedValue() as String?
        })
    }

    static func cameraDeviceIDs() -> [CMIOObjectID] {
        var address = cmioAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &ids) == noErr
        else { return [] }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    static func cmioUInt32(_ id: CMIOObjectID, _ selector: Int) -> UInt32? {
        var address = cmioAddress(CMIOObjectPropertySelector(selector))
        var value: UInt32 = 0
        var used: UInt32 = 0
        return CMIOObjectGetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == noErr ? value : nil
    }

    static func cameraIsRunningHere(_ id: CMIOObjectID) -> Bool? {
        cmioUInt32(id, kCMIODevicePropertyDeviceIsRunning).map { $0 != 0 }
    }

    static func builtInCameraUIDs() -> Set<String> {
        Set(cameraDeviceIDs().compactMap { id -> String? in
            guard cmioUInt32(id, kCMIODevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn else { return nil }
            var address = cmioAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID))
            var uid: Unmanaged<CFString>?
            var used: UInt32 = 0
            let status = withUnsafeMutablePointer(to: &uid) {
                CMIOObjectGetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, $0)
            }
            return status == noErr ? uid?.takeRetainedValue() as String? : nil
        })
    }

    private static func cmioAddress(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }
}
