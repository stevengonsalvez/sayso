import Foundation

public enum JevControlBridge {
    public static func makeCandidates(
        from snapshot: DesktopSnapshot,
        installedApplications: [InstalledDesktopApplication]? = nil
    ) -> [JevCandidate] {
        var candidates: [JevCandidate] = []
        for element in snapshot.elements {
            let label = element.title.isEmpty ? "Unnamed \(element.role)" : element.title
            if element.supportsPress {
                candidates.append(JevCandidate(
                    id: "press:\(element.id)",
                    label: label,
                    detail: "Click \(label) (\(element.role))"
                ))
            }
            if element.supportsFocus {
                candidates.append(JevCandidate(
                    id: "focus:\(element.id)",
                    label: label,
                    detail: "Focus \(label) text field (\(element.role))"
                ))
            }
            if element.supportsSelection {
                candidates.append(JevCandidate(
                    id: "select:\(element.id)",
                    label: label,
                    detail: "Select \(label) row (\(element.role))"
                ))
            }
        }

        // Standard navigation actions
        candidates.append(JevCandidate(id: "key:return", label: "Press Return", detail: "Press Return / Enter key"))
        candidates.append(JevCandidate(id: "key:space", label: "Press Space", detail: "Press Space key"))
        candidates.append(JevCandidate(id: "key:escape", label: "Press Escape", detail: "Press Escape key"))
        candidates.append(JevCandidate(id: "key:tab", label: "Press Tab", detail: "Press Tab key to advance focus"))
        candidates.append(JevCandidate(id: "key:goBack", label: "Go Back", detail: "Navigate back in browser or window"))
        candidates.append(JevCandidate(id: "scroll:down", label: "Scroll Down", detail: "Scroll down the current content"))
        candidates.append(JevCandidate(id: "scroll:up", label: "Scroll Up", detail: "Scroll up the current content"))

        if let apps = installedApplications {
            for app in apps.prefix(25) {
                candidates.append(JevCandidate(
                    id: "open:\(app.bundleIdentifier)",
                    label: "Open \(app.name)",
                    detail: "Open or activate application \(app.name)"
                ))
            }
        }

        return candidates
    }

    public static func planStep(
        from decision: JevDecision,
        candidates: [JevCandidate],
        snapshot: DesktopSnapshot,
        installedApplications: [InstalledDesktopApplication]? = nil
    ) throws -> ControlPlanStep {
        let candidate = try decision.selectedCandidate(from: candidates)
        let parts = candidate.id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw JevDecisionError.invalidResponse
        }
        let actionType = parts[0]
        let targetId = parts[1]

        switch actionType {
        case "press":
            let element = snapshot.elements.first(where: { $0.id == targetId })
            return ControlPlanStep(
                action: .press(elementID: targetId, expectedFingerprint: snapshot.fingerprint),
                confidence: decision.answers["action"]?.confidence ?? 0.85,
                reason: "Jev: Click \(candidate.label)",
                candidateTitle: element?.title ?? candidate.label
            )
        case "focus":
            let element = snapshot.elements.first(where: { $0.id == targetId })
            return ControlPlanStep(
                action: .focus(elementID: targetId, expectedFingerprint: snapshot.fingerprint),
                confidence: decision.answers["action"]?.confidence ?? 0.85,
                reason: "Jev: Focus \(candidate.label)",
                candidateTitle: element?.title ?? candidate.label
            )
        case "select":
            let element = snapshot.elements.first(where: { $0.id == targetId })
            return ControlPlanStep(
                action: .select(elementID: targetId, expectedFingerprint: snapshot.fingerprint),
                confidence: decision.answers["action"]?.confidence ?? 0.85,
                reason: "Jev: Select \(candidate.label)",
                candidateTitle: element?.title ?? candidate.label
            )
        case "key":
            let key: DesktopKey
            switch targetId {
            case "return": key = .return
            case "space": key = .space
            case "escape": key = .escape
            case "tab": key = .tab
            case "goBack": key = .goBack
            default: key = .return
            }
            return ControlPlanStep(
                action: .key(key, expectedFingerprint: snapshot.fingerprint),
                confidence: decision.answers["action"]?.confidence ?? 0.9,
                reason: "Jev: Press \(key.rawValue)"
            )
        case "scroll":
            let lines = targetId == "up" ? 6 : -6
            return ControlPlanStep(
                action: .scroll(lines: lines, expectedFingerprint: snapshot.fingerprint),
                confidence: decision.answers["action"]?.confidence ?? 0.9,
                reason: "Jev: Scroll \(targetId)"
            )
        case "open":
            if let app = installedApplications?.first(where: { $0.bundleIdentifier == targetId }) {
                return ControlPlanStep(
                    action: .activateApplication(bundleIdentifier: targetId, applicationURL: app.applicationURL),
                    confidence: decision.answers["action"]?.confidence ?? 0.9,
                    reason: "Jev: Open \(app.name)"
                )
            } else {
                return ControlPlanStep(
                    action: .activate(bundleIdentifier: targetId),
                    confidence: decision.answers["action"]?.confidence ?? 0.85,
                    reason: "Jev: Open \(targetId)"
                )
            }
        default:
            throw JevDecisionError.invalidResponse
        }
    }
}
