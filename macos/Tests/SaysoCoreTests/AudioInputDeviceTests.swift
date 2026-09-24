import Foundation
import Testing
@testable import SaysoCore

@Test func audioInputDeviceUIDPersistsAsItsStableString() throws {
    let uid = try #require(AudioInputDeviceUID(rawValue: "com.example.microphone"))

    let data = try JSONEncoder().encode(uid)

    #expect(String(decoding: data, as: UTF8.self) == "\"com.example.microphone\"")
    #expect(try JSONDecoder().decode(AudioInputDeviceUID.self, from: data) == uid)
}

@Test func selectedInputRestoresPreviousDefaultAfterFinalLease() async {
    let previous = uid("built-in")
    let selected = uid("usb-mic")
    let controller = FakeAudioInputDeviceController(devices: [previous, selected], defaultUID: previous)
    let coordinator = AudioInputDeviceLeaseCoordinator(controller: controller)

    let lease = await coordinator.acquire(preferredDeviceUID: selected)
    await coordinator.release(lease)

    #expect(controller.setCalls == [selected, previous])
    #expect(controller.defaultUID == previous)
}

@Test func matchingSelectionsShareOneTemporaryDefaultUntilFinalLease() async {
    let previous = uid("built-in")
    let selected = uid("usb-mic")
    let controller = FakeAudioInputDeviceController(devices: [previous, selected], defaultUID: previous)
    let coordinator = AudioInputDeviceLeaseCoordinator(controller: controller)

    let first = await coordinator.acquire(preferredDeviceUID: selected)
    let second = await coordinator.acquire(preferredDeviceUID: selected)
    await coordinator.release(first)

    #expect(controller.setCalls == [selected])
    #expect(controller.defaultUID == selected)

    await coordinator.release(second)

    #expect(controller.setCalls == [selected, previous])
    #expect(controller.defaultUID == previous)
}

@Test func userDefaultChangeDuringLeaseIsNeverRestoredOver() async {
    let previous = uid("built-in")
    let selected = uid("usb-mic")
    let userChoice = uid("display-mic")
    let controller = FakeAudioInputDeviceController(
        devices: [previous, selected, userChoice], defaultUID: previous
    )
    let coordinator = AudioInputDeviceLeaseCoordinator(controller: controller)

    let lease = await coordinator.acquire(preferredDeviceUID: selected)
    controller.defaultUID = userChoice
    await coordinator.release(lease)

    #expect(controller.setCalls == [selected])
    #expect(controller.defaultUID == userChoice)
}

@Test func unavailableSelectedInputLeavesDefaultUntouched() async {
    let previous = uid("built-in")
    let unavailable = uid("unplugged-usb-mic")
    let controller = FakeAudioInputDeviceController(devices: [previous], defaultUID: previous)
    let coordinator = AudioInputDeviceLeaseCoordinator(controller: controller)

    let lease = await coordinator.acquire(preferredDeviceUID: unavailable)
    await coordinator.release(lease)

    #expect(controller.setCalls.isEmpty)
    #expect(controller.defaultUID == previous)
}

private func uid(_ value: String) -> AudioInputDeviceUID {
    AudioInputDeviceUID(rawValue: value)!
}

private final class FakeAudioInputDeviceController: AudioInputDeviceControlling, @unchecked Sendable {
    let deviceUIDs: [AudioInputDeviceUID]
    var defaultUID: AudioInputDeviceUID?
    var setCalls: [AudioInputDeviceUID] = []

    init(devices: [AudioInputDeviceUID], defaultUID: AudioInputDeviceUID?) {
        deviceUIDs = devices
        self.defaultUID = defaultUID
    }

    func inputDevices() -> [AudioInputDevice] {
        deviceUIDs.map {
            AudioInputDevice(
                uid: $0,
                name: $0.rawValue,
                manufacturer: "",
                inputChannelCount: 1,
                nominalSampleRate: 48_000,
                isDefault: $0 == defaultUID
            )
        }
    }

    func defaultInputDeviceUID() -> AudioInputDeviceUID? {
        defaultUID
    }

    @discardableResult
    func setDefaultInputDevice(to uid: AudioInputDeviceUID) -> Bool {
        guard deviceUIDs.contains(uid) else { return false }
        setCalls.append(uid)
        defaultUID = uid
        return true
    }
}
