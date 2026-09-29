import Foundation

public enum JevControlBridge {
    private static let maximumChoicesPerHead = 255

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
            for app in apps {
                candidates.append(JevCandidate(
                    id: "open:\(app.bundleIdentifier)",
                    label: "Open \(app.name)",
                    detail: "Open or activate application \(app.name)"
                ))
            }
        }

        return candidates
    }

    public static func makeCycleOffer(
        goal: String,
        snapshot: DesktopSnapshot,
        recentActions: [JevCycleRecentAction],
        installedApplications: [InstalledDesktopApplication],
        previous: String? = nil
    ) -> JevCycleOffer {
        let clickCandidates = makeCandidates(from: snapshot).filter {
            $0.id.hasPrefix("press:") || $0.id.hasPrefix("select:") || $0.id.hasPrefix("focus:")
        }
        let inputCandidates = uniqueCandidates(clickCandidates.filter { $0.id.hasPrefix("focus:") })
        let indexedApplications = Array(installedApplications.enumerated())
        let matchingApplications = indexedApplications.filter {
            goal.range(of: visibleApplicationName($0.element.name), options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        let offeredApplications = matchingApplications.isEmpty ? indexedApplications : matchingApplications
        let appCandidates = offeredApplications.prefix(maximumChoicesPerHead).map {
            let name = visibleApplicationName($0.element.name)
            return JevCandidate(id: "open:\($0.element.bundleIdentifier)", label: "Open \(name)", detail: "Open or activate application \(name)")
        }
        let websiteCandidates = websites(in: goal).map {
            JevCandidate(id: "url:\($0.absoluteString)", label: $0.host ?? $0.absoluteString, detail: "Open website \($0.absoluteString)")
        }
        var heads: [String: [String: String]] = [:]
        var operations: [String: String] = [
            "PRESS_RETURN": "Press Return to submit the focused search or message only when the goal asks.",
            "PRESS_ESCAPE": "Press Escape to close the current transient interface.",
            "SCROLL_DOWN": "Scroll down one screen.",
            "SCROLL_UP": "Scroll up one screen.",
            "DONE": "Every part of the goal is visibly satisfied.",
            "BLOCKED": "No offered operation can make progress.",
            "WAIT": "Wait briefly because the needed control is still loading."
        ]
        if !clickCandidates.isEmpty {
            operations["CLICK"] = "Click, select, or focus the control chosen in click_target."
            heads["click_target"] = Dictionary(
                clickCandidates.map { ($0.id, $0.detail) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        let tokens = goal.split(separator: " ").map(String.init)
        if !inputCandidates.isEmpty {
            operations["TYPE_TEXT"] = "Enter the verbatim words selected from the goal into type_target; does not submit."
            heads["type_target"] = Dictionary(
                inputCandidates.map { ($0.id, $0.detail) },
                uniquingKeysWith: { first, _ in first }
            )
            var wordOptions: [String: String] = [:]
            for (index, token) in tokens.enumerated() {
                let before = index > 0 ? "\(tokens[index - 1]) " : ""
                let after = index + 1 < tokens.count ? " \(tokens[index + 1])" : ""
                wordOptions["w\(index)"] = "word \(index + 1) of \(tokens.count): …\(before)[\(token)]\(after)…"
            }
            heads["type_from"] = wordOptions
            heads["type_to"] = wordOptions
        }
        if !appCandidates.isEmpty {
            operations["OPEN_APP"] = "Open or switch to the application chosen in app_target."
            heads["app_target"] = Dictionary(
                appCandidates.map { ($0.id, $0.detail) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        if !websiteCandidates.isEmpty {
            operations["OPEN_URL"] = "Open the website chosen in url_target."
            heads["url_target"] = Dictionary(
                websiteCandidates.map { ($0.id, $0.detail) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        let elements = snapshot.elements.enumerated().map { index, element in
            var supported: [String] = []
            if element.supportsPress || element.supportsSelection { supported.append("CLICK") }
            if element.supportsFocus { supported.append(contentsOf: ["CLICK", "TYPE_TEXT"]) }
            return JevCycleElement(
                index: index + 1,
                role: element.role,
                label: element.title,
                value: nil,
                operations: Array(Set(supported)).sorted()
            )
        }
        let state = JevCycleState(
            goal: goal,
            application: snapshot.applicationName,
            window: snapshot.windowTitle,
            elements: elements,
            observations: snapshot.observations,
            available: .init(apps: appCandidates.map(\.label), sites: websiteCandidates.map(\.label)),
            recentActions: Array(recentActions.suffix(10)),
            previous: previous
        )
        return JevCycleOffer(
            state: state,
            operations: operations,
            heads: heads,
            snapshot: snapshot,
            installedApplications: installedApplications
        )
    }

    public static func planCycleStep(
        from decision: JevDecision,
        offer: JevCycleOffer
    ) throws -> JevCyclePlan {
        guard let operation = decision.choice("operation") else { throw JevDecisionError.invalidResponse }
        let finishes = decision.noul("finishes") >= 0.8
        let fingerprint = offer.snapshot.fingerprint
        switch operation.id {
        case "DONE": return .done
        case "BLOCKED": return .blocked
        case "WAIT": return .wait
        case "PRESS_RETURN":
            return .execute(.init(action: .key(.return, expectedFingerprint: fingerprint), confidence: operation.confidence, reason: "Jev: Press Return", planningSource: .jev), finishes: finishes)
        case "PRESS_ESCAPE":
            return .execute(.init(action: .key(.escape, expectedFingerprint: fingerprint), confidence: operation.confidence, reason: "Jev: Press Escape", planningSource: .jev), finishes: finishes)
        case "SCROLL_DOWN", "SCROLL_UP":
            let lines = operation.id == "SCROLL_UP" ? 6 : -6
            return .execute(.init(action: .scroll(lines: lines, expectedFingerprint: fingerprint), confidence: operation.confidence, reason: "Jev: \(operation.id == "SCROLL_UP" ? "Scroll up" : "Scroll down")", planningSource: .jev), finishes: finishes)
        case "CLICK":
            guard let target = decision.choice("click_target") else { throw JevDecisionError.invalidResponse }
            return .execute(try cycleTargetStep(id: target.id, confidence: min(operation.confidence, target.confidence), offer: offer), finishes: finishes)
        case "OPEN_APP":
            guard let target = decision.choice("app_target") else { throw JevDecisionError.invalidResponse }
            return .execute(try cycleTargetStep(id: target.id, confidence: min(operation.confidence, target.confidence), offer: offer), finishes: finishes)
        case "OPEN_URL":
            guard let target = decision.choice("url_target") else { throw JevDecisionError.invalidResponse }
            return .execute(try cycleTargetStep(id: target.id, confidence: min(operation.confidence, target.confidence), offer: offer), finishes: finishes)
        case "TYPE_TEXT":
            guard let target = decision.choice("type_target"), target.id.hasPrefix("focus:"),
                  let first = wordIndex(decision.choice("type_from")?.id),
                  let last = wordIndex(decision.choice("type_to")?.id) else {
                throw JevDecisionError.invalidResponse
            }
            let tokens = offer.state.goal.split(separator: " ").map(String.init)
            guard tokens.indices.contains(first), tokens.indices.contains(last), first <= last else {
                throw JevDecisionError.invalidResponse
            }
            let text = tokens[first ... last].joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !text.isEmpty else { throw JevDecisionError.invalidResponse }
            let targetID = String(target.id.dropFirst("focus:".count))
            return .execute(.init(
                action: .typeInto(elementID: targetID, text: text, expectedFingerprint: fingerprint),
                confidence: exactGoalTargetConfidence(
                    min(operation.confidence, target.confidence),
                    targetID: targetID,
                    offer: offer
                ),
                reason: "Jev: Type into selected field",
                planningSource: .jev
            ), finishes: finishes)
        default:
            throw JevDecisionError.invalidResponse
        }
    }

    public static func cycleAlternatives(
        from decision: JevDecision,
        offer: JevCycleOffer,
        limit: Int = 3
    ) -> [String] {
        guard let operation = decision.choice("operation")?.id else { return [] }
        let head = switch operation {
        case "CLICK": "click_target"
        case "TYPE_TEXT": "type_target"
        case "OPEN_APP": "app_target"
        case "OPEN_URL": "url_target"
        default: ""
        }
        guard !head.isEmpty, let probabilities = decision.answers[head]?.probabilities else { return [] }
        let ranked = probabilities.sorted { $0.value > $1.value }.prefix(max(1, limit))
        return ranked.enumerated().compactMap { index, entry in
            let parts = entry.key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            if parts[0] == "open" {
                return offer.installedApplications.first { $0.bundleIdentifier == parts[1] }.map {
                    "\(index + 1): \(visibleApplicationName($0.name))"
                }
            }
            if parts[0] == "url" { return URL(string: parts[1])?.host.map { "\(index + 1): \($0)" } }
            return offer.snapshot.elements.first { $0.id == parts[1] }.map { "\(index + 1): \($0.title)" }
        }
    }

    private static func wordIndex(_ identifier: String?) -> Int? {
        guard let identifier, identifier.first == "w" else { return nil }
        return Int(identifier.dropFirst())
    }

    private static func visibleApplicationName(_ name: String) -> String {
        visibleName(name)
    }

    private static func visibleName(_ name: String) -> String {
        String(name.unicodeScalars.filter { $0.properties.generalCategory != .format })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func uniqueCandidates(_ candidates: [JevCandidate]) -> [JevCandidate] {
        var seen: Set<String> = []
        return candidates.filter {
            let key = visibleName($0.label).lowercased()
            return seen.insert(key).inserted
        }
    }

    private static func exactGoalTargetConfidence(
        _ confidence: Double,
        targetID: String,
        offer: JevCycleOffer
    ) -> Double {
        guard let element = offer.snapshot.elements.first(where: { $0.id == targetID }) else { return confidence }
        let title = visibleName(element.title)
        guard !title.isEmpty,
              offer.state.goal.range(of: title, options: [.caseInsensitive, .diacriticInsensitive]) != nil else {
            return confidence
        }
        let exactMatches = offer.snapshot.elements.filter {
            visibleName($0.title).compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        guard exactMatches.count == 1 else { return confidence }
        return max(confidence, ControlPolicy.minimumConfidence)
    }

    private static func cycleTargetStep(
        id: String,
        confidence: Double,
        offer: JevCycleOffer
    ) throws -> ControlPlanStep {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw JevDecisionError.invalidResponse }
        let fingerprint = offer.snapshot.fingerprint
        let resolvedConfidence = exactGoalTargetConfidence(confidence, targetID: parts[1], offer: offer)
        switch parts[0] {
        case "press":
            let title = offer.snapshot.elements.first { $0.id == parts[1] }?.title
            return .init(action: .press(elementID: parts[1], expectedFingerprint: fingerprint), confidence: resolvedConfidence, reason: "Jev: Click \(title ?? "control")", planningSource: .jev, candidateTitle: title)
        case "focus":
            return .init(action: .focus(elementID: parts[1], expectedFingerprint: fingerprint), confidence: resolvedConfidence, reason: "Jev: Focus field", planningSource: .jev)
        case "select":
            let title = offer.snapshot.elements.first { $0.id == parts[1] }?.title
            return .init(action: .select(elementID: parts[1], expectedFingerprint: fingerprint), confidence: resolvedConfidence, reason: "Jev: Select \(title ?? "row")", planningSource: .jev, candidateTitle: title)
        case "open":
            guard let app = offer.installedApplications.first(where: { $0.bundleIdentifier == parts[1] }) else {
                throw JevDecisionError.invalidResponse
            }
            return .init(action: .activateApplication(bundleIdentifier: app.bundleIdentifier, applicationURL: app.applicationURL), confidence: confidence, reason: "Jev: Open \(app.name)", planningSource: .jev)
        case "url":
            guard let url = URL(string: parts[1]), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                throw JevDecisionError.invalidResponse
            }
            return .init(action: .open(url: url), confidence: confidence, reason: "Jev: Open \(url.host ?? url.absoluteString)", planningSource: .jev)
        default:
            throw JevDecisionError.invalidResponse
        }
    }

    private static func websites(in command: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(command.startIndex..., in: command)
        return detector.matches(in: command, range: range).compactMap { match in
            guard let detected = match.url,
                  let matchRange = Range(match.range, in: command) else { return nil }
            let literal = String(command[matchRange])
            let hasScheme = literal.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil
            let url = hasScheme ? detected : URL(string: "https://\(literal)")
            guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
            return url
        }
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
                planningSource: .jev,
                candidateTitle: element?.title ?? candidate.label
            )
        case "focus":
            let element = snapshot.elements.first(where: { $0.id == targetId })
            return ControlPlanStep(
                action: .focus(elementID: targetId, expectedFingerprint: snapshot.fingerprint),
                confidence: decision.answers["action"]?.confidence ?? 0.85,
                reason: "Jev: Focus \(candidate.label)",
                planningSource: .jev,
                candidateTitle: element?.title ?? candidate.label
            )
        case "select":
            let element = snapshot.elements.first(where: { $0.id == targetId })
            return ControlPlanStep(
                action: .select(elementID: targetId, expectedFingerprint: snapshot.fingerprint),
                confidence: decision.answers["action"]?.confidence ?? 0.85,
                reason: "Jev: Select \(candidate.label)",
                planningSource: .jev,
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
                reason: "Jev: Press \(key.rawValue)",
                planningSource: .jev
            )
        case "scroll":
            let lines = targetId == "up" ? 6 : -6
            return ControlPlanStep(
                action: .scroll(lines: lines, expectedFingerprint: snapshot.fingerprint),
                confidence: decision.answers["action"]?.confidence ?? 0.9,
                reason: "Jev: Scroll \(targetId)",
                planningSource: .jev
            )
        case "open":
            if let app = installedApplications?.first(where: { $0.bundleIdentifier == targetId }) {
                return ControlPlanStep(
                    action: .activateApplication(bundleIdentifier: targetId, applicationURL: app.applicationURL),
                    confidence: decision.answers["action"]?.confidence ?? 0.9,
                    reason: "Jev: Open \(app.name)",
                    planningSource: .jev
                )
            } else {
                return ControlPlanStep(
                    action: .activate(bundleIdentifier: targetId),
                    confidence: decision.answers["action"]?.confidence ?? 0.85,
                    reason: "Jev: Open \(targetId)",
                    planningSource: .jev
                )
            }
        default:
            throw JevDecisionError.invalidResponse
        }
    }
}
