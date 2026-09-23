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

enum ClipboardRestorePolicy {
    static func ownsPasteboard(expectedChangeCount: Int, currentChangeCount: Int) -> Bool {
        expectedChangeCount == currentChangeCount
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
    public enum DeliveryResult: Equatable {
        case delivered(TextDeliveryMethod)
        case pasteFailed(PasteFailure)
    }

    public enum PasteFailure: Equatable {
        case finalTextCopiedToClipboard
        case clipboardRestored
        case clipboardChangedBeforeRestore
        case clipboardRestoreFailed
        case clipboardUnavailable

        public var userMessage: String {
            switch self {
            case .finalTextCopiedToClipboard:
                return "Could not paste final text. Final text copied to clipboard."
            case .clipboardRestored:
                return "Could not paste final text. Clipboard was restored."
            case .clipboardChangedBeforeRestore:
                return "Could not paste final text. Clipboard changed before Sayso could restore it."
            case .clipboardRestoreFailed:
                return "Could not paste final text. Clipboard could not be restored."
            case .clipboardUnavailable:
                return "Could not paste final text or copy it to the clipboard."
            }
        }

        public var fallbackDelivery: TextDeliveryMethod? {
            switch self {
            case .finalTextCopiedToClipboard:
                return .clipboard
            case .clipboardRestored, .clipboardChangedBeforeRestore, .clipboardRestoreFailed, .clipboardUnavailable:
                return nil
            }
        }
    }

    private enum PasteResult {
        case pasted
        case failed(PasteFailure)
    }

    private enum ClipboardRestoreResult {
        case restored
        case ownershipLost
        case failed
    }

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

    private struct PendingClipboardRestore {
        let id: UUID
        let snapshot: PasteboardSnapshot
        let expectedChangeCount: Int
        let task: Task<Void, Never>
    }

    private static var pendingClipboardRestore: PendingClipboardRestore?

    public static func copy(_ text: String) -> Bool {
        cancelPendingClipboardRestore()
        return write(text, to: .general)
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
    ) -> DeliveryResult {
        guard AXIsProcessTrusted(), let destination else {
            return clipboardFallback(for: text)
        }
        guard destination.isSafeDeliveryTarget else {
            return clipboardFallback(for: text)
        }
        guard !isProtected(destination.field) else {
            return clipboardFallback(for: text)
        }
        let setResult = AXUIElementSetAttributeValue(destination.field, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        if setResult == .success { return .delivered(.directInsertion) }

        switch paste(text, into: destination, restoreClipboardAfterPaste: restoreClipboardAfterPaste) {
        case .pasted:
            return .delivered(.pidPaste)
        case let .failed(failure):
            return .pasteFailed(failure)
        }
    }

    private static func clipboardFallback(for text: String) -> DeliveryResult {
        copy(text) ? .delivered(.clipboard) : .pasteFailed(.clipboardUnavailable)
    }

    private static func paste(
        _ text: String,
        into destination: Destination,
        restoreClipboardAfterPaste: Bool
    ) -> PasteResult {
        guard destination.isSafeDeliveryTarget else {
            return .failed(copy(text) ? .finalTextCopiedToClipboard : .clipboardUnavailable)
        }
        let pasteboard = NSPasteboard.general
        let snapshot = clipboardSnapshotForPaste(
            on: pasteboard,
            restoreClipboardAfterPaste: restoreClipboardAfterPaste
        )
        guard write(text, to: pasteboard) else {
            return .failed(
                restoreFailure(
                    snapshot,
                    afterWritingFinalTextWithChangeCount: pasteboard.changeCount,
                    restoreClipboardAfterPaste: restoreClipboardAfterPaste,
                    finalTextIsOnClipboard: false,
                    pasteboard: pasteboard
                )
            )
        }
        let pasteboardChangeCount = pasteboard.changeCount

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return .failed(
                restoreFailure(
                    snapshot,
                    afterWritingFinalTextWithChangeCount: pasteboardChangeCount,
                    restoreClipboardAfterPaste: restoreClipboardAfterPaste,
                    finalTextIsOnClipboard: true,
                    pasteboard: pasteboard
                )
            )
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(destination.processIdentifier)
        keyUp.postToPid(destination.processIdentifier)
        if let snapshot {
            scheduleRestore(snapshot, whenPasteboardChangeCountIs: pasteboardChangeCount, to: pasteboard)
        }
        return .pasted
    }

    private static func write(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    private static func restoreFailure(
        _ snapshot: PasteboardSnapshot?,
        afterWritingFinalTextWithChangeCount changeCount: Int,
        restoreClipboardAfterPaste: Bool,
        finalTextIsOnClipboard: Bool,
        pasteboard: NSPasteboard
    ) -> PasteFailure {
        // No paste event reached the target. Preserve the final transcript instead of restoring it away.
        if finalTextIsOnClipboard { return .finalTextCopiedToClipboard }
        guard restoreClipboardAfterPaste else {
            return .clipboardUnavailable
        }
        switch restore(snapshot, whenPasteboardChangeCountIs: changeCount, to: pasteboard) {
        case .restored:
            return .clipboardRestored
        case .ownershipLost:
            return .clipboardChangedBeforeRestore
        case .failed:
            return .clipboardRestoreFailed
        }
    }

    private static func clipboardSnapshotForPaste(
        on pasteboard: NSPasteboard,
        restoreClipboardAfterPaste: Bool
    ) -> PasteboardSnapshot? {
        let pending = cancelPendingClipboardRestore()
        guard restoreClipboardAfterPaste else { return nil }
        if let pending,
           ClipboardRestorePolicy.ownsPasteboard(
            expectedChangeCount: pending.expectedChangeCount,
            currentChangeCount: pasteboard.changeCount
           ) {
            return pending.snapshot
        }
        return PasteboardSnapshot(reading: pasteboard)
    }

    @discardableResult
    private static func cancelPendingClipboardRestore() -> PendingClipboardRestore? {
        let pending = pendingClipboardRestore
        pending?.task.cancel()
        pendingClipboardRestore = nil
        return pending
    }

    private static func restore(
        _ snapshot: PasteboardSnapshot?,
        whenPasteboardChangeCountIs expectedChangeCount: Int,
        to pasteboard: NSPasteboard
    ) -> ClipboardRestoreResult {
        guard let snapshot else { return .failed }
        guard ClipboardRestorePolicy.ownsPasteboard(
                expectedChangeCount: expectedChangeCount,
                currentChangeCount: pasteboard.changeCount
              ) else { return .ownershipLost }
        return snapshot.restore(to: pasteboard) ? .restored : .failed
    }

    private static func scheduleRestore(
        _ snapshot: PasteboardSnapshot,
        whenPasteboardChangeCountIs expectedChangeCount: Int,
        to pasteboard: NSPasteboard
    ) {
        let id = UUID()
        let task = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard let pending = pendingClipboardRestore, pending.id == id else { return }
            pendingClipboardRestore = nil
            _ = restore(snapshot, whenPasteboardChangeCountIs: expectedChangeCount, to: pasteboard)
        }
        pendingClipboardRestore = .init(
            id: id,
            snapshot: snapshot,
            expectedChangeCount: expectedChangeCount,
            task: task
        )
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

        func restore(to pasteboard: NSPasteboard) -> Bool {
            pasteboard.clearContents()
            guard !items.isEmpty else { return true }
            return pasteboard.writeObjects(items)
        }
    }

    private static func isProtected(_ element: AXUIElement) -> Bool {
        let role = copyAttribute(kAXRoleAttribute as CFString, from: element) as? String ?? ""
        let subrole = copyAttribute(kAXSubroleAttribute as CFString, from: element) as? String ?? ""
        return AXCandidateCapturePolicy.isProtected(role: role, subrole: subrole)
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
