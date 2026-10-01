import Foundation

public enum JevControlBridge {
    private static let maximumChoicesPerHead = 255

    private enum CycleOperation: String {
        case pressReturn = "PRESS_RETURN"
        case pressEscape = "PRESS_ESCAPE"
        case scrollDown = "SCROLL_DOWN"
        case scrollUp = "SCROLL_UP"
        case done = "DONE"
        case blocked = "BLOCKED"
        case wait = "WAIT"
        case click = "CLICK"
        case typeText = "TYPE_TEXT"
        case openApp = "OPEN_APP"
        case openURL = "OPEN_URL"

        var targetHead: String? {
            switch self {
            case .click: "click_target"
            case .typeText: "type_target"
            case .openApp: "app_target"
            case .openURL: "url_target"
            default: nil
            }
        }
    }

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
        let matchingApplications = indexedApplications.filter { containsWord(visibleName($0.element.name), in: goal) }
        let offeredApplications = matchingApplications.isEmpty ? indexedApplications : matchingApplications
        let appCandidates = offeredApplications.prefix(maximumChoicesPerHead).map {
            let name = visibleName($0.element.name)
            return JevCandidate(id: "open:\($0.element.bundleIdentifier)", label: "Open \(name)", detail: "Open or activate application \(name)")
        }
        let websiteCandidates = websites(in: goal).map {
            JevCandidate(id: "url:\($0.absoluteString)", label: $0.host ?? $0.absoluteString, detail: "Open website \($0.absoluteString)")
        }
        var heads: [String: [String: String]] = [:]
        var operations: [String: String] = [
            CycleOperation.pressReturn.rawValue: "Press Return to submit the focused search or message only when the goal asks.",
            CycleOperation.pressEscape.rawValue: "Press Escape to close the current transient interface.",
            CycleOperation.scrollDown.rawValue: "Scroll down one screen.",
            CycleOperation.scrollUp.rawValue: "Scroll up one screen.",
            CycleOperation.done.rawValue: "Every part of the goal is visibly satisfied.",
            CycleOperation.blocked.rawValue: "No offered operation can make progress.",
            CycleOperation.wait.rawValue: "Wait briefly because the needed control is still loading."
        ]
        if !clickCandidates.isEmpty {
            operations[CycleOperation.click.rawValue] = "Click, select, or focus the control chosen in click_target."
            heads[CycleOperation.click.targetHead!] = Dictionary(
                clickCandidates.map { ($0.id, $0.detail) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        let tokens = goal.split(separator: " ").map(String.init)
        if !inputCandidates.isEmpty {
            operations[CycleOperation.typeText.rawValue] = "Enter the verbatim words selected from the goal into type_target; does not submit."
            heads[CycleOperation.typeText.targetHead!] = Dictionary(
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
            operations[CycleOperation.openApp.rawValue] = "Open or switch to the application chosen in app_target."
            heads[CycleOperation.openApp.targetHead!] = Dictionary(
                appCandidates.map { ($0.id, $0.detail) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        if !websiteCandidates.isEmpty {
            operations[CycleOperation.openURL.rawValue] = "Open the website chosen in url_target."
            heads[CycleOperation.openURL.targetHead!] = Dictionary(
                websiteCandidates.map { ($0.id, $0.detail) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        let elements = snapshot.elements.enumerated().map { index, element in
            var supported: [String] = []
            if element.supportsPress || element.supportsSelection { supported.append(CycleOperation.click.rawValue) }
            if element.supportsFocus { supported.append(contentsOf: [CycleOperation.click.rawValue, CycleOperation.typeText.rawValue]) }
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
        guard let cycleOperation = CycleOperation(rawValue: operation.id) else { throw JevDecisionError.invalidResponse }
        switch cycleOperation {
        case .done: return .done
        case .blocked: return .blocked
        case .wait: return .wait
        case .pressReturn:
            return .execute(.init(action: .key(.return, expectedFingerprint: fingerprint), confidence: operation.confidence, reason: "Jev: Press Return", planningSource: .jev), finishes: finishes)
        case .pressEscape:
            return .execute(.init(action: .key(.escape, expectedFingerprint: fingerprint), confidence: operation.confidence, reason: "Jev: Press Escape", planningSource: .jev), finishes: finishes)
        case .scrollDown, .scrollUp:
            let scrollsUp = cycleOperation == .scrollUp
            return .execute(.init(action: .scroll(lines: scrollsUp ? 6 : -6, expectedFingerprint: fingerprint), confidence: operation.confidence, reason: "Jev: \(scrollsUp ? "Scroll up" : "Scroll down")", planningSource: .jev), finishes: finishes)
        case .click:
            guard let target = decision.choice("click_target") else { throw JevDecisionError.invalidResponse }
            return .execute(try cycleTargetStep(id: target.id, confidence: min(operation.confidence, target.confidence), offer: offer), finishes: finishes)
        case .openApp:
            guard let target = decision.choice("app_target") else { throw JevDecisionError.invalidResponse }
            return .execute(try cycleTargetStep(id: target.id, confidence: min(operation.confidence, target.confidence), offer: offer), finishes: finishes)
        case .openURL:
            guard let target = decision.choice("url_target") else { throw JevDecisionError.invalidResponse }
            return .execute(try cycleTargetStep(id: target.id, confidence: min(operation.confidence, target.confidence), offer: offer), finishes: finishes)
        case .typeText:
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
        }
    }

    public static func cycleAlternatives(
        from decision: JevDecision,
        offer: JevCycleOffer,
        limit: Int = 3
    ) -> [String] {
        guard let operationID = decision.choice("operation")?.id,
              let head = CycleOperation(rawValue: operationID)?.targetHead,
              let probabilities = decision.answers[head]?.probabilities else { return [] }
        let ranked = probabilities.sorted { $0.value > $1.value }.prefix(max(1, limit))
        return ranked.enumerated().compactMap { index, entry in
            let parts = entry.key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            if parts[0] == "open" {
                return offer.installedApplications.first { $0.bundleIdentifier == parts[1] }.map {
                    "\(index + 1): \(visibleName($0.name))"
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

    private static func visibleName(_ name: String) -> String {
        String(name.unicodeScalars.filter { $0.properties.generalCategory != .format })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whole words only: a button titled "Set" must not match "settings", nor an app "Mail" match "email".
    private static func containsWord(_ word: String, in text: String) -> Bool {
        guard !word.isEmpty else { return false }
        let pattern = "(?<![\\p{L}\\p{N}])\(NSRegularExpression.escapedPattern(for: word))(?![\\p{L}\\p{N}])"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive, .diacriticInsensitive]) != nil
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
        guard containsWord(title, in: offer.state.goal) else {
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
