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

enum PermissionInteraction: Equatable, Sendable {
    case none
    case nativePrompt
    case systemSettings
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
        states[.accessibility] = AXIsProcessTrusted() ? .granted : .denied
        // Report the Input Monitoring grant itself, not a capability implied by
        // another permission, so each row reflects its own System Settings toggle.
        states[.inputMonitoring] = CGPreflightListenEventAccess() ? .granted : .denied
    }

    /// Resolves a permission for a flow that is already underway, such as
    /// dictation. Decided permissions return immediately without activating
    /// Sayso or opening System Settings, so the user's target app keeps focus.
    /// Only an undetermined microphone or speech grant shows the native prompt.
    public func authorize(_ kind: PermissionKind) async -> PermissionState {
        refresh()
        guard Self.interaction(for: kind, state: states[kind]) == .nativePrompt else {
            return states[kind] ?? .unavailable
        }
        await prompt(kind)
        return states[kind] ?? .unavailable
    }

    /// Explicit request from the permission UI. Prompts when undetermined,
    /// otherwise opens the matching System Settings pane when not granted.
    public func request(_ kind: PermissionKind) async {
        refresh()
        switch Self.interaction(for: kind, state: states[kind]) {
        case .none:
            return
        case .nativePrompt:
            await prompt(kind)
            return
        case .systemSettings:
            break
        }
        switch kind {
        case .microphone, .speechRecognition:
            break
        case .accessibility:
            // Registers Sayso in the Accessibility list; the grant itself is manual.
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        }
        openSettings(for: kind)
        // Settings grants happen outside Sayso and may not reactivate it, so
        // keep polling until the grant lands or the bound expires.
        await pollUntil(kind, attempts: 120) { $0 == .granted }
    }

    nonisolated static func interaction(for kind: PermissionKind, state: PermissionState?) -> PermissionInteraction {
        if case .granted? = state { return .none }
        switch kind {
        case .microphone, .speechRecognition:
            if case .undetermined? = state { return .nativePrompt }
            return .systemSettings
        case .accessibility, .inputMonitoring:
            return .systemSettings
        }
    }

    nonisolated static func needsSystemPrompt(_ kind: PermissionKind, state: PermissionState?) -> Bool {
        interaction(for: kind, state: state) == .nativePrompt
    }

    private func prompt(_ kind: PermissionKind) async {
        // Native TCC sheets attach to the active app.
        NSApplication.shared.activate(ignoringOtherApps: true)
        await Task.yield()
        switch kind {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .speechRecognition:
            _ = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        case .accessibility, .inputMonitoring:
            return
        }
        // TCC can report the prior state briefly after its sheet closes.
        await pollUntil(kind, attempts: 20) { $0 != .undetermined }
    }

    private func pollUntil(_ kind: PermissionKind, attempts: Int, _ done: (PermissionState?) -> Bool) async {
        for _ in 0 ..< attempts {
            refresh()
            if done(states[kind]) || Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
        refresh()
    }

    private func openSettings(for kind: PermissionKind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }
}
