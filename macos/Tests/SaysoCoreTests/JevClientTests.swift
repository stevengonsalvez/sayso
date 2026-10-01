import Foundation
import Testing
@testable import SaysoCore

@Suite("Jev Client & Control Bridge Tests")
struct JevClientTests {

    @Test("Jev cycle offer keeps the whole goal and separates operations from targets")
    func cycleOfferKeepsWholeGoal() {
        let goal = "Open WhatsApp and type hello to Steve"
        let snapshot = DesktopSnapshot(
            processIdentifier: 1234,
            applicationName: "Finder",
            windowTitle: "Desktop",
            focusedRole: "AXWindow",
            focusedValue: "",
            isProtected: false,
            observations: ["0"],
            elements: [
                DesktopElement(id: "steve", role: "AXRow", title: "Steve", supportsPress: true),
                DesktopElement(id: "message", role: "AXTextArea", title: "Message", supportsPress: false, supportsFocus: true)
            ]
        )
        let whatsapp = InstalledDesktopApplication(
            name: "WhatsApp",
            bundleIdentifier: "net.whatsapp.WhatsApp",
            applicationURL: URL(fileURLWithPath: "/Applications/WhatsApp.app")
        )
        let recent = [JevCycleRecentAction(action: "OPEN_APP WhatsApp", result: "opened", screenChanged: true)]

        let offer = JevControlBridge.makeCycleOffer(
            goal: goal,
            snapshot: snapshot,
            recentActions: recent,
            installedApplications: [whatsapp]
        )

        #expect(offer.state.goal == goal)
        #expect(offer.state.observations == ["0"])
        #expect(offer.state.recentActions == recent)
        #expect(offer.operations["CLICK"] != nil)
        #expect(offer.operations["TYPE_TEXT"] != nil)
        #expect(offer.operations["OPEN_APP"] != nil)
        #expect(offer.operations["DONE"] != nil)
        #expect(offer.heads["click_target"]?["press:steve"] != nil)
        #expect(offer.heads["type_target"]?["focus:message"] != nil)
        #expect(offer.heads["app_target"]?["open:net.whatsapp.WhatsApp"] != nil)
        #expect(offer.heads["type_from"]?["w0"] != nil)
        #expect(offer.heads["type_to"]?["w6"] != nil)
    }

    @Test("Jev cycle narrows application choices to goal matches")
    func cycleOfferCapsApplicationChoices() {
        let snapshot = DesktopSnapshot(
            processIdentifier: 1234,
            applicationName: "Finder",
            windowTitle: "Desktop",
            focusedRole: "AXWindow",
            focusedValue: "",
            isProtected: false
        )
        var applications = (0..<300).map { index in
            InstalledDesktopApplication(
                name: "Utility \(index)",
                bundleIdentifier: "example.utility.\(index)",
                applicationURL: URL(fileURLWithPath: "/Applications/Utility \(index).app")
            )
        }
        applications.append(.init(
            name: "Calculator",
            bundleIdentifier: "com.apple.calculator",
            applicationURL: URL(fileURLWithPath: "/System/Applications/Calculator.app")
        ))

        let offer = JevControlBridge.makeCycleOffer(
            goal: "Open Calculator and find 12 times 3",
            snapshot: snapshot,
            recentActions: [],
            installedApplications: applications
        )

        #expect(offer.heads["app_target"]?.count == 1)
        #expect(offer.heads["app_target"]?["open:com.apple.calculator"] != nil)
    }

    @Test("Jev cycle collapses duplicate text targets")
    func cycleOfferCollapsesDuplicateTextTargets() {
        let snapshot = DesktopSnapshot(
            processIdentifier: 1234,
            applicationName: "WhatsApp",
            windowTitle: "Chats",
            focusedRole: "AXWindow",
            focusedValue: "",
            isProtected: false,
            elements: [
                .init(id: "message-a", role: "AXTextArea", title: "Compose message", supportsPress: false, supportsFocus: true),
                .init(id: "message-b", role: "AXGroup", title: "Compose message", supportsPress: false, supportsFocus: true)
            ]
        )

        let offer = JevControlBridge.makeCycleOffer(
            goal: "type hello in Compose message",
            snapshot: snapshot,
            recentActions: [],
            installedApplications: []
        )

        #expect(offer.heads["type_target"]?.count == 1)
    }

    @Test("Jev cycle strips invisible app-name formatting before goal matching")
    func cycleOfferNormalizesApplicationNames() {
        let snapshot = DesktopSnapshot(
            processIdentifier: 1234,
            applicationName: "Finder",
            windowTitle: "Desktop",
            focusedRole: "AXWindow",
            focusedValue: "",
            isProtected: false
        )
        var applications = (0..<300).map { index in
            InstalledDesktopApplication(
                name: "Utility \(index)",
                bundleIdentifier: "example.utility.\(index)",
                applicationURL: URL(fileURLWithPath: "/Applications/Utility \(index).app")
            )
        }
        applications.append(.init(
            name: "\u{200E}WhatsApp",
            bundleIdentifier: "net.whatsapp.WhatsApp",
            applicationURL: URL(fileURLWithPath: "/Applications/WhatsApp.app")
        ))

        let offer = JevControlBridge.makeCycleOffer(
            goal: "Open WhatsApp and type a test draft",
            snapshot: snapshot,
            recentActions: [],
            installedApplications: applications
        )

        #expect(offer.heads["app_target"]?["open:net.whatsapp.WhatsApp"] == "Open or activate application WhatsApp")
        #expect(offer.state.available.apps.contains("Open WhatsApp"))
    }

    @Test("Jev cycle request asks one operation and speculative target heads")
    func cycleRequestShape() throws {
        let state = JevCycleState(
            goal: "Open Calculator and find 12 times three",
            application: "Finder",
            window: "Desktop",
            elements: [],
            available: .init(apps: ["Open Calculator"]),
            recentActions: []
        )
        let data = try JevClient.cycleBody(
            state: state,
            operations: ["OPEN_APP": "Open app", "DONE": "Goal complete"],
            heads: ["app_target": ["open:com.apple.calculator": "Open Calculator"]]
        )

        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedState = try #require(json["state"] as? [String: Any])
        let questions = try #require(json["questions"] as? [String: Any])
        #expect(encodedState["goal"] as? String == state.goal)
        #expect(questions["operation"] != nil)
        #expect(questions["app_target"] != nil)
        #expect(questions["finishes"] != nil)
        #expect(questions["action"] == nil)
    }

    @Test("Jev cycle request never sends more than 255 choices per head")
    func cycleRequestChoiceLimit() throws {
        let state = JevCycleState(
            goal: "Open Calculator",
            application: "Finder",
            window: "Desktop",
            elements: [],
            available: .init(apps: [], sites: []),
            recentActions: []
        )
        let choices = Dictionary(uniqueKeysWithValues: (0..<300).map { ("choice-\($0)", "Choice \($0)") })

        let data = try JevClient.cycleBody(
            state: state,
            operations: ["OPEN_APP": "Open app"],
            heads: ["app_target": choices]
        )

        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let questions = try #require(json["questions"] as? [String: Any])
        let appTarget = try #require(questions["app_target"] as? [String: Any])
        let criteria = try #require(appTarget["criteria"] as? [String: String])
        #expect(criteria.count == 255)
    }

    @Test("Jev cycle maps selected contiguous goal words into a targeted type action")
    func cycleMapsTargetedTyping() throws {
        let goal = "Open WhatsApp and type hello there to Steve"
        let snapshot = DesktopSnapshot(
            processIdentifier: 1234,
            applicationName: "WhatsApp",
            windowTitle: "Steve",
            focusedRole: "AXTextArea",
            focusedValue: "",
            isProtected: false,
            elements: [
                DesktopElement(id: "message", role: "AXTextArea", title: "Message", supportsPress: false, supportsFocus: true)
            ]
        )
        let offer = JevControlBridge.makeCycleOffer(
            goal: goal,
            snapshot: snapshot,
            recentActions: [],
            installedApplications: []
        )
        let data = try JSONSerialization.data(withJSONObject: [
            "answers": [
                "operation": ["type": "choice", "choice": "TYPE_TEXT", "confidence": 0.95, "probabilities": ["TYPE_TEXT": 0.96]],
                "type_target": ["type": "choice", "choice": "focus:message", "confidence": 0.94, "probabilities": ["focus:message": 0.97]],
                "type_from": ["type": "choice", "choice": "w4", "confidence": 0.99, "probabilities": ["w4": 0.99]],
                "type_to": ["type": "choice", "choice": "w5", "confidence": 0.99, "probabilities": ["w5": 0.99]],
                "finishes": ["type": "noul", "noul": 0.2]
            ]
        ])
        let decision = try JSONDecoder().decode(JevDecision.self, from: data)

        let result = try JevControlBridge.planCycleStep(from: decision, offer: offer)

        guard case let .execute(step, finishes) = result else {
            Issue.record("Expected executable cycle step")
            return
        }
        #expect(!finishes)
        if case let .typeInto(elementID, text, _) = step.action {
            #expect(elementID == "message")
            #expect(text == "hello there")
        } else {
            Issue.record("Expected targeted type action")
        }
    }

    @Test("Jev cycle exposes likely targets for spoken clarification")
    func cycleClarificationAlternatives() throws {
        let snapshot = DesktopSnapshot(
            processIdentifier: 1234,
            applicationName: "WhatsApp",
            windowTitle: "Chats",
            focusedRole: "AXWindow",
            focusedValue: "",
            isProtected: false,
            elements: [
                .init(id: "steve", role: "AXRow", title: "Steve", supportsPress: true),
                .init(id: "steven", role: "AXRow", title: "Steven", supportsPress: true)
            ]
        )
        let offer = JevControlBridge.makeCycleOffer(goal: "Open Steve", snapshot: snapshot, recentActions: [], installedApplications: [])
        let data = try JSONSerialization.data(withJSONObject: [
            "answers": [
                "operation": ["type": "choice", "choice": "CLICK", "confidence": 0.9, "probabilities": ["CLICK": 0.9]],
                "click_target": [
                    "type": "choice",
                    "choice": "press:steve",
                    "confidence": 0.4,
                    "probabilities": ["press:steve": 0.48, "press:steven": 0.45]
                ]
            ]
        ])
        let decision = try JSONDecoder().decode(JevDecision.self, from: data)

        #expect(JevControlBridge.cycleAlternatives(from: decision, offer: offer) == ["1: Steve", "2: Steven"])
    }

    @Test("Jev cycle trusts one exact target named in the goal")
    func cycleTrustsUniqueExactGoalTarget() throws {
        let snapshot = DesktopSnapshot(
            processIdentifier: 1234,
            applicationName: "WhatsApp",
            windowTitle: "Chats",
            focusedRole: "AXWindow",
            focusedValue: "",
            isProtected: false,
            elements: [
                .init(id: "message", role: "AXTextArea", title: "\u{200E}Compose message", supportsPress: true, supportsFocus: true)
            ]
        )
        let offer = JevControlBridge.makeCycleOffer(
            goal: "type hello in Compose message",
            snapshot: snapshot,
            recentActions: [],
            installedApplications: []
        )
        let data = try JSONSerialization.data(withJSONObject: [
            "answers": [
                "operation": ["type": "choice", "choice": "CLICK", "confidence": 0.95],
                "click_target": ["type": "choice", "choice": "focus:message", "confidence": 0.4]
            ]
        ])
        let decision = try JSONDecoder().decode(JevDecision.self, from: data)

        guard case let .execute(step, _) = try JevControlBridge.planCycleStep(from: decision, offer: offer) else {
            Issue.record("Expected executable cycle step")
            return
        }
        #expect(step.confidence == ControlPolicy.minimumConfidence)
    }

    @Test("Jev cycle narrows applications by whole words only")
    func cycleNarrowsApplicationsByWholeWords() {
        let snapshot = DesktopSnapshot(
            processIdentifier: 1234, applicationName: "Finder", windowTitle: "Desktop",
            focusedRole: "AXWindow", focusedValue: "", isProtected: false
        )
        let apps = ["Mail", "Notes"].map {
            InstalledDesktopApplication(name: $0, bundleIdentifier: "com.apple.\($0)", applicationURL: URL(fileURLWithPath: "/System/Applications/\($0).app"))
        }
        let named = JevControlBridge.makeCycleOffer(goal: "open Notes", snapshot: snapshot, recentActions: [], installedApplications: apps)
        let substring = JevControlBridge.makeCycleOffer(goal: "email the footnotes", snapshot: snapshot, recentActions: [], installedApplications: apps)

        #expect(named.state.available.apps == ["Open Notes"])
        #expect(substring.state.available.apps.sorted() == ["Open Mail", "Open Notes"])
    }

    @Test("Jev cycle keeps a low-confidence pick whose title is only part of a goal word")
    func cycleKeepsLowConfidenceForSubstringTitle() throws {
        let snapshot = DesktopSnapshot(
            processIdentifier: 1234,
            applicationName: "Notes",
            windowTitle: "Notes",
            focusedRole: "AXWindow",
            focusedValue: "",
            isProtected: false,
            elements: [.init(id: "set", role: "AXButton", title: "Set", supportsPress: true)]
        )
        let offer = JevControlBridge.makeCycleOffer(
            goal: "open the settings panel",
            snapshot: snapshot,
            recentActions: [],
            installedApplications: []
        )
        let data = try JSONSerialization.data(withJSONObject: [
            "answers": [
                "operation": ["type": "choice", "choice": "CLICK", "confidence": 0.95],
                "click_target": ["type": "choice", "choice": "press:set", "confidence": 0.3]
            ]
        ])
        let decision = try JSONDecoder().decode(JevDecision.self, from: data)

        guard case let .execute(step, _) = try JevControlBridge.planCycleStep(from: decision, offer: offer) else {
            Issue.record("Expected executable cycle step")
            return
        }
        #expect(step.confidence == 0.3)
        #expect(!ControlPolicy.canAutoRun(step))
    }

    @Test("Jev cycle offers and maps a website named in the whole goal")
    func cycleWebsiteTarget() throws {
        let snapshot = DesktopSnapshot(
            processIdentifier: 1234,
            applicationName: "Safari",
            windowTitle: "Start Page",
            focusedRole: "AXWindow",
            focusedValue: "",
            isProtected: false
        )
        let offer = JevControlBridge.makeCycleOffer(
            goal: "Go to wikipedia.org and search accessibility",
            snapshot: snapshot,
            recentActions: [],
            installedApplications: []
        )
        #expect(offer.operations["OPEN_URL"] != nil)
        #expect(offer.heads["url_target"]?["url:https://wikipedia.org"] != nil)

        let data = try JSONSerialization.data(withJSONObject: [
            "answers": [
                "operation": ["type": "choice", "choice": "OPEN_URL", "confidence": 0.95, "probabilities": ["OPEN_URL": 0.96]],
                "url_target": ["type": "choice", "choice": "url:https://wikipedia.org", "confidence": 0.94, "probabilities": ["url:https://wikipedia.org": 0.97]],
                "finishes": ["type": "noul", "noul": 0.1]
            ]
        ])
        let decision = try JSONDecoder().decode(JevDecision.self, from: data)
        let result = try JevControlBridge.planCycleStep(from: decision, offer: offer)

        guard case let .execute(step, finishes) = result else {
            Issue.record("Expected URL action")
            return
        }
        #expect(!finishes)
        #expect(step.action == .open(url: URL(string: "https://wikipedia.org")!))
    }

    @Test("Jev request body encodes valid state and questions")
    func requestBodyEncoding() throws {
        let context = JevCommandContext(
            command: "click Settings",
            application: "Finder",
            window: "Finder Window",
            completedSteps: ["opened Finder"]
        )
        let candidates = [
            JevCandidate(id: "press:btn1", label: "Settings", detail: "Click Settings button"),
            JevCandidate(id: "key:return", label: "Press Return", detail: "Press Return key")
        ]

        let data = try JevClient.requestBody(context: context, candidates: candidates)
        #expect(!data.isEmpty)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json != nil)
        #expect(json?["model"] as? String == "jev-latest")

        let state = json?["state"] as? [String: Any]
        #expect(state?["command"] as? String == "click Settings")
        #expect(state?["application"] as? String == "Finder")

        let questions = json?["questions"] as? [String: Any]
        #expect(questions?["action"] != nil)
        #expect(questions?["more"] != nil)
        #expect(questions?["repeat"] != nil)
    }

    @Test("Jev request body tolerates duplicate candidate identifiers")
    func requestBodyDuplicateCandidates() throws {
        let context = JevCommandContext(command: "open calculator", application: "Finder", window: "Downloads")
        let candidates = [
            JevCandidate(id: "open:com.apple.calculator", label: "Calculator", detail: "Open Calculator"),
            JevCandidate(id: "open:com.apple.calculator", label: "Calculator copy", detail: "Open Calculator copy")
        ]

        let data = try JevClient.requestBody(context: context, candidates: candidates)

        #expect(!data.isEmpty)
    }

    @Test("JevControlBridge maps press candidate to ControlPlanStep")
    func bridgePressMapping() throws {
        let snapshot = DesktopSnapshot(
            processIdentifier: 1234,
            applicationName: "Safari",
            windowTitle: "Apple",
            focusedRole: "AXWindow",
            focusedValue: "",
            isProtected: false,
            elements: [
                DesktopElement(id: "elem-search", role: "AXButton", title: "Search", supportsPress: true)
            ]
        )

        let candidates = JevControlBridge.makeCandidates(from: snapshot)
        #expect(candidates.contains(where: { $0.id == "press:elem-search" }))
        #expect(candidates.contains(where: { $0.id == "key:return" }))
        #expect(candidates.contains(where: { $0.id == "scroll:down" }))

        let jsonAnswer: [String: Any] = [
            "answers": [
                "action": [
                    "type": "choice",
                    "choice": "press:elem-search",
                    "confidence": 0.95
                ],
                "more": [
                    "type": "noul",
                    "noul": 0.1
                ]
            ]
        ]
        let answerData = try JSONSerialization.data(withJSONObject: jsonAnswer)
        let decision = try JSONDecoder().decode(JevDecision.self, from: answerData)

        let step = try JevControlBridge.planStep(from: decision, candidates: candidates, snapshot: snapshot)
        #expect(step.candidateTitle == "Search")
        #expect(step.confidence == 0.95)
        #expect(step.reason.contains("Click Search"))
        #expect(step.planningSource == .jev)
        if case let .press(elementID, _) = step.action {
            #expect(elementID == "elem-search")
        } else {
            Issue.record("Expected .press action")
        }
    }

    @Test("JevControlBridge maps key candidate to ControlPlanStep")
    func bridgeKeyMapping() throws {
        let snapshot = DesktopSnapshot(
            processIdentifier: 1234,
            applicationName: "Safari",
            windowTitle: "Search Results",
            focusedRole: "AXTextField",
            focusedValue: "cats",
            isProtected: false,
            elements: []
        )

        let candidates = JevControlBridge.makeCandidates(from: snapshot)
        let jsonAnswer: [String: Any] = [
            "answers": [
                "action": [
                    "type": "choice",
                    "choice": "key:return",
                    "confidence": 0.92
                ]
            ]
        ]
        let answerData = try JSONSerialization.data(withJSONObject: jsonAnswer)
        let decision = try JSONDecoder().decode(JevDecision.self, from: answerData)

        let step = try JevControlBridge.planStep(from: decision, candidates: candidates, snapshot: snapshot)
        #expect(step.planningSource == .jev)
        if case let .key(key, _) = step.action {
            #expect(key == .return)
        } else {
            Issue.record("Expected .key action")
        }
    }

    @Test("JevControlBridge offers every installed application")
    func bridgeIncludesApplicationsBeyondFirstTwentyFive() {
        let snapshot = DesktopSnapshot(
            processIdentifier: 1234,
            applicationName: "Finder",
            windowTitle: "Desktop",
            focusedRole: "AXWindow",
            focusedValue: "",
            isProtected: false,
            elements: []
        )
        let applications = (0..<26).map { index in
            InstalledDesktopApplication(
                name: "App \(index)",
                bundleIdentifier: "example.app.\(index)",
                applicationURL: URL(fileURLWithPath: "/Applications/App \(index).app")
            )
        }

        let candidates = JevControlBridge.makeCandidates(
            from: snapshot,
            installedApplications: applications
        )

        #expect(candidates.contains { $0.id == "open:example.app.25" })
    }

    @Test("smartFormat adds capitalization and terminal punctuation")
    func smartFormatRules() {
        #expect(TranscriptCleanup.smartFormat("hello how are you today") == "Hello how are you today.")
        #expect(TranscriptCleanup.smartFormat("hello. how are you? i am great") == "Hello. How are you? I am great.")
        #expect(TranscriptCleanup.smartFormat("already punctuated.") == "Already punctuated.")
        #expect(TranscriptCleanup.smartFormat("ls -la", addsTerminalPunctuation: false) == "Ls -la")
        #expect(TranscriptCleanup.smartFormat("sayso period is period awesome") == "Sayso. Is. Awesome.")
    }
}
