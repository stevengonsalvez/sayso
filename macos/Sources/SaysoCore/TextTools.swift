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
    public struct Voice: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let language: String
    }

    @Published public private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    public static func availableVoices(for language: DictationLanguage) -> [Voice] {
        let voices = AVSpeechSynthesisVoice.speechVoices().map {
            Voice(id: $0.identifier, name: $0.name, language: $0.language)
        }
        guard let localeIdentifier = language.localeIdentifier,
              let languageCode = Locale(identifier: localeIdentifier).language.languageCode?.identifier else { return voices }
        return voices.filter { Locale(identifier: $0.language).language.languageCode?.identifier == languageCode }
    }

    public func speak(
        _ text: String,
        language: DictationLanguage = .english,
        voiceIdentifier: String? = nil,
        rate: Double = Double(AVSpeechUtteranceDefaultSpeechRate)
    ) {
        guard !text.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
            ?? AVSpeechSynthesisVoice(language: language.localeIdentifier ?? Locale.current.identifier)
        utterance.rate = min(
            max(Float(rate), AVSpeechUtteranceMinimumSpeechRate),
            AVSpeechUtteranceMaximumSpeechRate
        )
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
        public let bundleIdentifier: String?
        public let recordingDestination: RecordingDestination

        fileprivate init(
            field: AXUIElement,
            processIdentifier: pid_t,
            applicationIdentity: TextOutputTargetIdentity,
            bundleIdentifier: String?,
            recordingDestination: RecordingDestination
        ) {
            self.field = field
            self.processIdentifier = processIdentifier
            self.applicationIdentity = applicationIdentity
            self.bundleIdentifier = bundleIdentifier
            self.recordingDestination = recordingDestination
        }
    }

    @MainActor
    public final class LiveInsertion {
        public enum FinalizationResult: Equatable { case applied, deferred, failed }

        private let destination: Destination
        private var region: LiveTextRegion
        private var isUsable = true
        public private(set) var hasWritten = false

        public init?(destination: Destination) {
            guard ["com.apple.TextEdit", "com.apple.Notes"].contains(destination.bundleIdentifier),
                  TextOutput.isFocused(destination),
                  let value = TextOutput.value(in: destination),
                  let selection = TextOutput.selectedRange(in: destination),
                  let region = LiveTextRegion(baseline: value, selection: selection) else { return nil }
            self.destination = destination
            self.region = region
        }

        @discardableResult
        public func update(_ text: String) -> Bool { replace(with: text) }

        public func finalize(_ text: String) -> FinalizationResult {
            guard hasWritten else { return .deferred }
            return replace(with: text) ? .applied : .failed
        }

        public func discard() {
            guard hasWritten, let originalSelection = region.originalSelection else { return }
            if replace(with: originalSelection) { region.restore() }
        }

        @discardableResult
        private func replace(with text: String) -> Bool {
            guard isUsable,
                  TextOutput.isFocused(destination),
                  let current = TextOutput.value(in: destination),
                  region.matches(current),
                  let expected = region.value(afterReplacingWith: text),
                  TextOutput.setSelectedRange(region.replacementRange, in: destination),
                  AXUIElementSetAttributeValue(destination.field, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success else {
                isUsable = false
                return false
            }
            hasWritten = true
            guard TextOutput.value(in: destination) == expected else {
                isUsable = false
                return false
            }
            region.replace(with: text)
            return true
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
            bundleIdentifier: runningApplication?.bundleIdentifier,
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

    public static func currentValue(in destination: Destination) -> String? {
        guard destination.isSafeDeliveryTarget, !isProtected(destination.field) else { return nil }
        return copyAttribute(kAXValueAttribute as CFString, from: destination.field) as? String
    }

    public static func isFocused(_ destination: Destination) -> Bool {
        destination.isSafeDeliveryTarget && !isProtected(destination.field)
    }

    private static func value(in destination: Destination) -> String? {
        copyAttribute(kAXValueAttribute as CFString, from: destination.field) as? String
    }

    private static func selectedRange(in destination: Destination) -> TextUTF16Range? {
        guard let value = copyAttribute(kAXSelectedTextRangeAttribute as CFString, from: destination.field),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let rangeValue = unsafeDowncast(value, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        return .init(location: range.location, length: range.length)
    }

    private static func setSelectedRange(_ range: TextUTF16Range, in destination: Destination) -> Bool {
        var value = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &value) else { return false }
        return AXUIElementSetAttributeValue(
            destination.field,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        ) == .success
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
        guard let value = copyAttribute(attribute, from: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
}

public struct TextUTF16Range: Codable, Equatable, Sendable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public var end: Int { location + length }
}

public struct LiveTextRegion: Equatable, Sendable {
    public let baseline: String
    public let selection: TextUTF16Range
    public private(set) var insertedText = ""
    private var hasReplacedSelection = false

    public init?(baseline: String, selection: TextUTF16Range) {
        guard Self.nsRange(in: baseline, at: selection) != nil else { return nil }
        self.baseline = baseline
        self.selection = selection
    }

    public var expectedValue: String? {
        hasReplacedSelection ? replacingBaseline(with: insertedText) : baseline
    }

    public var originalSelection: String? {
        guard let range = Self.nsRange(in: baseline, at: selection) else { return nil }
        return (baseline as NSString).substring(with: range)
    }

    public func matches(_ currentValue: String) -> Bool {
        currentValue == expectedValue
    }

    public mutating func replace(with text: String) {
        insertedText = text
        hasReplacedSelection = true
    }

    public mutating func restore() {
        insertedText = ""
        hasReplacedSelection = false
    }

    public func rangeForInsertedText() -> TextUTF16Range {
        .init(location: selection.location, length: insertedText.utf16.count)
    }

    public var replacementRange: TextUTF16Range {
        hasReplacedSelection ? rangeForInsertedText() : selection
    }

    public func value(afterReplacingWith text: String) -> String? {
        replacingBaseline(with: text)
    }

    private func replacingBaseline(with text: String) -> String? {
        guard let range = Self.nsRange(in: baseline, at: selection) else { return nil }
        return (baseline as NSString).replacingCharacters(in: range, with: text)
    }

    private static func nsRange(in value: String, at range: TextUTF16Range) -> NSRange? {
        let utf16Count = value.utf16.count
        guard range.location >= 0,
              range.length >= 0,
              range.location <= utf16Count,
              range.length <= utf16Count - range.location else { return nil }
        let start = String.Index(utf16Offset: range.location, in: value)
        let end = String.Index(utf16Offset: range.location + range.length, in: value)
        guard start.samePosition(in: value.unicodeScalars) != nil,
              end.samePosition(in: value.unicodeScalars) != nil else { return nil }
        return .init(location: range.location, length: range.length)
    }
}

public struct SelectedTextEditAnchor: Equatable, Sendable {
    public let selectedText: String
    public let range: TextUTF16Range

    public init?(value: String, range: TextUTF16Range) {
        guard let selectedText = Self.substring(in: value, at: range) else { return nil }
        self.selectedText = selectedText
        self.range = range
    }

    public func stillMatches(value: String, range: TextUTF16Range) -> Bool {
        self.range == range && Self.substring(in: value, at: range) == selectedText
    }

    public func replacing(with text: String, in value: String) -> String? {
        guard stillMatches(value: value, range: range),
              let range = Self.nsRange(in: value, at: range) else { return nil }
        return (value as NSString).replacingCharacters(in: range, with: text)
    }

    private static func substring(in value: String, at range: TextUTF16Range) -> String? {
        guard let range = nsRange(in: value, at: range) else { return nil }
        return (value as NSString).substring(with: range)
    }

    private static func nsRange(in value: String, at range: TextUTF16Range) -> NSRange? {
        let utf16Count = value.utf16.count
        guard range.location >= 0,
              range.length > 0,
              range.location <= utf16Count,
              range.length <= utf16Count - range.location
        else { return nil }
        let start = String.Index(utf16Offset: range.location, in: value)
        let end = String.Index(utf16Offset: range.location + range.length, in: value)
        guard start.samePosition(in: value.unicodeScalars) != nil,
              end.samePosition(in: value.unicodeScalars) != nil else { return nil }
        return .init(location: range.location, length: range.length)
    }
}

@MainActor
public enum SelectedTextEdit {
    public enum ApplyResult: Equatable {
        case replaced
        case replacementUnverified
        case noRewrite
        case copiedToClipboard(String)

        public var userMessage: String {
            switch self {
            case .replaced: "Selection rewritten."
            case .replacementUnverified: "Replacement may have been applied. Check the selected field before continuing."
            case .noRewrite: "No rewrite was returned."
            case let .copiedToClipboard(reason): "\(reason) Rewrite copied to clipboard."
            }
        }
    }

    public final class Capture {
        public let selectedText: String
        public let targetProcessIdentifier: pid_t
        fileprivate let field: AXUIElement
        fileprivate let processIdentifier: pid_t
        fileprivate let applicationIdentity: TextOutputTargetIdentity
        fileprivate let anchor: SelectedTextEditAnchor

        fileprivate init(
            field: AXUIElement,
            processIdentifier: pid_t,
            applicationIdentity: TextOutputTargetIdentity,
            anchor: SelectedTextEditAnchor
        ) {
            self.field = field
            self.processIdentifier = processIdentifier
            targetProcessIdentifier = processIdentifier
            self.applicationIdentity = applicationIdentity
            self.anchor = anchor
            selectedText = anchor.selectedText
        }
    }

    public static func capture() -> Capture? {
        guard AXIsProcessTrusted(),
              let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !application.isTerminated else { return nil }
        let root = AXUIElementCreateApplication(application.processIdentifier)
        guard let field = copyElement(kAXFocusedUIElementAttribute as CFString, from: root) else { return nil }
        let role = copyAttribute(kAXRoleAttribute as CFString, from: field) as? String ?? ""
        let subrole = copyAttribute(kAXSubroleAttribute as CFString, from: field) as? String ?? ""
        guard !AXCandidateCapturePolicy.isProtected(role: role, subrole: subrole) else { return nil }
        var fieldProcessIdentifier: pid_t = 0
        AXUIElementGetPid(field, &fieldProcessIdentifier)
        guard fieldProcessIdentifier == application.processIdentifier else { return nil }
        guard let value = copyAttribute(kAXValueAttribute as CFString, from: field) as? String,
              let range = selectedRange(in: field),
              let anchor = SelectedTextEditAnchor(value: value, range: range) else { return nil }
        let identity = TextOutputTargetIdentity(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            launchDate: application.launchDate
        )
        return .init(
            field: field,
            processIdentifier: application.processIdentifier,
            applicationIdentity: identity,
            anchor: anchor
        )
    }

    public static func replace(_ rewrite: String, in capture: Capture) -> ApplyResult {
        guard !rewrite.isEmpty else { return .noRewrite }
        guard let application = NSRunningApplication(processIdentifier: capture.processIdentifier),
              !application.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == capture.processIdentifier,
              capture.applicationIdentity.matches(.init(
                  processIdentifier: application.processIdentifier,
                  bundleIdentifier: application.bundleIdentifier,
                  launchDate: application.launchDate
              )),
              let focused = copyElement(
                  kAXFocusedUIElementAttribute as CFString,
                  from: AXUIElementCreateApplication(capture.processIdentifier)
              ),
              CFEqual(focused, capture.field),
              let currentValue = copyAttribute(kAXValueAttribute as CFString, from: capture.field) as? String,
              let currentRange = selectedRange(in: capture.field),
              capture.anchor.stillMatches(value: currentValue, range: currentRange)
        else {
            return copy(rewrite, reason: "Selection changed.")
        }
        let role = copyAttribute(kAXRoleAttribute as CFString, from: capture.field) as? String ?? ""
        let subrole = copyAttribute(kAXSubroleAttribute as CFString, from: capture.field) as? String ?? ""
        guard !AXCandidateCapturePolicy.isProtected(role: role, subrole: subrole) else {
            return copy(rewrite, reason: "Protected field.")
        }
        guard let expected = capture.anchor.replacing(with: rewrite, in: currentValue) else {
            return copy(rewrite, reason: "Selection changed.")
        }
        guard AXUIElementSetAttributeValue(capture.field, kAXSelectedTextAttribute as CFString, rewrite as CFTypeRef) == .success else {
            return copy(rewrite, reason: "Could not replace selection.")
        }
        return (copyAttribute(kAXValueAttribute as CFString, from: capture.field) as? String) == expected
            ? .replaced
            : .replacementUnverified
    }

    private static func copy(_ text: String, reason: String) -> ApplyResult {
        _ = TextOutput.copy(text)
        return .copiedToClipboard(reason)
    }

    private static func selectedRange(in element: AXUIElement) -> TextUTF16Range? {
        guard let value = copyAttribute(kAXSelectedTextRangeAttribute as CFString, from: element),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let rangeValue = unsafeDowncast(value, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(rangeValue) == .cfRange,
              AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        return .init(location: range.location, length: range.length)
    }

    private static func copyAttribute(_ attribute: CFString, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value
    }

    private static func copyElement(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        guard let value = copyAttribute(attribute, from: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
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
