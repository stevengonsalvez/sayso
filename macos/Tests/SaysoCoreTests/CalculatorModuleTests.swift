import Foundation
import Testing
@testable import SaysoCore

private func number(_ input: String, angle: CalculatorAngleUnit = .radians) throws -> Double {
    try CalculatorEngine.evaluate(input, angle: angle).get().number
}

private func failure(_ input: String, angle: CalculatorAngleUnit = .radians) -> CalculatorError? {
    if case let .failure(error) = CalculatorEngine.evaluate(input, angle: angle) { error } else { nil }
}

@Suite struct CalculatorEngineArithmeticTests {
    @Test func multiplicationAndDivisionBindTighterThanAdditionAndSubtraction() throws {
        #expect(try number("2 + 3 * 4") == 14)
        #expect(try number("10 - 4 / 2") == 8)
        #expect(try number("10 - 4 - 3") == 3, "subtraction is left associative")
        #expect(try number("64 / 4 / 2") == 8, "division is left associative")
    }

    @Test func parenthesesOverridePrecedence() throws {
        #expect(try number("(2 + 3) * 4") == 20)
        #expect(try number("((1 + 2) * (3 + 4))") == 21)
    }

    @Test func unaryMinusNegatesAndNests() throws {
        #expect(try number("-5 + 2") == -3)
        #expect(try number("3 * -2") == -6)
        #expect(try number("--4") == 4)
        #expect(try number("-(2 + 3)") == -5)
        #expect(try number("+7") == 7)
        #expect(try number("−3 + 1") == -2, "the typographic minus sign also negates")
    }

    @Test func exponentIsRightAssociativeAndBindsTighterThanUnaryMinus() throws {
        #expect(try number("2 ^ 10") == 1024)
        #expect(try number("2 ^ 3 ^ 2") == 512)
        #expect(try number("-2 ^ 2") == -4)
        #expect(try number("2 ^ -1") == 0.5)
    }

    @Test func letterXAndTheTimesSignBothMeanMultiply() throws {
        #expect(try number("12 x 3") == 36)
        #expect(try number("12 X 3") == 36)
        #expect(try number("12 × 3") == 36)
        #expect(try number("12x3") == 36)
        #expect(try number("12 ÷ 4") == 3)
    }

    @Test func decimalsAndThousandsSeparatorsAreRead() throws {
        #expect(try number("1,200.5") == 1200.5)
        #expect(try number("12,345,678") == 12_345_678)
        #expect(try number(".5 + 0.25") == 0.75)
        #expect(failure("1,20") != nil, "a comma that does not start a group of three digits is not a separator")
        #expect(failure("1234,567") != nil, "a group before a comma has at most three digits")
        #expect(failure("1.2.3") != nil)
    }

    @Test func emptyAndIncompleteInputAreErrorsNotCrashes() {
        #expect(failure("") == .empty)
        #expect(failure("   ") == .empty)
        #expect(failure("2 +") == .incomplete)
        #expect(failure("(2 + 3") == .incomplete)
        #expect(failure("2 + 3)") == .unexpected(")"))
        #expect(failure("2 $ 3") == .unexpected("$"))
        #expect(failure("2 + banana") == .unknownWord("banana"))
    }
}
