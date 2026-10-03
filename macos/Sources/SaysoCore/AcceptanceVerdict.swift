import Foundation

/// Pass/fail rule for the CLI dictation acceptance: proof of live partials and of the final target value.
public struct AcceptanceVerdict: Equatable, Sendable {
    public enum Delivery: Equatable, Sendable {
        case inserted
        case clipboard
        case failed(String)
    }

    public let ok: Bool
    public let error: String?

    public static func evaluate(
        expectedText: String,
        partialsApplied: [Bool],
        delivery: Delivery,
        observedTargetValue: String?,
        targetValueBefore: String? = nil
    ) -> AcceptanceVerdict {
        func fail(_ message: String) -> AcceptanceVerdict { .init(ok: false, error: message) }

        switch delivery {
        case .failed(let message): return fail(message)
        case .clipboard: return fail("Final text was copied, not inserted.")
        case .inserted: break
        }
        // Texts of two words or fewer produce no checkpoints, so no partial can be required.
        let needsPartials = expectedText.split(whereSeparator: \.isWhitespace).count > 2
        if needsPartials, !partialsApplied.contains(true) { return fail("No partial insertion was applied.") }
        guard let observed = observedTargetValue else {
            return fail("Target value could not be read to verify the insertion.")
        }
        func normalized(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        guard normalized(observed).contains(normalized(expectedText)) else {
            return fail("Target value does not contain the dictated text.")
        }
        if let before = targetValueBefore, normalized(before) == normalized(observed) {
            return fail("Target value did not change, so insertion is unproven.")
        }
        return .init(ok: true, error: nil)
    }
}
