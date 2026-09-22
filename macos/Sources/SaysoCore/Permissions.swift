import AVFoundation
import ApplicationServices
import Speech

public enum PermissionKind: String, CaseIterable, Identifiable, Sendable {
    case microphone
    case speechRecognition
    case accessibility
    case inputMonitoring

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .microphone: "Microphone"
        case .speechRecognition: "Speech Recognition"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        }
    }
}

public enum PermissionState: Sendable {
    case granted
    case denied
    case undetermined
    case unavailable
}

@MainActor
public final class PermissionCenter: ObservableObject {
    @Published public private(set) var states: [PermissionKind: PermissionState] = [:]

    public init() {
        refresh()
    }

    public func refresh() {
        states[.microphone] = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .undetermined
        @unknown default: .unavailable
        }
        states[.speechRecognition] = switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .undetermined
        @unknown default: .unavailable
        }
        states[.accessibility] = AXIsProcessTrusted() ? .granted : .denied
        // macOS exposes Input Monitoring only through System Settings. Recording the
        // trusted result for accessibility keeps onboarding honest without probing input.
        states[.inputMonitoring] = .undetermined
    }

    public func request(_ kind: PermissionKind) async {
        switch kind {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .speechRecognition:
            _ = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        case .accessibility:
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .inputMonitoring:
            break
        }
        refresh()
    }
}
