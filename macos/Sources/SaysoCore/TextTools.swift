import AppKit
import ApplicationServices
@preconcurrency import AVFoundation

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

        fileprivate init(field: AXUIElement, processIdentifier: pid_t) {
            self.field = field
            self.processIdentifier = processIdentifier
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
        return Destination(field: field, processIdentifier: targetProcessIdentifier)
    }

    @discardableResult
    public static func insertOrCopy(
        _ text: String,
        destination: Destination?,
        restoreClipboardAfterPaste: Bool = true
    ) -> Bool {
        guard AXIsProcessTrusted(), let destination else {
            copy(text)
            return false
        }
        var fieldProcessIdentifier: pid_t = 0
        AXUIElementGetPid(destination.field, &fieldProcessIdentifier)
        guard fieldProcessIdentifier == destination.processIdentifier else {
            copy(text)
            return false
        }
        guard !isProtected(destination.field) else {
            copy(text)
            return false
        }
        let setResult = AXUIElementSetAttributeValue(destination.field, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        if setResult == .success { return true }

        guard paste(text, into: destination.processIdentifier, restoreClipboardAfterPaste: restoreClipboardAfterPaste) else {
            copy(text)
            return false
        }
        return true
    }

    private static func paste(
        _ text: String,
        into targetProcessIdentifier: pid_t,
        restoreClipboardAfterPaste: Bool
    ) -> Bool {
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
        keyDown.postToPid(targetProcessIdentifier)
        keyUp.postToPid(targetProcessIdentifier)
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
}
