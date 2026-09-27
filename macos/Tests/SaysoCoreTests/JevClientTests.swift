import Foundation
import Testing
@testable import SaysoCore

@Suite("Jev Client & Control Bridge Tests")
struct JevClientTests {

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
        if case let .key(key, _) = step.action {
            #expect(key == .return)
        } else {
            Issue.record("Expected .key action")
        }
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
