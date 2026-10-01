import Foundation
import Testing
@testable import SaysoCore

/// Injects a typed command into the production Control run engine. Apple Speech is never involved.
@MainActor
final class ControlHarness {
    let desktop = FakeDesktop()
    var decisions: [@MainActor (JevCycleOffer) throws -> JevDecision] = []
    private(set) var offers: [JevCycleOffer] = []
    private(set) var recorded: [ControlAuditEntry] = []
    let applications: [InstalledDesktopApplication]
    private(set) var engine: ControlRunEngine<String>!
    var clock = Date(timeIntervalSince1970: 1_000_000)

    init(limits: ControlSessionLimits = .init(), applications: [InstalledDesktopApplication] = ControlHarness.catalog) {
        self.applications = applications
        engine = ControlRunEngine<String>(
            boundary: .init(
                isEnabled: { true },
                bundleIdentifier: { $0 },
                installedApplications: { applications },
                capture: { [desktop] in try desktop.capture($0) },
                execute: { [desktop] step, approved, target in
                    try await desktop.execute(step, approved: approved, target: target)
                },
                decide: { [unowned self] offer in
                    offers.append(offer)
                    guard !decisions.isEmpty else { throw SaysoError.unavailable("Jev script exhausted") }
                    return try decisions.removeFirst()(offer)
                },
                record: { [unowned self] in recorded.append($0) },
                retarget: { [desktop] _, step, current in
                    step.action.mayMoveControlTarget && !desktop.frontmost.isEmpty ? desktop.frontmost : current
                },
                pause: { _ in }
            ),
            session: ControlSession(limits: limits),
            now: { [unowned self] in clock }
        )
    }

    static let catalog: [InstalledDesktopApplication] = [
        .init(name: "Calculator", bundleIdentifier: FakeDesktop.calculatorID, applicationURL: URL(fileURLWithPath: "/System/Applications/Calculator.app")),
        .init(name: "Arc", bundleIdentifier: "company.thebrowser.Browser", applicationURL: URL(fileURLWithPath: "/Applications/Arc.app")),
        .init(name: "TextEdit", bundleIdentifier: "com.apple.TextEdit", applicationURL: URL(fileURLWithPath: "/System/Applications/TextEdit.app")),
        .init(name: "Finder", bundleIdentifier: "com.apple.finder", applicationURL: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")),
        .init(name: "WhatsApp", bundleIdentifier: "net.whatsapp.WhatsApp", applicationURL: URL(fileURLWithPath: "/Applications/WhatsApp.app")),
        .init(name: "Terminal", bundleIdentifier: "com.apple.Terminal", applicationURL: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    ]

    /// Starts from a terminal-like host app, as the real flow does after the user says a command elsewhere.
    func installStandardApps() {
        desktop.install("com.apple.Terminal", .init(name: "Terminal", processIdentifier: 1, windowTitle: "zsh", focusedRole: "AXTextArea"))
        desktop.install(FakeDesktop.calculatorID, FakeDesktop.calculatorApp())
        desktop.frontmost = "com.apple.Terminal"
    }

    func run(_ command: String, from target: String = "com.apple.Terminal") async {
        engine.submit(command, target: target)
        await engine.waitUntilIdle()
    }

    /// Picks the first offered candidate of `head`, so scripts stay independent of candidate id spelling.
    static func choose(
        _ operation: String, head: String? = nil, confidence: Double = 0.95, finishes: Double = 0,
        where matches: @escaping (String) -> Bool = { _ in true }
    ) -> @MainActor (JevCycleOffer) throws -> JevDecision {
        { offer in
            guard let head else { return JevScript.decision(operation: operation, confidence: confidence, finishes: finishes) }
            guard let id = offer.heads[head]?.keys.sorted().first(where: matches) else {
                throw SaysoError.unavailable("Script: no \(head) candidate offered")
            }
            return JevScript.decision(operation: operation, confidence: confidence, finishes: finishes, head: head, choice: id)
        }
    }

    static func openApp(_ bundleIdentifier: String, finishes: Double = 0) -> @MainActor (JevCycleOffer) throws -> JevDecision {
        { _ in
            JevScript.decision(
                operation: "OPEN_APP", finishes: finishes,
                head: "app_target", choice: "open:\(bundleIdentifier)"
            )
        }
    }
}

@MainActor
@Suite struct ControlAcceptanceTests {
    @Test func calculatorOpensAndMultipliesTwelveByThreeWithVerifiedResult() async {
        let harness = ControlHarness()
        harness.installStandardApps()
        harness.decisions = [ControlHarness.openApp(FakeDesktop.calculatorID)]

        await harness.run("open calculator and find 12 times 3")

        #expect(harness.engine.status == "Control completed: 36")
        #expect(harness.desktop.apps[FakeDesktop.calculatorID]?.observations == ["36"])
        // Jev opened the app once; every later step was planned deterministically with no further Jev call.
        #expect(harness.offers.count == 1)
        #expect(harness.recorded.map(\.planningSource).first == .jev)
        #expect(harness.recorded.dropFirst().allSatisfy { $0.planningSource == .deterministic })
        #expect(await harness.engine.sessionState().result == .completed)
    }
}

// MARK: - Installed-app scenarios, synthetic

@MainActor
extension ControlAcceptanceTests {
    private func harnessWith(_ apps: [(String, FakeDesktop.App)], limits: ControlSessionLimits = .init()) -> ControlHarness {
        let harness = ControlHarness(limits: limits)
        harness.installStandardApps()
        for (id, app) in apps { harness.desktop.install(id, app) }
        return harness
    }

    private static let arc = ("company.thebrowser.Browser", FakeDesktop.App(name: "Arc", processIdentifier: 200, windowTitle: "New Tab", focusedRole: "AXWebArea"))
    private static let textEdit = ("com.apple.TextEdit", FakeDesktop.App(
        name: "TextEdit", processIdentifier: 300, windowTitle: "Untitled", focusedRole: "AXTextArea",
        elements: [.init(id: "doc", role: "AXTextArea", title: "Document", supportsPress: false, supportsFocus: true)]
    ))
    private static let finder = ("com.apple.finder", FakeDesktop.App(
        name: "Finder", processIdentifier: 400, windowTitle: "Recents", focusedRole: "AXOutline",
        elements: [.init(id: "downloads", role: "AXRow", title: "Downloads", supportsPress: true)]
    ))
    private static let whatsApp = ("net.whatsapp.WhatsApp", FakeDesktop.App(
        name: "WhatsApp", processIdentifier: 500, windowTitle: "Chats", focusedRole: "AXGroup",
        elements: [
            .init(id: "steve", role: "AXRow", title: "Steve", supportsPress: true),
            .init(id: "compose", role: "AXTextArea", title: "Type a message", supportsPress: false, supportsFocus: true),
            .init(id: "send", role: "AXButton", title: "Send", supportsPress: true)
        ]
    ))

    @Test func arcNavigatesToExplicitHTTPSSiteWithVerifiedURL() async {
        let harness = harnessWith([Self.arc])
        harness.decisions = [
            ControlHarness.openApp("company.thebrowser.Browser"),
            ControlHarness.choose("OPEN_URL", head: "url_target", finishes: 0.95)
        ]

        await harness.run("open Arc and go to https://example.com/docs")

        #expect(harness.desktop.apps["company.thebrowser.Browser"]?.url?.absoluteString == "https://example.com/docs")
        #expect(harness.desktop.apps["company.thebrowser.Browser"]?.windowTitle == "example.com")
        #expect(harness.engine.status == "Control completed")
        #expect(harness.recorded.map(\.effect) == [.observed, .observed])
    }

    @Test func textEditTypesExactTextIntoDisposableEmptyDocument() async {
        let harness = harnessWith([Self.textEdit])
        #expect(harness.desktop.apps["com.apple.TextEdit"]?.focusedValue == "")
        harness.decisions = [
            ControlHarness.openApp("com.apple.TextEdit"),
            { offer in
                let id = try #require(offer.heads["type_target"]?.keys.first)
                let words = offer.state.goal.split(separator: " ").count
                var answers = JevScript.decision(operation: "TYPE_TEXT", head: "type_target", choice: id)
                answers = try ControlHarness.withWords(answers, from: 5, to: words - 1)
                return answers
            }
        ]

        await harness.run("open TextEdit and write exactly hello brave world")

        #expect(harness.desktop.apps["com.apple.TextEdit"]?.focusedValue == "hello brave world")
        #expect(harness.engine.status == "Control completed")
    }

    @Test func finderOpensSafeFolderByVisibleRowAndVerifiesWindow() async {
        let harness = harnessWith([Self.finder])
        harness.decisions = [
            ControlHarness.openApp("com.apple.finder"),
            ControlHarness.choose("CLICK", head: "click_target", finishes: 0.95) { $0.hasPrefix("press:") }
        ]

        await harness.run("open Finder and click Downloads")

        #expect(harness.desktop.apps["com.apple.finder"]?.windowTitle == "Downloads")
        #expect(harness.engine.status == "Control completed")
    }

    @Test func whatsAppNavigatesToContactAndTypesDraftWithoutSending() async {
        let harness = harnessWith([Self.whatsApp])
        harness.decisions = [
            ControlHarness.openApp("net.whatsapp.WhatsApp"),
            ControlHarness.choose("CLICK", head: "click_target") { $0 == "press:steve" },
            { offer in
                let id = try #require(offer.heads["type_target"]?.keys.first)
                let words = offer.state.goal.split(separator: " ").count
                return try ControlHarness.withWords(
                    JevScript.decision(operation: "TYPE_TEXT", head: "type_target", choice: id), from: words - 2, to: words - 1
                )
            }
        ]

        await harness.run("open WhatsApp then Steve and write draft running late")

        let app = harness.desktop.apps["net.whatsapp.WhatsApp"]
        #expect(app?.windowTitle == "Steve")
        #expect(app?.focusedValue == "running late")
        let neverSent = harness.desktop.dispatched.allSatisfy { dispatch in
            switch dispatch.step.action {
            case .key, .clickAt: false
            case let .press(id, _): id != "send"
            default: true
            }
        }
        #expect(neverSent)
        #expect(harness.engine.pendingStep == nil)
    }
}

extension ControlHarness {
    /// Adds the `type_from` / `type_to` word picks a TYPE_TEXT decision needs.
    static func withWords(_ decision: JevDecision, from: Int, to: Int) throws -> JevDecision {
        var answers: [String: Any] = [:]
        for (key, answer) in decision.answers {
            var entry: [String: Any] = ["type": answer.type]
            if let choice = answer.choice { entry["choice"] = choice }
            if let confidence = answer.confidence { entry["confidence"] = confidence }
            if let probabilities = answer.probabilities { entry["probabilities"] = probabilities }
            if let noul = answer.noul { entry["noul"] = noul }
            answers[key] = entry
        }
        for (head, index) in [("type_from", from), ("type_to", to)] {
            answers[head] = ["type": "choice", "choice": "w\(index)", "confidence": 0.95, "probabilities": ["w\(index)": 0.95]]
        }
        return try JSONDecoder().decode(JevDecision.self, from: JSONSerialization.data(withJSONObject: ["answers": answers]))
    }
}

// MARK: - Safety and failure scenarios, synthetic

@MainActor
@Suite struct ControlSafetyAcceptanceTests {
    private func harness(limits: ControlSessionLimits = .init()) -> ControlHarness {
        let harness = ControlHarness(limits: limits)
        harness.installStandardApps()
        harness.desktop.install("com.apple.TextEdit", .init(
            name: "TextEdit", processIdentifier: 300, windowTitle: "Untitled", focusedRole: "AXTextArea",
            elements: [
                .init(id: "doc", role: "AXTextArea", title: "Document", supportsPress: false, supportsFocus: true),
                .init(id: "delete", role: "AXButton", title: "Delete", supportsPress: true)
            ]
        ))
        return harness
    }

    private static func lowConfidenceOpen(_ offer: JevCycleOffer) -> JevDecision {
        JevScript.decision(
            operation: "OPEN_APP", confidence: 0.4, head: "app_target", choice: "open:com.apple.calculator",
            probabilities: ["open:com.apple.calculator": 0.4, "open:com.apple.TextEdit": 0.35]
        )
    }

    @Test func ambiguousTargetAsksOneBoundedClarificationAndExecutesNothing() async {
        let harness = harness()
        harness.decisions = [{ Self.lowConfidenceOpen($0) }]

        await harness.run("open the editor")

        #expect(harness.engine.status.hasPrefix("Which one:"))
        #expect(harness.engine.status.contains("Calculator") && harness.engine.status.contains("TextEdit"))
        #expect(harness.desktop.dispatched.isEmpty)
        #expect(harness.offers.count == 1)
    }

    @Test func clarificationReplyNamingAChoiceResumesTheSameRun() async {
        let harness = harness()
        harness.decisions = [{ Self.lowConfidenceOpen($0) }, ControlHarness.openApp("com.apple.TextEdit", finishes: 0.95)]

        await harness.run("open the editor")
        await harness.run("second")

        #expect(harness.desktop.dispatched.count == 1)
        #expect(harness.desktop.frontmost == "com.apple.TextEdit")
        #expect(harness.offers.last?.state.goal.contains("User clarification: second") == true)
    }

    @Test func staleClarificationDoesNotSwallowALaterUnrelatedCommand() async {
        let harness = harness()
        harness.decisions = [{ Self.lowConfidenceOpen($0) }, ControlHarness.openApp(FakeDesktop.calculatorID)]

        await harness.run("open the editor")
        harness.clock.addTimeInterval(ControlClarification.maximumAge + 1)
        await harness.run("open calculator and find 12 times 3")

        #expect(harness.engine.status == "Control completed: 36")
        #expect(harness.offers.last?.state.goal == "open calculator and find 12 times 3")
    }

    @Test func unrelatedCommandInsideTheWindowIsAlsoANewCommand() async {
        let harness = harness()
        harness.decisions = [{ Self.lowConfidenceOpen($0) }, ControlHarness.openApp(FakeDesktop.calculatorID)]

        await harness.run("open the editor")
        await harness.run("open calculator and find 12 times 3")

        #expect(harness.engine.status == "Control completed: 36")
    }

    @Test func cancellingWithAReasonReportsThatReasonAndStopsTheRun() async {
        let harness = harness()
        harness.desktop.frontmost = "com.apple.TextEdit"
        harness.decisions = [ControlHarness.choose("PRESS_RETURN")]

        await harness.run("press return", from: "com.apple.TextEdit")
        harness.engine.cancel(reason: "Desktop control disabled.")
        await harness.engine.waitUntilIdle()

        #expect(harness.engine.status == "Desktop control disabled.")
        #expect(harness.engine.pendingStep == nil)
        #expect(!harness.engine.isActive)
        #expect(harness.desktop.dispatched.isEmpty)
    }

    @Test func providerFailureExecutesNothing() async {
        let harness = harness()
        harness.decisions = [{ _ in throw SaysoError.unavailable("Jev unreachable") }]

        await harness.run("open TextEdit")

        #expect(harness.desktop.dispatched.isEmpty)
        #expect(harness.recorded.isEmpty)
        #expect(await harness.engine.sessionState().result == .failed)
        #expect(!harness.engine.isActive)
    }

    @Test func lowConfidenceWithAlternativesAsksInsteadOfActing() async {
        let harness = harness()
        harness.decisions = [ControlHarness.choose("OPEN_APP", head: "app_target", confidence: 0.3)]

        await harness.run("open TextEdit")

        #expect(harness.engine.status.hasPrefix("Which one:"))
        #expect(harness.desktop.dispatched.isEmpty)
    }

    @Test func lowConfidenceWithNoAlternativesExecutesNothing() async {
        let harness = harness()
        harness.decisions = [{ _ in JevScript.decision(operation: "CLICK", confidence: 0.3, head: "click_target", choice: "press:ghost") }]

        await harness.run("click the ghost")

        #expect(harness.engine.status == "Jev was not confident enough to act.")
        #expect(harness.desktop.dispatched.isEmpty)
    }

    @Test func protectedTargetExecutesNothing() async {
        let harness = harness()
        harness.desktop.apps["com.apple.TextEdit"]?.isProtected = true
        harness.desktop.frontmost = "com.apple.TextEdit"
        harness.decisions = [ControlHarness.choose("TYPE_TEXT", head: "type_target")]

        await harness.run("write exactly secret", from: "com.apple.TextEdit")

        #expect(harness.desktop.dispatched.isEmpty)
        #expect(harness.desktop.apps["com.apple.TextEdit"]?.focusedValue == "")
    }

    @Test func targetThatChangedAfterPlanningIsStaleAndExecutesNothing() async {
        let harness = harness()
        harness.desktop.frontmost = "com.apple.TextEdit"
        harness.desktop.mutateBeforeNextDispatch = { $0.apps["com.apple.TextEdit"]?.windowTitle = "Other document" }
        harness.decisions = [{ offer in
            let id = try #require(offer.heads["type_target"]?.keys.first)
            return try ControlHarness.withWords(
                JevScript.decision(operation: "TYPE_TEXT", head: "type_target", choice: id), from: 2, to: 2
            )
        }]

        await harness.run("write exactly hello", from: "com.apple.TextEdit")

        #expect(harness.engine.status == SaysoError.staleTarget.localizedDescription)
        #expect(harness.desktop.dispatched.isEmpty)
        #expect(harness.desktop.apps["com.apple.TextEdit"]?.focusedValue == "")
    }

    @Test func destructiveControlWaitsForConfirmationAndDiscardExecutesNothing() async {
        let harness = harness()
        harness.desktop.frontmost = "com.apple.TextEdit"
        harness.decisions = [ControlHarness.choose("CLICK", head: "click_target") { $0 == "press:delete" }]

        await harness.run("delete the document", from: "com.apple.TextEdit")

        #expect(harness.engine.status.hasPrefix("Review required"))
        #expect(harness.engine.pendingStep != nil)
        #expect(harness.desktop.dispatched.isEmpty)

        harness.engine.discardPending()
        await harness.engine.waitUntilIdle()
        #expect(harness.engine.pendingStep == nil)
        #expect(harness.desktop.dispatched.isEmpty)
    }

    @Test func opaqueKeyPressIsConfirmationGatedAndRunsOnlyWhenApproved() async {
        let harness = harness()
        harness.desktop.frontmost = "com.apple.TextEdit"
        harness.decisions = [ControlHarness.choose("PRESS_RETURN", finishes: 0.95)]

        await harness.run("press return", from: "com.apple.TextEdit")
        #expect(harness.desktop.dispatched.isEmpty)
        #expect(harness.engine.pendingStep != nil)

        harness.engine.approvePending()
        await harness.engine.waitUntilIdle()
        #expect(harness.desktop.dispatched.count == 1)
        #expect(harness.desktop.dispatched.first?.approved == true)
    }

    @Test func actionBudgetExhaustionStopsSafely() async {
        let harness = harness(limits: .init(maxActions: 3, maxConsecutiveNoEffect: 2))
        harness.desktop.frontmost = "com.apple.TextEdit"
        harness.decisions = Array(repeating: ControlHarness.choose("SCROLL_DOWN"), count: 10)

        await harness.run("scroll all the way", from: "com.apple.TextEdit")

        #expect(harness.desktop.dispatched.count == 3)
        #expect(await harness.engine.sessionState().result == .actionBudgetExhausted)
        #expect(!harness.engine.isActive)
    }

    @Test func noEffectLoopStopsSafely() async {
        let harness = harness()
        harness.desktop.frontmost = "com.apple.TextEdit"
        harness.desktop.scrollChangesScreen = false
        harness.decisions = Array(repeating: ControlHarness.choose("SCROLL_DOWN"), count: 10)

        await harness.run("scroll all the way", from: "com.apple.TextEdit")

        #expect(harness.desktop.dispatched.count == 2)
        #expect(await harness.engine.sessionState().result == .noEffectBudgetExhausted)
    }

    @Test func auditSeparatesDeterministicFromJevPlanningWithoutSecrets() async throws {
        let harness = harness()
        harness.decisions = [ControlHarness.openApp(FakeDesktop.calculatorID)]

        await harness.run("open calculator and find 12 times 3")

        let sources = Set(harness.recorded.map(\.planningSource))
        #expect(sources == [.jev, .deterministic])
        #expect(harness.recorded.first?.planningSource == .jev)
        let encoded = try String(decoding: JSONEncoder().encode(harness.recorded), as: UTF8.self)
        #expect(!encoded.localizedCaseInsensitiveContains("apikey"))
        #expect(!encoded.contains("sk-"))
    }

    @Test func jevTypedTextKeepsBoundaryPunctuationTheUserSpoke() async {
        let harness = harness()
        harness.desktop.frontmost = "com.apple.TextEdit"
        harness.decisions = [{ offer in
            let id = try #require(offer.heads["type_target"]?.keys.first)
            return try ControlHarness.withWords(
                JevScript.decision(operation: "TYPE_TEXT", head: "type_target", choice: id), from: 2, to: 3
            )
        }]

        await harness.run("write exactly Hello, world!", from: "com.apple.TextEdit")

        #expect(harness.desktop.apps["com.apple.TextEdit"]?.focusedValue == "Hello, world!")
    }
}
