import Foundation
@testable import SaysoCore

/// Deterministic stand-in for the macOS Accessibility boundary and the Jev model.
/// Everything above these two seams (planning, grounding, policy, session budget, audit) is production code.
@MainActor
final class FakeDesktop {
    struct App {
        var name: String
        var processIdentifier: Int32
        var windowTitle = ""
        var focusedRole = ""
        var focusedValue = ""
        var isProtected = false
        var observations: [String] = []
        var elements: [DesktopElement] = []
        var url: URL?
    }

    struct Dispatch {
        let step: ControlPlanStep
        let approved: Bool
    }

    var apps: [String: App] = [:]
    var frontmost = ""
    private(set) var dispatched: [Dispatch] = []
    private(set) var audit: [ControlAuditEntry] = []
    /// Applied once, between capture and a guarded dispatch, to model a target that changed under the plan.
    var mutateBeforeNextDispatch: (@MainActor (FakeDesktop) -> Void)?
    var scrollChangesScreen = true
    /// A freshly launched app can answer the first captures with an empty control list.
    var coldCapturesAfterLaunch = 0
    private var remainingColdCaptures = 0
    private var calculator = (display: "0", pending: "", operand: "")

    static let calculatorID = "com.apple.calculator"

    func install(_ bundleIdentifier: String, _ app: App) { apps[bundleIdentifier] = app }

    func capture(_ target: String) throws -> DesktopSnapshot {
        guard var app = apps[target] else { throw SaysoError.unavailable("Application") }
        if target == Self.calculatorID, remainingColdCaptures > 0 {
            remainingColdCaptures -= 1
            app.elements = []
        }
        return DesktopSnapshot(
            processIdentifier: app.processIdentifier,
            applicationName: app.name,
            windowTitle: app.windowTitle,
            focusedRole: app.focusedRole,
            focusedValue: app.focusedValue,
            isProtected: app.isProtected,
            observations: app.observations,
            elements: app.elements
        )
    }

    /// Mirrors the guards of `AXDesktopController.execute` that run before anything is dispatched.
    func execute(_ step: ControlPlanStep, approved: Bool, target: String) async throws -> ControlAuditEntry {
        guard step.confidence >= ControlPolicy.minimumConfidence else {
            throw SaysoError.invalidAction("Confidence below Sayso control threshold")
        }
        guard approved || !ControlPolicy.requiresConfirmation(step) else {
            throw SaysoError.invalidAction("Review required before this action can run")
        }
        let before = try capture(target)
        guard !before.isProtected else { throw SaysoError.protectedTarget }
        mutateBeforeNextDispatch?(self)
        mutateBeforeNextDispatch = nil
        let current = try capture(target)
        if let expected = Self.expectedFingerprint(of: step.action), current.fingerprint != expected {
            throw SaysoError.staleTarget
        }
        guard !current.isProtected else { throw SaysoError.protectedTarget }
        dispatched.append(.init(step: step, approved: approved))
        let external = apply(step.action, target: target)
        let after = try? capture(frontmost.isEmpty ? target : (apps[target] == nil ? frontmost : target))
        let effect = ControlOutcome.effect(for: step.action, before: before, after: after, externalEffect: external)
        let entry = ControlAuditEntry(
            action: step.action,
            beforeFingerprint: before.fingerprint,
            afterFingerprint: after?.fingerprint,
            effect: effect,
            planningSource: step.planningSource,
            result: ControlOutcome.result(for: step.action, effect: effect)
        )
        audit.append(entry)
        return entry
    }

    private static func expectedFingerprint(of action: DesktopAction) -> String? {
        switch action {
        case let .type(_, fingerprint), let .typeInto(_, _, fingerprint), let .scroll(_, fingerprint),
             let .press(_, fingerprint), let .focus(_, fingerprint), let .select(_, fingerprint),
             let .clickAt(_, fingerprint), let .key(_, fingerprint):
            fingerprint
        case .open, .openFolder, .activate, .activateApplication, .quit:
            nil
        }
    }

    private func apply(_ action: DesktopAction, target: String) -> ControlEffect {
        switch action {
        case let .activateApplication(bundleIdentifier, _), let .activate(bundleIdentifier):
            guard apps[bundleIdentifier] != nil else { return .notObserved }
            frontmost = bundleIdentifier
            if bundleIdentifier == Self.calculatorID { remainingColdCaptures = coldCapturesAfterLaunch }
            return .observed
        case let .open(url):
            guard var app = apps[handler(for: url)] else { return .notObserved }
            app.url = url
            app.windowTitle = url.host ?? ""
            apps[handler(for: url)] = app
            frontmost = handler(for: url)
            return .observed
        case let .openFolder(url):
            guard var finder = apps["com.apple.finder"] else { return .notObserved }
            finder.windowTitle = url.lastPathComponent
            apps["com.apple.finder"] = finder
            frontmost = "com.apple.finder"
            return .observed
        case let .typeInto(elementID, text, _):
            guard var app = apps[target], app.elements.contains(where: { $0.id == elementID }) else { return .notObserved }
            app.focusedValue += text
            apps[target] = app
            return .observed
        case let .type(text, _):
            apps[target]?.focusedValue += text
            return .observed
        case let .press(elementID, _):
            guard let title = apps[target]?.elements.first(where: { $0.id == elementID })?.title else { return .notObserved }
            if target == Self.calculatorID { pressCalculator(title) } else { apps[target]?.windowTitle = title }
            return .observed
        case .scroll:
            if scrollChangesScreen { apps[target]?.observations.append("scrolled \(dispatched.count)") }
            return .unknown
        case .focus, .select, .clickAt, .key, .quit:
            return .unknown
        }
    }

    private func handler(for url: URL) -> String { "company.thebrowser.Browser" }

    private func pressCalculator(_ title: String) {
        switch title {
        case "All Clear", "Clear":
            calculator = ("0", "", "")
        case "Multiply":
            calculator.pending = "×"
            calculator.operand = calculator.display
            calculator.display = "0"
        case "Equals":
            if let left = Int(calculator.operand), let right = Int(calculator.display) {
                calculator.display = String(left * right)
            }
            calculator.pending = ""
        default:
            calculator.display = calculator.display == "0" ? title : calculator.display + title
        }
        apps[Self.calculatorID]?.observations = [calculator.display]
    }

    static func calculatorApp() -> App {
        let titles = (0 ... 9).map(String.init) + ["Multiply", "Equals", "All Clear"]
        return App(
            name: "Calculator", processIdentifier: 100, windowTitle: "Calculator", focusedRole: "AXWindow",
            observations: ["0"],
            elements: titles.map { .init(id: "press:\($0)", role: "AXButton", title: $0, supportsPress: true) }
        )
    }
}

/// Builds the `JevDecision` the hosted model would return. The provider is scripted, never the bridge.
enum JevScript {
    static func decision(
        operation: String, confidence: Double = 0.95, finishes: Double = 0,
        head: String? = nil, choice: String? = nil, probabilities: [String: Double] = [:]
    ) -> JevDecision {
        var answers: [String: Any] = [
            "operation": ["type": "choice", "choice": operation, "confidence": confidence, "probabilities": [operation: confidence]],
            "finishes": ["type": "noul", "noul": finishes]
        ]
        if let head, let choice {
            answers[head] = [
                "type": "choice", "choice": choice, "confidence": confidence,
                "probabilities": probabilities.isEmpty ? [choice: confidence] : probabilities
            ]
        }
        let data = try! JSONSerialization.data(withJSONObject: ["answers": answers])
        return try! JSONDecoder().decode(JevDecision.self, from: data)
    }
}
