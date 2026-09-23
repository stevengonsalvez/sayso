import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public struct DesktopElement: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let role: String
    public let title: String

    public init(id: String, role: String, title: String) {
        self.id = id
        self.role = role
        self.title = title
    }
}

public struct DesktopSnapshot: Codable, Equatable, Sendable {
    public let processIdentifier: Int32
    public let applicationName: String
    public let windowTitle: String
    public let focusedRole: String
    public let focusedValue: String
    public let isProtected: Bool
    public let elements: [DesktopElement]

    public init(
        processIdentifier: Int32, applicationName: String, windowTitle: String,
        focusedRole: String, focusedValue: String, isProtected: Bool,
        elements: [DesktopElement] = []
    ) {
        self.processIdentifier = processIdentifier
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.focusedRole = focusedRole
        self.focusedValue = focusedValue
        self.isProtected = isProtected
        self.elements = elements
    }

    public var fingerprint: String {
        let visibleControls = elements.map { [$0.id, $0.role, $0.title].joined(separator: "\u{1F}") }
            .joined(separator: "\u{1E}")
        return [String(processIdentifier), applicationName, windowTitle, focusedRole, focusedValue, isProtected.description, visibleControls]
            .joined(separator: "|")
    }
}

public enum DesktopAction: Codable, Equatable, Sendable {
    case type(text: String, expectedFingerprint: String)
    case open(url: URL)
    case activate(bundleIdentifier: String)
    case quit(bundleIdentifier: String)
    case scroll(lines: Int, expectedFingerprint: String)
    case press(elementID: String, expectedFingerprint: String)

    public var isDestructive: Bool {
        switch self {
        case .quit:
            return true
        case let .press(elementID, _):
            return ControlPolicy.isDestructiveControlTitle(elementID.split(separator: "|", maxSplits: 1).last.map(String.init) ?? "")
        default:
            return false
        }
    }
}

public struct ControlPlanStep: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let action: DesktopAction
    public let confidence: Double
    public let reason: String

    public init(id: UUID = UUID(), action: DesktopAction, confidence: Double, reason: String) {
        self.id = id
        self.action = action
        self.confidence = confidence
        self.reason = reason
    }
}

public struct ControlAuditEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let action: DesktopAction
    public let beforeFingerprint: String
    public let afterFingerprint: String?
    public let result: String

    public init(
        id: UUID = UUID(), timestamp: Date = .now, action: DesktopAction,
        beforeFingerprint: String, afterFingerprint: String?, result: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.action = action
        self.beforeFingerprint = beforeFingerprint
        self.afterFingerprint = afterFingerprint
        self.result = result
    }
}

public enum ControlPolicy {
    public static let minimumConfidence = 0.60
    private static let destructiveWords = [
        "quit", "close", "delete", "remove", "trash", "empty", "discard", "clear",
        "send", "submit", "post", "share", "publish", "pay", "purchase", "order", "transfer"
    ]

    public static func canAutoRun(_ step: ControlPlanStep) -> Bool {
        step.confidence >= minimumConfidence && !requiresConfirmation(step)
    }

    public static func requiresConfirmation(_ step: ControlPlanStep) -> Bool {
        step.action.isDestructive
    }

    public static func isDestructiveControlTitle(_ title: String) -> Bool {
        let normalized = title.lowercased()
        return destructiveWords.contains { normalized.contains($0) }
    }
}

public enum ControlOutcome {
    public static func result(for action: DesktopAction, before: DesktopSnapshot, after: DesktopSnapshot?) -> String {
        guard let after else { return "unknown effect" }
        switch action {
        case .type:
            return after.focusedValue != before.focusedValue ? "observed text change" : "no observed text change"
        case .press, .scroll:
            return after.fingerprint != before.fingerprint ? "observed interface change" : "no observed interface change"
        case .open, .activate, .quit:
            return "dispatched"
        }
    }
}

public enum ControlPlanner {
    public static func plan(command: String, snapshot: DesktopSnapshot) throws -> ControlPlanStep {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        if normalized == "scroll down" || normalized == "scroll down a bit" {
            return .init(action: .scroll(lines: -6, expectedFingerprint: snapshot.fingerprint), confidence: 0.90, reason: "Exact scroll command")
        }
        if normalized == "scroll up" || normalized == "scroll up a bit" {
            return .init(action: .scroll(lines: 6, expectedFingerprint: snapshot.fingerprint), confidence: 0.90, reason: "Exact scroll command")
        }
        if normalized.hasPrefix("type ") {
            let text = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { throw SaysoError.invalidAction("Say what to type after 'type'.") }
            return .init(action: .type(text: text, expectedFingerprint: snapshot.fingerprint), confidence: 0.90, reason: "Exact type command")
        }
        if normalized.hasPrefix("open ") {
            let address = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: address), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
                throw SaysoError.invalidAction("Open commands need an http or https address.")
            }
            return .init(action: .open(url: url), confidence: 0.80, reason: "Explicit web address")
        }
        if normalized.hasPrefix("click ") {
            let title = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            let matches = snapshot.elements.filter { $0.title.compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            guard matches.count == 1, let element = matches.first else {
                throw SaysoError.invalidAction("Click commands need one visible control with an exact title.")
            }
            return .init(action: .press(elementID: element.id, expectedFingerprint: snapshot.fingerprint), confidence: 0.85, reason: "Exact visible control")
        }
        if normalized.hasPrefix("activate "), let identifier = bundleIdentifier(from: trimmed, prefix: 9) {
            return .init(action: .activate(bundleIdentifier: identifier), confidence: 0.80, reason: "Exact bundle identifier")
        }
        if normalized.hasPrefix("quit "), let identifier = bundleIdentifier(from: trimmed, prefix: 5) {
            return .init(action: .quit(bundleIdentifier: identifier), confidence: 0.70, reason: "Exact bundle identifier")
        }
        throw SaysoError.invalidAction("Control supports: type, click exact title, scroll, open https URL, activate bundle ID, or quit bundle ID.")
    }

    private static func bundleIdentifier(from command: String, prefix: Int) -> String? {
        let identifier = String(command.dropFirst(prefix)).trimmingCharacters(in: .whitespaces)
        guard identifier.split(separator: ".").count >= 2,
              identifier.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        return identifier
    }
}

public actor ControlAuditStore {
    private let fileURL: URL

    public init(fileManager: FileManager = .default) {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SaysoNotch", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        fileURL = root.appendingPathComponent("control-audit.json")
    }

    public func entries() -> [ControlAuditEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([ControlAuditEntry].self, from: data)) ?? []
    }

    public func append(_ entry: ControlAuditEntry) {
        var values = entries()
        values.insert(entry, at: 0)
        if values.count > 500 { values.removeLast(values.count - 500) }
        guard let data = try? JSONEncoder().encode(values) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

public final class AXDesktopController: @unchecked Sendable {
    public init() {}

    public func capture(application targetApplication: NSRunningApplication? = nil) throws -> DesktopSnapshot {
        guard AXIsProcessTrusted() else { throw SaysoError.permissionDenied("Accessibility") }
        guard let app = targetApplication ?? NSWorkspace.shared.frontmostApplication else {
            throw SaysoError.unavailable("Frontmost application")
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let focused = copyElement(kAXFocusedUIElementAttribute as CFString, from: application)
        let window = copyElement(kAXFocusedWindowAttribute as CFString, from: application)
        let subrole = focused.flatMap { copyAttribute(kAXSubroleAttribute as CFString, from: $0) as? String } ?? ""
        return DesktopSnapshot(
            processIdentifier: app.processIdentifier,
            applicationName: app.localizedName ?? "Unknown",
            windowTitle: window.flatMap { copyAttribute(kAXTitleAttribute as CFString, from: $0) as? String } ?? "",
            focusedRole: focused.flatMap { copyAttribute(kAXRoleAttribute as CFString, from: $0) as? String } ?? "",
            focusedValue: focused.flatMap { copyAttribute(kAXValueAttribute as CFString, from: $0) as? String } ?? "",
            isProtected: subrole == kAXSecureTextFieldSubrole as String,
            elements: window.map { interactiveElements(in: $0) } ?? []
        )
    }

    public func execute(
        _ step: ControlPlanStep,
        approved: Bool = false,
        targetApplication: NSRunningApplication? = nil
    ) async throws -> ControlAuditEntry {
        guard step.confidence >= ControlPolicy.minimumConfidence else {
            throw SaysoError.invalidAction("Confidence below Sayso control threshold")
        }
        guard approved || !ControlPolicy.requiresConfirmation(step) else {
            throw SaysoError.invalidAction("Review required before this action can run")
        }
        let before = try capture(application: targetApplication)
        guard !before.isProtected else { throw SaysoError.protectedTarget }

        switch step.action {
        case let .type(text, expectedFingerprint):
            guard before.fingerprint == expectedFingerprint else { throw SaysoError.staleTarget }
            try setFocusedText(text, in: before.processIdentifier)
        case let .open(url):
            NSWorkspace.shared.open(url)
        case let .activate(bundleIdentifier):
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
                throw SaysoError.unavailable(bundleIdentifier)
            }
            app.activate()
        case let .quit(bundleIdentifier):
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
                throw SaysoError.unavailable(bundleIdentifier)
            }
            app.terminate()
        case let .scroll(lines, expectedFingerprint):
            guard before.fingerprint == expectedFingerprint else { throw SaysoError.staleTarget }
            guard let target = NSRunningApplication(processIdentifier: before.processIdentifier) else {
                throw SaysoError.unavailable(before.applicationName)
            }
            target.activate()
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(lines), wheel2: 0, wheel3: 0) else {
                throw SaysoError.unavailable("Scroll event")
            }
            event.post(tap: .cghidEventTap)
        case let .press(elementID, expectedFingerprint):
            guard before.fingerprint == expectedFingerprint else { throw SaysoError.staleTarget }
            guard let window = copyElement(kAXFocusedWindowAttribute as CFString, from: AXUIElementCreateApplication(before.processIdentifier)),
                  let element = interactiveElements(in: window).first(where: { $0.id == elementID }) else {
                throw SaysoError.staleTarget
            }
            try press(element, in: before.processIdentifier)
        }

        let after = try? capture(application: targetApplication)
        let entry = ControlAuditEntry(
            action: step.action,
            beforeFingerprint: before.fingerprint,
            afterFingerprint: after?.fingerprint,
            result: ControlOutcome.result(for: step.action, before: before, after: after)
        )
        return entry
    }

    public func verify(
        _ snapshot: DesktopSnapshot,
        targetApplication: NSRunningApplication? = nil
    ) throws -> DesktopSnapshot {
        let current = try capture(application: targetApplication)
        guard !current.isProtected else { throw SaysoError.protectedTarget }
        guard current.fingerprint == snapshot.fingerprint else { throw SaysoError.staleTarget }
        return current
    }

    private func setFocusedText(_ text: String, in processIdentifier: Int32) throws {
        let application = AXUIElementCreateApplication(processIdentifier)
        guard let focused = copyElement(kAXFocusedUIElementAttribute as CFString, from: application) else {
            throw SaysoError.unavailable("Focused text field")
        }
        let subrole = copyAttribute(kAXSubroleAttribute as CFString, from: focused) as? String
        guard subrole != kAXSecureTextFieldSubrole as String else { throw SaysoError.protectedTarget }
        guard AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success else {
            throw SaysoError.invalidAction("Text field rejected insertion")
        }
    }

    private func interactiveElements(in root: AXUIElement) -> [DesktopElement] {
        descendants(of: root, depth: 4).compactMap { element in
            let role = copyAttribute(kAXRoleAttribute as CFString, from: element) as? String ?? ""
            let title = (copyAttribute(kAXTitleAttribute as CFString, from: element) as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !role.isEmpty, !title.isEmpty, supportsPress(element) else { return nil }
            return DesktopElement(id: elementID(role: role, title: title), role: role, title: title)
        }
    }

    private func press(_ descriptor: DesktopElement, in processIdentifier: Int32) throws {
        let application = AXUIElementCreateApplication(processIdentifier)
        guard let window = copyElement(kAXFocusedWindowAttribute as CFString, from: application),
              let target = descendants(of: window, depth: 4).first(where: {
                  let role = copyAttribute(kAXRoleAttribute as CFString, from: $0) as? String ?? ""
                  let title = copyAttribute(kAXTitleAttribute as CFString, from: $0) as? String ?? ""
                  return elementID(role: role, title: title) == descriptor.id
              }), AXUIElementPerformAction(target, kAXPressAction as CFString) == .success else {
            throw SaysoError.invalidAction("Visible control rejected click")
        }
    }

    private func descendants(of root: AXUIElement, depth: Int) -> [AXUIElement] {
        guard depth > 0 else { return [] }
        let children = copyAttribute(kAXChildrenAttribute as CFString, from: root) as? [AXUIElement] ?? []
        return children + children.flatMap { descendants(of: $0, depth: depth - 1) }
    }

    private func supportsPress(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return false }
        return (names as? [String] ?? []).contains(kAXPressAction as String)
    }

    private func elementID(role: String, title: String) -> String {
        "\(role)|\(title)"
    }

    private func copyAttribute(_ attribute: CFString, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value
    }

    private func copyElement(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        guard let value = copyAttribute(attribute, from: element) else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
}
