import AppKit
import ApplicationServices
@preconcurrency import AVFoundation

struct TextOutputTargetIdentity: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let launchDate: Date?

    func matches(_ current: TextOutputTargetIdentity) -> Bool {
        processIdentifier == current.processIdentifier
            && bundleIdentifier == current.bundleIdentifier
            && launchDate == current.launchDate
    }

    func allowsDelivery(
        to current: TextOutputTargetIdentity,
        isFrontmost: Bool,
        capturedFieldOwnsFocus: Bool
    ) -> Bool {
        matches(current) && isFrontmost && capturedFieldOwnsFocus
    }
}

@MainActor
public final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate, ObservableObject {
    @Published public private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    public func speak(_ text: String, language: DictationLanguage = .english) {
        guard !text.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language.localeIdentifier ?? Locale.current.identifier)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    public func stop() { synthesizer.stopSpeaking(at: .immediate) }
    nonisolated public func speechSynthesizer(_: AVSpeechSynthesizer, didStart _: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = true }
    }

    nonisolated public func speechSynthesizer(_: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    nonisolated public func speechSynthesizer(_: AVSpeechSynthesizer, didCancel _: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}

@MainActor
public enum TextOutput {
    public final class Destination {
        fileprivate let field: AXUIElement
        fileprivate let processIdentifier: pid_t
        fileprivate let applicationIdentity: TextOutputTargetIdentity
        public let recordingDestination: RecordingDestination

        fileprivate init(
            field: AXUIElement,
            processIdentifier: pid_t,
            applicationIdentity: TextOutputTargetIdentity,
            recordingDestination: RecordingDestination
        ) {
            self.field = field
            self.processIdentifier = processIdentifier
            self.applicationIdentity = applicationIdentity
            self.recordingDestination = recordingDestination
        }
    }

    public static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public static func captureDestination(targetProcessIdentifier: pid_t?) -> Destination? {
        guard let targetProcessIdentifier else { return nil }
        let application = AXUIElementCreateApplication(targetProcessIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value else { return nil }
        let field = unsafeDowncast(value, to: AXUIElement.self)
        var fieldProcessIdentifier: pid_t = 0
        AXUIElementGetPid(field, &fieldProcessIdentifier)
        guard fieldProcessIdentifier == targetProcessIdentifier, !isProtected(field) else { return nil }
        let role = copyAttribute(kAXRoleAttribute as CFString, from: field) as? String ?? "Unknown"
        let window = copyElement(kAXFocusedWindowAttribute as CFString, from: application)
        let windowTitle = window.flatMap { copyAttribute(kAXTitleAttribute as CFString, from: $0) as? String } ?? ""
        let runningApplication = NSRunningApplication(processIdentifier: targetProcessIdentifier)
        let name = runningApplication?.localizedName ?? "Unknown"
        return Destination(
            field: field,
            processIdentifier: targetProcessIdentifier,
            applicationIdentity: .init(
                processIdentifier: targetProcessIdentifier,
                bundleIdentifier: runningApplication?.bundleIdentifier,
                launchDate: runningApplication?.launchDate
            ),
            recordingDestination: .init(
                processIdentifier: targetProcessIdentifier,
                applicationName: name,
                fieldRole: role,
                windowTitle: windowTitle
            )
        )
    }

    @discardableResult
    public static func insertOrCopy(
        _ text: String,
        destination: Destination?,
        restoreClipboardAfterPaste: Bool = true
    ) -> TextDeliveryMethod {
        guard AXIsProcessTrusted(), let destination else {
            copy(text)
            return .clipboard
        }
        guard destination.isSafeDeliveryTarget else {
            copy(text)
            return .clipboard
        }
        guard !isProtected(destination.field) else {
            copy(text)
            return .clipboard
        }
        let setResult = AXUIElementSetAttributeValue(destination.field, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        if setResult == .success { return .directInsertion }

        guard paste(text, into: destination, restoreClipboardAfterPaste: restoreClipboardAfterPaste) else {
            copy(text)
            return .clipboard
        }
        return .pidPaste
    }

    private static func paste(
        _ text: String,
        into destination: Destination,
        restoreClipboardAfterPaste: Bool
    ) -> Bool {
        guard destination.isSafeDeliveryTarget else { return false }
        let pasteboard = NSPasteboard.general
        let snapshot = restoreClipboardAfterPaste ? PasteboardSnapshot(reading: pasteboard) : nil
        copy(text)

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(destination.processIdentifier)
        keyUp.postToPid(destination.processIdentifier)
        if let snapshot {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) {
                snapshot.restore(to: pasteboard)
            }
        }
        return true
    }

    private struct PasteboardSnapshot {
        let items: [NSPasteboardItem]

        init(reading pasteboard: NSPasteboard) {
            items = (pasteboard.pasteboardItems ?? []).map { source in
                let copy = NSPasteboardItem()
                for type in source.types {
                    if let data = source.data(forType: type) {
                        copy.setData(data, forType: type)
                    }
                }
                return copy
            }
        }

        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            guard !items.isEmpty else { return }
            pasteboard.writeObjects(items)
        }
    }

    private static func isProtected(_ element: AXUIElement) -> Bool {
        var subrole: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        return (subrole as? String) == (kAXSecureTextFieldSubrole as String)
    }

    private static func copyAttribute(_ attribute: CFString, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value
    }

    private static func copyElement(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        guard let value = copyAttribute(attribute, from: element) else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
}

@MainActor
private extension TextOutput.Destination {
    var isSafeDeliveryTarget: Bool {
        var fieldProcessIdentifier: pid_t = 0
        AXUIElementGetPid(field, &fieldProcessIdentifier)
        guard let currentIdentity = TextOutput.runningApplicationIdentity(processIdentifier: processIdentifier),
              fieldProcessIdentifier == processIdentifier,
              let focusedField = TextOutput.focusedElement(processIdentifier: processIdentifier) else {
            return false
        }
        return applicationIdentity.allowsDelivery(
            to: currentIdentity,
            isFrontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier,
            capturedFieldOwnsFocus: CFEqual(field, focusedField)
        )
    }
}

private extension TextOutput {
    static func runningApplicationIdentity(processIdentifier: pid_t) -> TextOutputTargetIdentity? {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier), !application.isTerminated else {
            return nil
        }
        return .init(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            launchDate: application.launchDate
        )
    }

    static func focusedElement(processIdentifier: pid_t) -> AXUIElement? {
        copyElement(kAXFocusedUIElementAttribute as CFString, from: AXUIElementCreateApplication(processIdentifier))
    }
}
