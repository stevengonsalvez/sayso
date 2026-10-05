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

/// Deterministic pseudo-random source so a fuzz failure reproduces.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

@Suite struct CalculatorEngineErrorTests {
    @Test func divisionByZeroIsAClearErrorNeverInfinity() {
        #expect(failure("1/0") == .divisionByZero)
        #expect(failure("1 ÷ (2 - 2)") == .divisionByZero)
        #expect(failure("0 ^ -1") == .divisionByZero)
        #expect(CalculatorError.divisionByZero.message == "Cannot divide by zero")
    }

    @Test func overflowIsAClearErrorNeverInfinity() {
        #expect(failure("10 ^ 400") == .overflow)
        #expect(failure("9 ^ 9 ^ 9") == .overflow)
        #expect(failure("10^200 * 10^200") == .overflow)
        #expect(failure("10^400 - 10^400") == .overflow, "the first overflow wins over the NaN it would lead to")
        #expect(failure(String(repeating: "9", count: 400)) == .overflow)
        #expect(CalculatorError.overflow.message == "Too large to show")
    }

    @Test func notANumberIsAClearError() {
        #expect(failure("(-8) ^ 0.5") == .undefined)
        #expect(CalculatorError.undefined.message == "Not a real number")
    }

    @Test func longInputIsRejectedBeforeAnyParsing() throws {
        let tenThousand = String(repeating: "1+", count: 5000)
        #expect(tenThousand.count == 10_000)
        let start = ContinuousClock.now
        #expect(failure(tenThousand) == .tooLong(limit: CalculatorEngine.maxLength))
        #expect(ContinuousClock.now - start < .milliseconds(200))
        #expect(failure(String(repeating: "(", count: 5000) + "1" + String(repeating: ")", count: 5000)) == .tooLong(limit: CalculatorEngine.maxLength))
        let atLimit = String(repeating: "1+", count: (CalculatorEngine.maxLength - 1) / 2) + "1"
        #expect(atLimit.count <= CalculatorEngine.maxLength)
        #expect(try number(atLimit) == Double((CalculatorEngine.maxLength - 1) / 2 + 1))
    }

    @Test func deepNestingIsRejectedWithinTheDepthBound() throws {
        let depth = CalculatorEngine.maxDepth
        func nested(_ count: Int) -> String { String(repeating: "(", count: count) + "1" + String(repeating: ")", count: count) }
        #expect(failure(nested(depth + 50)) == .tooDeep(limit: depth))
        #expect(failure(String(repeating: "-", count: 300) + "1") == .tooDeep(limit: depth))
        #expect(failure(String(repeating: "2^", count: 150) + "1") == .tooDeep(limit: depth))
        #expect(try number(nested(depth / 2)) == 1, "ordinary nesting still works")
    }

    @Test func randomInputNeverCrashesAndNeverYieldsANonFiniteNumber() {
        var generator = SeededGenerator(state: 42)
        let alphabet = Array("0123456789+-−*×x/÷^().,% piesqrtlnogabsundinf kmc")
        for _ in 0..<2000 {
            let length = Int.random(in: 0...120, using: &generator)
            let input = String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
            if case let .success(value) = CalculatorEngine.evaluate(input) {
                #expect(value.number.isFinite, "\(input) gave \(value.number)")
            }
        }
    }
}

private func close(_ a: Double, _ b: Double, within tolerance: Double = 1e-12) -> Bool { abs(a - b) <= tolerance }

@Suite struct CalculatorEngineFunctionTests {
    @Test func percentOfAndPercentAddedOrTakenOff() throws {
        #expect(try number("15% of 80") == 12)
        #expect(try number("15 % of 80") == 12)
        #expect(try number("200 + 10%") == 220)
        #expect(try number("200 - 10%") == 180)
        #expect(try number("50 * 10%") == 5)
        #expect(try number("10%") == 0.1)
        #expect(try number("50% of 80 + 10%") == 44)
        #expect(failure("10% of") == .incomplete)
    }

    @Test func piAndEAreConstants() throws {
        #expect(try number("pi") == Double.pi)
        #expect(try number("π") == Double.pi)
        #expect(try number("2 * e") == 2 * M_E)
        #expect(try number("PI") == Double.pi, "words are case insensitive")
    }

    @Test func rootsLogarithmsAbsoluteValueAndRounding() throws {
        #expect(try number("sqrt(16)") == 4)
        #expect(try number("sqrt 16") == 4)
        #expect(try number("ln(e)") == 1)
        #expect(try number("log(1000)") == 3)
        #expect(try number("abs(-3)") == 3)
        #expect(try number("round(2.5)") == 3)
        #expect(try number("round(-2.5)") == -3)
        #expect(try number("round(2.4)") == 2)
        #expect(failure("sqrt(-1)") == .undefined)
        #expect(failure("ln(0)") == .undefined)
        #expect(failure("log(-1)") == .undefined)
        #expect(failure("sqrt") == .incomplete)
        #expect(failure("foo(2)") == .unknownWord("foo"))
    }

    @Test func trigonometryReadsDegreesOrRadiansAsSet() throws {
        #expect(close(try number("sin(30)", angle: .degrees), 0.5))
        #expect(try number("sin(90)", angle: .degrees) == 1)
        #expect(try number("sin(180)", angle: .degrees) == 0, "exact at multiples of a right angle, no float noise")
        #expect(try number("cos(90)", angle: .degrees) == 0)
        #expect(close(try number("tan(45)", angle: .degrees), 1))
        #expect(failure("tan(90)", angle: .degrees) == .undefined)
        #expect(failure("tan(270)", angle: .degrees) == .undefined)

        #expect(close(try number("sin(1)", angle: .radians), 0.8414709848078965))
        #expect(try number("sin(pi)", angle: .radians) == 0)
        #expect(try number("cos(pi / 2)", angle: .radians) == 0)
        #expect(failure("tan(pi / 2)", angle: .radians) == .undefined)
        #expect(close(try number("sin(90)", angle: .radians), 0.8939966636005579))
        #expect(close(try number("sin(30)^2", angle: .degrees), 0.25), "a function applies to its parentheses before the exponent")
        #expect(try number("cos 0") == 1)
    }
}
