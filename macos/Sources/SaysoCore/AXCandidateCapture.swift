import AppKit
import ApplicationServices
import Foundation

public struct AXCandidateCaptureLimits: Equatable, Sendable {
    public let maximumDepth: Int
    public let maximumNodes: Int
    public let maximumCandidates: Int

    public init(maximumDepth: Int = 5, maximumNodes: Int = 300, maximumCandidates: Int = 100) {
        self.maximumDepth = max(0, maximumDepth)
        self.maximumNodes = max(1, maximumNodes)
        self.maximumCandidates = max(1, maximumCandidates)
    }
}

public enum AXCandidateCapturePolicy {
    public static func isProtected(role: String, subrole: String) -> Bool {
        role == "AXSecureTextField" || subrole == kAXSecureTextFieldSubrole as String
    }

    public static func includesCandidate(
        role: String,
        title: String,
        identifier: String?,
        supportsPress: Bool,
        supportsFocus: Bool,
        isProtected: Bool
    ) -> Bool {
        guard !isProtected, !role.isEmpty, supportsPress || supportsFocus else { return false }
        return !title.isEmpty || !(identifier?.isEmpty ?? true)
    }

    static func childPaths(
        from ancestry: [Int],
        childCount: Int,
        remainingNodeCapacity: Int
    ) -> [[Int]] {
        guard remainingNodeCapacity > 0 else { return [] }
        return (0 ..< min(childCount, remainingNodeCapacity)).map { ancestry + [$0] }
    }
}

public final class AXCandidateCapture: @unchecked Sendable {
    public let limits: AXCandidateCaptureLimits

    public init(limits: AXCandidateCaptureLimits = .init()) {
        self.limits = limits
    }

    public func capture(application targetApplication: NSRunningApplication? = nil) throws -> DesktopCandidateSnapshot {
        guard AXIsProcessTrusted() else { throw SaysoError.permissionDenied("Accessibility") }
        guard let app = targetApplication ?? NSWorkspace.shared.frontmostApplication else {
            throw SaysoError.unavailable("Frontmost application")
        }

        let application = AXUIElementCreateApplication(app.processIdentifier)
        let window = copyElement(kAXFocusedWindowAttribute as CFString, from: application)
        let windowTitle = window.flatMap { stringAttribute(kAXTitleAttribute as CFString, from: $0) } ?? ""
        let captured = window.map {
            capturedCandidates(in: $0, processIdentifier: app.processIdentifier, windowTitle: windowTitle)
        } ?? []

        return DesktopCandidateSnapshot(
            processIdentifier: app.processIdentifier,
            applicationName: app.localizedName ?? "Unknown",
            windowTitle: windowTitle,
            candidates: captured.map(\.candidate)
        )
    }

    public func press(candidateID: DesktopCandidateID, application targetApplication: NSRunningApplication) throws {
        guard AXIsProcessTrusted() else { throw SaysoError.permissionDenied("Accessibility") }
        let application = AXUIElementCreateApplication(targetApplication.processIdentifier)
        guard let window = copyElement(kAXFocusedWindowAttribute as CFString, from: application) else {
            throw SaysoError.staleTarget
        }
        let windowTitle = stringAttribute(kAXTitleAttribute as CFString, from: window) ?? ""
        guard let target = capturedCandidates(
            in: window,
            processIdentifier: targetApplication.processIdentifier,
            windowTitle: windowTitle
        ).first(where: { $0.candidate.id == candidateID }), target.candidate.state.isTargetable else {
            throw SaysoError.staleTarget
        }
        guard AXUIElementPerformAction(target.element, kAXPressAction as CFString) == .success else {
            throw SaysoError.invalidAction("Visible control rejected click")
        }
    }

    private struct CapturedCandidate {
        let candidate: DesktopCandidate
        let element: AXUIElement
    }

    private func capturedCandidates(
        in root: AXUIElement,
        processIdentifier: Int32,
        windowTitle: String
    ) -> [CapturedCandidate] {
        struct PendingNode {
            let element: AXUIElement
            let ancestry: [Int]
            let depth: Int
        }

        var pending = [PendingNode(element: root, ancestry: [], depth: 0)]
        var index = 0
        var visited = 0
        var captured = [CapturedCandidate]()

        while index < pending.count,
              visited < limits.maximumNodes,
              captured.count < limits.maximumCandidates {
            let node = pending[index]
            index += 1
            visited += 1

            let role = stringAttribute(kAXRoleAttribute as CFString, from: node.element) ?? ""
            let subrole = stringAttribute(kAXSubroleAttribute as CFString, from: node.element) ?? ""
            let protected = AXCandidateCapturePolicy.isProtected(role: role, subrole: subrole)
            if protected { continue }

            let identifier = stringAttribute(kAXIdentifierAttribute as CFString, from: node.element)
            let title = title(for: node.element)
            let supportsPress = supportsAction(kAXPressAction as String, on: node.element)
            let supportsFocus = attributeIsSettable(kAXFocusedAttribute as CFString, on: node.element)
            let isEnabled = boolAttribute(kAXEnabledAttribute as CFString, from: node.element, defaultValue: true)

            if AXCandidateCapturePolicy.includesCandidate(
                role: role,
                title: title,
                identifier: identifier,
                supportsPress: supportsPress,
                supportsFocus: supportsFocus,
                isProtected: protected
            ) {
                let candidate = DesktopCandidate(
                    id: .init(
                        processIdentifier: processIdentifier,
                        windowTitle: windowTitle,
                        role: role,
                        identifier: identifier,
                        ancestry: node.ancestry
                    ),
                    role: role,
                    title: title,
                    identifier: identifier,
                    state: .init(
                        isEnabled: isEnabled,
                        supportsPress: supportsPress,
                        supportsFocus: supportsFocus,
                        isProtected: false
                    )
                )
                captured.append(.init(candidate: candidate, element: node.element))
            }

            guard node.depth < limits.maximumDepth else { continue }
            let children = copyAttribute(kAXChildrenAttribute as CFString, from: node.element) as? [AXUIElement] ?? []
            let remaining = limits.maximumNodes - visited - (pending.count - index)
            let paths = AXCandidateCapturePolicy.childPaths(
                from: node.ancestry,
                childCount: children.count,
                remainingNodeCapacity: remaining
            )
            pending += zip(children, paths).map { child, ancestry in
                PendingNode(element: child, ancestry: ancestry, depth: node.depth + 1)
            }
        }

        return captured
    }

    private func title(for element: AXUIElement) -> String {
        let title = stringAttribute(kAXTitleAttribute as CFString, from: element)
        let description = stringAttribute(kAXDescriptionAttribute as CFString, from: element)
        return (title ?? description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func supportsAction(_ action: String, on element: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return false }
        return (names as? [String] ?? []).contains(action)
    }

    private func attributeIsSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success && settable.boolValue
    }

    private func boolAttribute(_ attribute: CFString, from element: AXUIElement, defaultValue: Bool) -> Bool {
        (copyAttribute(attribute, from: element) as? NSNumber)?.boolValue ?? defaultValue
    }

    private func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        (copyAttribute(attribute, from: element) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func copyAttribute(_ attribute: CFString, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value
    }

    private func copyElement(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        guard let value = copyAttribute(attribute, from: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
}
