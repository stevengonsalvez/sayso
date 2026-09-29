import AppKit
import Carbon
import Foundation
import os.log
import SaysoCore
import SpeakUpstreamBridge
import SwiftUI

private final class CarbonRegistrationState: @unchecked Sendable {
    var eventHandler: EventHandlerRef?
    var hotKeyRefs: [SaysoShortcutAction: EventHotKeyRef] = [:]
    var registeredActionsByID: [UInt32: SaysoShortcutAction] = [:]

    deinit {
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }
}

/// Global shortcut manager for Sayso using Carbon RegisterEventHotKey.
/// Supports dual hotkeys (dictation and desktop control) plus notch HUD toggle.
@MainActor
public final class SaysoShortcutManager: ObservableObject {
    private let log = Logger(subsystem: "com.sayso.notch", category: "SaysoShortcutManager")
    private let signature: UInt32 = 0x5359_534F // "SYSO"
    private let state = CarbonRegistrationState()

    public var onActionTriggered: ((SaysoShortcutAction, _ isKeyDown: Bool) -> Void)?

    public init() {
        installCarbonEventHandler()
    }

    /// Register a hotkey for a specific action.
    @discardableResult
    public func register(action: SaysoShortcutAction, hotKey: HotKey) -> Bool {
        unregister(action: action)

        guard case let .custom(keyCode, modifiers) = hotKey else {
            log.info("Action \(action.rawValue) is Fn key or unhandled by Carbon backend")
            return false
        }

        guard hotKey.isSupportedForGlobalMonitoring else {
            log.error("Unsupported shortcut for global monitoring: \(hotKey.displayString)")
            return false
        }

        installCarbonEventHandler()

        let hotKeyIDSpec = EventHotKeyID(signature: signature, id: action.carbonID)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            modifiers.carbonFlags,
            hotKeyIDSpec,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr, let ref = hotKeyRef {
            state.hotKeyRefs[action] = ref
            state.registeredActionsByID[action.carbonID] = action
            log.info("Registered Carbon hotkey for \(action.rawValue): \(hotKey.displayString)")
            return true
        } else {
            log.error("Failed to register Carbon hotkey for \(action.rawValue) (status: \(status))")
            return false
        }
    }

    /// Unregister a specific action.
    public func unregister(action: SaysoShortcutAction) {
        if let ref = state.hotKeyRefs[action] {
            UnregisterEventHotKey(ref)
            state.hotKeyRefs.removeValue(forKey: action)
            state.registeredActionsByID.removeValue(forKey: action.carbonID)
            log.info("Unregistered Carbon hotkey for \(action.rawValue)")
        }
    }

    /// Unregister all active Carbon hotkeys.
    public func unregisterAll() {
        for (_, ref) in state.hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        state.hotKeyRefs.removeAll()
        state.registeredActionsByID.removeAll()
    }

    // MARK: - Carbon Event Handling

    private func installCarbonEventHandler() {
        guard state.eventHandler == nil else { return }

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<SaysoShortcutManager>.fromOpaque(userData).takeUnretainedValue()
                return manager.handleCarbonEvent(event)
            },
            eventTypes.count,
            &eventTypes,
            selfPtr,
            &state.eventHandler
        )

        if status != noErr {
            log.error("Failed to install Carbon event handler: \(status)")
            state.eventHandler = nil
        }
    }

    private nonisolated func handleCarbonEvent(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            UInt32(kEventParamDirectObject),
            UInt32(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr, hotKeyID.signature == signature else {
            return OSStatus(eventNotHandledErr)
        }

        let eventKind = Int(GetEventKind(event))
        let isKeyDown = eventKind == kEventHotKeyPressed

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let action = self.state.registeredActionsByID[hotKeyID.id] else { return }
            self.onActionTriggered?(action, isKeyDown)
        }

        return noErr
    }

    // MARK: - Conflict Detection

    /// Detect conflicts among configured shortcuts and against standard macOS shortcuts.
    public static func detectConflicts(
        dictation: HotKey,
        control: HotKey,
        toggleNotch: HotKey
    ) -> [ShortcutConflict] {
        ShortcutConflictDetector.detectConflicts(
            dictation: dictation,
            control: control,
            toggleNotch: toggleNotch
        )
    }
}

/// A compact, interactive shortcut recorder row modeled after JustSpeakToIt's ShortcutsSettingsView.
public struct SaysoShortcutRecorderRow: View {
    let action: SaysoShortcutAction
    @Binding var hotKey: HotKey
    @State private var isRecording = false
    @State private var pendingModifiers: HotKey.ModifierSet = []
    @State private var eventMonitor: Any?
    @State private var validationError: String?

    public init(action: SaysoShortcutAction, hotKey: Binding<HotKey>) {
        self.action = action
        self._hotKey = hotKey
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text(action.explanatoryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)

                if action != .toggleNotch {
                    Toggle("Fn key", isOn: Binding(
                        get: { hotKey.isFnKey },
                        set: { useFn in
                            if useFn {
                                stopRecording()
                                hotKey = .fnKey
                            } else {
                                hotKey = action.defaultHotKey
                            }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                }

                recordButton

                Button("Reset") {
                    stopRecording()
                    hotKey = action.defaultHotKey
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .disabled(hotKey == action.defaultHotKey)
            }

            if let validationError {
                Label(validationError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.red)
            }
        }
        .padding(.vertical, 4)
        .onDisappear {
            stopRecording()
        }
    }

    private var recordButton: some View {
        Button {
            if isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        } label: {
            HStack(spacing: 4) {
                if isRecording {
                    Image(systemName: "keyboard")
                    if !pendingModifiers.isEmpty {
                        Text(pendingModifiers.displaySymbol)
                            .font(.system(.caption, design: .monospaced).weight(.bold))
                    }
                    Text("Press keys...")
                        .font(.caption)
                } else {
                    Text(hotKey.displayString)
                        .font(.system(.subheadline, design: .monospaced).weight(.medium))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isRecording ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isRecording ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(hotKey.isFnKey)
        .help("Click to record a new keyboard shortcut.")
    }

    private func startRecording() {
        stopRecording()
        isRecording = true
        pendingModifiers = []
        validationError = nil

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Handle modifier-only presses
            if KeyCodeMapping.modifierKeyCodes.contains(event.keyCode) {
                pendingModifiers = HotKey.ModifierSet(from: event.modifierFlags)
                return nil
            }

            // Escape cancels recording
            if event.keyCode == 53 && pendingModifiers.isEmpty {
                stopRecording()
                return nil
            }

            let modifiers = HotKey.ModifierSet(
                from: event.modifierFlags.intersection([.command, .shift, .option, .control])
            )

            guard KeyCodeMapping.isSupportedCustomHotKey(
                keyCode: event.keyCode,
                hasModifiers: !modifiers.isEmpty
            ) else {
                validationError = KeyCodeMapping.unsupportedSingleKeyMessage
                return nil
            }

            validationError = nil
            hotKey = .custom(keyCode: event.keyCode, modifiers: modifiers)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        isRecording = false
        pendingModifiers = []
    }
}

extension HotKey.ModifierSet {
    public var displaySymbol: String {
        var parts: [String] = []
        if contains(.control) { parts.append("⌃") }
        if contains(.option) { parts.append("⌥") }
        if contains(.shift) { parts.append("⇧") }
        if contains(.command) { parts.append("⌘") }
        return parts.joined()
    }
}
