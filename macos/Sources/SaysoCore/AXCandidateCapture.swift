import AppKit
import ApplicationServices
import CoreGraphics
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

    public static func focusedValue(_ value: String, role: String, subrole: String) -> String {
        isProtected(role: role, subrole: subrole) ? "" : value
    }

    public static func includesCandidate(
        role: String,
        title: String,
        identifier: String?,
        supportsPress: Bool,
        supportsFocus: Bool,
        supportsSelection: Bool = false,
        isProtected: Bool
    ) -> Bool {
        guard !isProtected, !role.isEmpty, supportsPress || supportsFocus || supportsSelection else { return false }
        return !title.isEmpty || !(identifier?.isEmpty ?? true)
    }

    public static func defersSelectionCandidate(
        supportsPress: Bool,
        supportsFocus: Bool,
        supportsSelection: Bool
    ) -> Bool {
        supportsSelection && !supportsPress && !supportsFocus
    }

    public static func supportsPointerClick(
        supportsSelection: Bool,
        hasClickableFrame: Bool
    ) -> Bool {
        supportsSelection && hasClickableFrame
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

    public func focus(candidateID: DesktopCandidateID, application targetApplication: NSRunningApplication) throws {
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
        ).first(where: { $0.candidate.id == candidateID }), target.candidate.state.isSelectable else {
            throw SaysoError.staleTarget
        }
        guard AXUIElementSetAttributeValue(target.element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else {
            throw SaysoError.invalidAction("Visible field rejected focus")
        }
    }

    public func select(candidateID: DesktopCandidateID, application targetApplication: NSRunningApplication) throws -> Bool {
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
        ).first(where: { $0.candidate.id == candidateID }), target.candidate.state.isSelectionTarget else {
            throw SaysoError.staleTarget
        }
        guard !boolAttribute(kAXSelectedAttribute as CFString, from: target.element, defaultValue: false) else {
            return false
        }
        guard AXUIElementSetAttributeValue(target.element, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success,
              boolAttribute(kAXSelectedAttribute as CFString, from: target.element, defaultValue: false) else {
            throw SaysoError.invalidAction("Visible row rejected selection")
        }
        return true
    }

    /// Clicks only an exact, still-visible row whose centre resolves back to that row.
    public func click(candidateID: DesktopCandidateID, application targetApplication: NSRunningApplication) throws -> Bool {
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
        ).first(where: { $0.candidate.id == candidateID }), target.candidate.state.isPointerTarget,
              let centre = clickableCentre(of: target.element) else {
            throw SaysoError.staleTarget
        }

        let hit = try hitTest(target: target.element, in: application, at: centre)
        guard hit.matchesTarget else {
            throw SaysoError.invalidAction("Visible row is covered")
        }
        guard hit.hitsTargetDirectly else {
            return try select(candidateID: candidateID, application: targetApplication)
        }

        var topElement: AXUIElement?
        var owner: pid_t = 0
        guard AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(), Float(centre.x), Float(centre.y), &topElement
        ) == .success,
        let topElement,
        AXUIElementGetPid(topElement, &owner) == .success,
        owner == targetApplication.processIdentifier else {
            throw SaysoError.invalidAction("Another window covers the visible row")
        }

        let wasSelected = boolAttribute(kAXSelectedAttribute as CFString, from: target.element, defaultValue: false)
        try postPointerClick(at: centre)
        usleep(150_000)
        return !wasSelected && boolAttribute(kAXSelectedAttribute as CFString, from: target.element, defaultValue: false)
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
        var deferredSelectionCandidates = [CapturedCandidate]()

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
            let supportsSelection = [kAXRowRole as String, kAXCellRole as String].contains(role)
                && attributeIsSettable(kAXSelectedAttribute as CFString, on: node.element)
            let supportsPointerClick = AXCandidateCapturePolicy.supportsPointerClick(
                supportsSelection: supportsSelection,
                hasClickableFrame: clickableCentre(of: node.element) != nil
            )
            let isEnabled = boolAttribute(kAXEnabledAttribute as CFString, from: node.element, defaultValue: true)

            if AXCandidateCapturePolicy.includesCandidate(
                role: role,
                title: title,
                identifier: identifier,
                supportsPress: supportsPress,
                supportsFocus: supportsFocus,
                supportsSelection: supportsSelection,
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
                        supportsSelection: supportsSelection,
                        supportsPointerClick: supportsPointerClick,
                        isProtected: false
                    )
                )
                let capturedCandidate = CapturedCandidate(candidate: candidate, element: node.element)
                if AXCandidateCapturePolicy.defersSelectionCandidate(
                    supportsPress: supportsPress,
                    supportsFocus: supportsFocus,
                    supportsSelection: supportsSelection
                ) {
                    deferredSelectionCandidates.append(capturedCandidate)
                } else {
                    captured.append(capturedCandidate)
                }
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

        let remaining = limits.maximumCandidates - captured.count
        if remaining > 0 {
            captured.append(contentsOf: deferredSelectionCandidates.prefix(remaining))
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

    private func clickableCentre(of element: AXUIElement) -> CGPoint? {
        guard let position = pointAttribute(kAXPositionAttribute as CFString, from: element),
              let size = sizeAttribute(kAXSizeAttribute as CFString, from: element),
              size.width > 0, size.height > 0 else { return nil }
        return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
    }

    private func hitTest(target: AXUIElement, in application: AXUIElement, at point: CGPoint) throws -> (matchesTarget: Bool, hitsTargetDirectly: Bool) {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &element) == .success,
              let deepest = element else {
            throw SaysoError.invalidAction("Visible row no longer accepts clicks")
        }
        guard !CFEqual(deepest, target) else { return (true, true) }

        var ancestor = deepest
        for _ in 0..<4 {
            guard let parent = copyElement(kAXParentAttribute as CFString, from: ancestor) else { break }
            if CFEqual(parent, target) { return (true, false) }
            ancestor = parent
        }
        return (false, false)
    }

    private func postPointerClick(at point: CGPoint) throws {
        let originalPointer = CGEvent(source: nil)?.location
        defer {
            if let originalPointer { CGWarpMouseCursorPosition(originalPointer) }
        }
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(
                mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: .left
            ) else {
                throw SaysoError.unavailable("Pointer event")
            }
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
    }

    private func pointAttribute(_ attribute: CFString, from element: AXUIElement) -> CGPoint? {
        guard let value = copyAttribute(attribute, from: element),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private func sizeAttribute(_ attribute: CFString, from element: AXUIElement) -> CGSize? {
        guard let value = copyAttribute(attribute, from: element),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }
}
