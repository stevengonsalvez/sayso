import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
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

    public var settingsURL: URL {
        switch self {
        case .microphone:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .speechRecognition:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!
        case .accessibility:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .inputMonitoring:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        }
    }
}

public enum PermissionState: Sendable {
    case granted
    case denied
    case undetermined
    case unavailable
}

private final class PermissionRefreshObserver: @unchecked Sendable {
    let token: NSObjectProtocol

    init(token: NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}

@MainActor
public final class PermissionCenter: ObservableObject {
    @Published public private(set) var states: [PermissionKind: PermissionState] = [:]
    private var didBecomeActiveObserver: PermissionRefreshObserver?

    public init() {
        refresh()
        let token = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        didBecomeActiveObserver = PermissionRefreshObserver(token: token)
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
        let accessibilityGranted = AXIsProcessTrusted()
        states[.accessibility] = accessibilityGranted ? .granted : .denied
        // Accessibility also grants the event-listening capability required by a
        // global monitor. Otherwise, use the public preflight without prompting.
        states[.inputMonitoring] = CGPreflightListenEventAccess() || accessibilityGranted ? .granted : .denied
    }

    public func request(_ kind: PermissionKind) async {
        refresh()
        NSApplication.shared.activate(ignoringOtherApps: true)
        await Task.yield()
        switch kind {
        case .microphone:
            if states[.microphone] == .undetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            } else if states[.microphone] == .denied {
                openSettings(for: kind)
            }
        case .speechRecognition:
            if states[.speechRecognition] == .undetermined {
                _ = await withCheckedContinuation { continuation in
                    SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
                }
            } else if states[.speechRecognition] == .denied {
                openSettings(for: kind)
            }
        case .accessibility:
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            openSettings(for: kind)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
            openSettings(for: kind)
        }
        // TCC can report its prior state for one main-run-loop turn after its sheet closes.
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(150))
        refresh()
    }

    private func openSettings(for kind: PermissionKind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }
}
