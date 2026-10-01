import Foundation
import Testing
@testable import SaysoCore

private func typedText(goal: String, from: Int, to: Int) throws -> String? {
    let snapshot = DesktopSnapshot(
        processIdentifier: 1, applicationName: "TextEdit", windowTitle: "Untitled",
        focusedRole: "AXTextArea", focusedValue: "", isProtected: false,
        elements: [DesktopElement(id: "field", role: "AXTextArea", title: "Body", supportsPress: false, supportsFocus: true)]
    )
    let offer = JevControlBridge.makeCycleOffer(goal: goal, snapshot: snapshot, recentActions: [], installedApplications: [])
    func choice(_ id: String) -> [String: Any] {
        ["type": "choice", "choice": id, "confidence": 0.99, "probabilities": [id: 0.99]]
    }
    let data = try JSONSerialization.data(withJSONObject: [
        "answers": [
            "operation": choice("TYPE_TEXT"),
            "type_target": choice("focus:field"),
            "type_from": choice("w\(from)"),
            "type_to": choice("w\(to)"),
            "finishes": ["type": "noul", "noul": 0.2],
        ],
    ])
    let decision = try JSONDecoder().decode(JevDecision.self, from: data)
    guard case let .execute(step, _) = try JevControlBridge.planCycleStep(from: decision, offer: offer),
          case let .typeInto(_, text, _) = step.action else { return nil }
    return text
}

@Test func typedTextKeepsPunctuationThatBelongsToTheRequestedWords() throws {
    #expect(try typedText(goal: "Type Hello, world! into the field", from: 1, to: 2) == "Hello, world!")
    #expect(try typedText(goal: "Type (draft) v1.2. please", from: 1, to: 2) == "(draft) v1.2.")
    #expect(try typedText(goal: "Type don't panic now", from: 1, to: 2) == "don't panic")
    #expect(try typedText(goal: "Type $5.00 total", from: 1, to: 1) == "$5.00")
}

@Test func typedTextDropsOnlyQuotesThatWrapTheWholeSelection() throws {
    #expect(try typedText(goal: "Type \"hello world\" now", from: 1, to: 2) == "hello world")
    #expect(try typedText(goal: "Type “hello world” now", from: 1, to: 2) == "hello world")
    #expect(try typedText(goal: "Type 'hello world' now", from: 1, to: 2) == "hello world")
    #expect(try typedText(goal: "Type \"hello\" and \"world\" now", from: 1, to: 3) == "\"hello\" and \"world\"")
}
