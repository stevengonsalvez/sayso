import CoreAudio
import Foundation

/// Stable Core Audio device identifier, suitable for persisted microphone preferences.
public struct AudioInputDeviceUID: Codable, Equatable, Hashable, Identifiable, Sendable, RawRepresentable {
    public let rawValue: String

    public var id: String { rawValue }

    public init?(rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        self.rawValue = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let uid = Self(rawValue: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Audio input device UID is empty")
        }
        self = uid
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// An input-capable Core Audio device, identified by its stable UID rather than transient device ID.
public struct AudioInputDevice: Codable, Equatable, Identifiable, Sendable {
    public let uid: AudioInputDeviceUID
    public let name: String
    public let manufacturer: String
    public let inputChannelCount: UInt32
    public let nominalSampleRate: Double
    public let isDefault: Bool

    public var id: AudioInputDeviceUID { uid }

    public var displayName: String {
        guard !manufacturer.isEmpty, !name.localizedCaseInsensitiveContains(manufacturer) else {
            return name
        }
        return "\(name) (\(manufacturer))"
    }

    public init(
        uid: AudioInputDeviceUID,
        name: String,
        manufacturer: String,
        inputChannelCount: UInt32,
        nominalSampleRate: Double,
        isDefault: Bool
    ) {
        self.uid = uid
        self.name = name
        self.manufacturer = manufacturer
        self.inputChannelCount = inputChannelCount
        self.nominalSampleRate = nominalSampleRate
        self.isDefault = isDefault
    }
}

/// Core Audio boundary for device enumeration and default-input changes.
public protocol AudioInputDeviceControlling: Sendable {
    func inputDevices() -> [AudioInputDevice]
    func defaultInputDeviceUID() -> AudioInputDeviceUID?
    @discardableResult func setDefaultInputDevice(to uid: AudioInputDeviceUID) -> Bool
}

/// Native Core Audio implementation of ``AudioInputDeviceControlling``.
public final class CoreAudioInputDeviceController: AudioInputDeviceControlling, @unchecked Sendable {
    public init() {}

    public func inputDevices() -> [AudioInputDevice] {
        let defaultDeviceID = currentDefaultInputDeviceID()
        let devices = audioDeviceIDs().compactMap { deviceID -> AudioInputDevice? in
            guard
                let uid = uid(for: deviceID),
                let stableUID = AudioInputDeviceUID(rawValue: uid)
            else {
                return nil
            }

            let channelCount = inputChannelCount(for: deviceID)
            guard channelCount > 0 else { return nil }

            return AudioInputDevice(
                uid: stableUID,
                name: stringProperty(selector: kAudioObjectPropertyName, deviceID: deviceID) ?? "Unknown",
                manufacturer: stringProperty(selector: kAudioObjectPropertyManufacturer, deviceID: deviceID) ?? "",
                inputChannelCount: channelCount,
                nominalSampleRate: doubleProperty(selector: kAudioDevicePropertyNominalSampleRate, deviceID: deviceID) ?? 0,
                isDefault: deviceID == defaultDeviceID
            )
        }

        return devices.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            let order = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            return order == .orderedAscending || (order == .orderedSame && lhs.uid.rawValue < rhs.uid.rawValue)
        }
    }

    public func defaultInputDeviceUID() -> AudioInputDeviceUID? {
        guard let deviceID = currentDefaultInputDeviceID(), let uid = uid(for: deviceID) else {
            return nil
        }
        return AudioInputDeviceUID(rawValue: uid)
    }

    @discardableResult
    public func setDefaultInputDevice(to uid: AudioInputDeviceUID) -> Bool {
        guard let deviceID = deviceID(for: uid), inputChannelCount(for: deviceID) > 0 else {
            return false
        }
        guard currentDefaultInputDeviceID() != deviceID else { return true }

        var newDeviceID = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            size,
            &newDeviceID
        ) == noErr
    }

    private func audioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        let status = deviceIDs.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, bytes.baseAddress!
            )
        }
        return status == noErr ? deviceIDs : []
    }

    private func currentDefaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    private func deviceID(for uid: AudioInputDeviceUID) -> AudioDeviceID? {
        var uidCharacters = Array(uid.rawValue.utf8CString)
        var deviceID = AudioDeviceID()
        let status = uidCharacters.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return kAudioHardwareBadDeviceError }
            return withUnsafeMutablePointer(to: &deviceID) { devicePointer in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(baseAddress),
                    mInputDataSize: UInt32(buffer.count),
                    mOutputData: UnsafeMutableRawPointer(devicePointer),
                    mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                var translationSize = UInt32(MemoryLayout<AudioValueTranslation>.size)
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                return AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    0,
                    nil,
                    &translationSize,
                    &translation
                )
            }
        }
        return status == noErr ? deviceID : nil
    }

    private func uid(for deviceID: AudioDeviceID) -> String? {
        stringProperty(selector: kAudioDevicePropertyDeviceUID, deviceID: deviceID)
    }

    private func inputChannelCount(for deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return 0
        }

        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBuffer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, rawBuffer) == noErr else {
            return 0
        }

        let audioBufferList = rawBuffer.bindMemory(to: AudioBufferList.self, capacity: 1)
        return UnsafeMutableAudioBufferListPointer(audioBufferList).reduce(0) { $0 + $1.mNumberChannels }
    }

    private func stringProperty(selector: AudioObjectPropertySelector, deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? value as String : nil
    }

    private func doubleProperty(selector: AudioObjectPropertySelector, deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = Double()
        var size = UInt32(MemoryLayout<Double>.size)
        return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
}

/// Opaque ownership token for one selected-input capture session.
public struct AudioInputDeviceLease: Sendable {
    fileprivate let id: UUID?
    fileprivate let selectedDeviceUID: AudioInputDeviceUID?
}

/// Coordinates temporary default-input changes across concurrent capture sessions.
public actor AudioInputDeviceLeaseCoordinator {
    private let controller: any AudioInputDeviceControlling
    private var activeLeaseIDs: Set<UUID> = []
    private var selectedDeviceUID: AudioInputDeviceUID?
    private var previousDefaultDeviceUID: AudioInputDeviceUID?

    public init(controller: any AudioInputDeviceControlling = CoreAudioInputDeviceController()) {
        self.controller = controller
    }

    /// Applies an available selected input for the duration of a capture session.
    /// A concurrent request for another selected input leaves the active route unchanged.
    public func acquire(preferredDeviceUID: AudioInputDeviceUID?) -> AudioInputDeviceLease {
        guard let preferredDeviceUID else {
            return AudioInputDeviceLease(id: nil, selectedDeviceUID: nil)
        }
        guard controller.inputDevices().contains(where: { $0.uid == preferredDeviceUID }) else {
            return AudioInputDeviceLease(id: nil, selectedDeviceUID: nil)
        }

        if let selectedDeviceUID {
            guard selectedDeviceUID == preferredDeviceUID else {
                return AudioInputDeviceLease(id: nil, selectedDeviceUID: nil)
            }
            let id = UUID()
            activeLeaseIDs.insert(id)
            return AudioInputDeviceLease(id: id, selectedDeviceUID: preferredDeviceUID)
        }

        guard let previousDefaultDeviceUID = controller.defaultInputDeviceUID() else {
            return AudioInputDeviceLease(id: nil, selectedDeviceUID: nil)
        }
        guard previousDefaultDeviceUID != preferredDeviceUID else {
            return AudioInputDeviceLease(id: nil, selectedDeviceUID: nil)
        }
        guard controller.setDefaultInputDevice(to: preferredDeviceUID),
              controller.defaultInputDeviceUID() == preferredDeviceUID else {
            return AudioInputDeviceLease(id: nil, selectedDeviceUID: nil)
        }

        let id = UUID()
        selectedDeviceUID = preferredDeviceUID
        self.previousDefaultDeviceUID = previousDefaultDeviceUID
        activeLeaseIDs.insert(id)
        return AudioInputDeviceLease(id: id, selectedDeviceUID: preferredDeviceUID)
    }

    /// Restores the pre-capture default after the final lease, unless macOS now uses another input.
    public func release(_ lease: AudioInputDeviceLease) {
        guard let id = lease.id,
              let selectedDeviceUID,
              lease.selectedDeviceUID == selectedDeviceUID,
              activeLeaseIDs.remove(id) != nil else {
            return
        }
        guard activeLeaseIDs.isEmpty else { return }

        let previousDefaultDeviceUID = previousDefaultDeviceUID
        self.selectedDeviceUID = nil
        self.previousDefaultDeviceUID = nil
        guard controller.defaultInputDeviceUID() == selectedDeviceUID,
              let previousDefaultDeviceUID else {
            return
        }
        controller.setDefaultInputDevice(to: previousDefaultDeviceUID)
    }
}
