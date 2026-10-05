import Foundation

/// How sin, cos and tan read their argument.
public enum CalculatorAngleUnit: Equatable, Sendable {
    case degrees
    case radians
}

/// Why an input has no result. Every failure is a value, never a trap or an infinite number.
public enum CalculatorError: Error, Equatable, Sendable {
    case empty
    case incomplete
    case unexpected(String)
    case unknownWord(String)
    case divisionByZero
    case overflow
    case undefined
    case tooLong(limit: Int)
    case tooDeep(limit: Int)

    public var message: String {
        switch self {
        case .empty: "Type a calculation"
        case .incomplete: "Incomplete expression"
        case let .unexpected(text): "Unexpected \u{201C}\(text)\u{201D}"
        case let .unknownWord(word): "Unknown word \u{201C}\(word)\u{201D}"
        case .divisionByZero: "Cannot divide by zero"
        case .overflow: "Too large to show"
        case .undefined: "Not a real number"
        case let .tooLong(limit): "Too long: at most \(limit) characters"
        case let .tooDeep(limit): "Nested too deeply: at most \(limit) levels"
        }
    }
}

public struct CalculatorValue: Equatable, Sendable {
    public let number: Double
}

/// A small recursive-descent evaluator. NSExpression is not used: it raises an Objective-C exception on bad input.
///
///     sum     := product (("+" | "-") product)*
///     product := unary (("*" | "×" | "x" | "/" | "÷") unary)*
///     unary   := ("-" | "+") unary | power
///     power   := postfix ("^" unary)?
///     postfix := primary ("%" ("of" unary)?)?
///     primary := number | constant | function (("(" sum ")") | unary) | "(" sum ")"
///
/// A bare percent is a hundredth, except as the right side of + or -, where it is that share of the left side:
/// "200 + 10%" is 220.
public enum CalculatorEngine {
    /// Longer input is refused before tokenizing, so the cost of any input is bounded.
    public static let maxLength = 500
    /// Nesting through parentheses, unary signs, exponents and function arguments; bounds the parser's recursion.
    public static let maxDepth = 64

    public static func evaluate(_ input: String, angle: CalculatorAngleUnit = .radians) -> Result<CalculatorValue, CalculatorError> {
        // utf8 first: counting characters of a huge string is itself linear, so cap the bytes looked at.
        guard input.utf8.count <= maxLength * 4, input.count <= maxLength else { return .failure(.tooLong(limit: maxLength)) }
        do {
            let tokens = try CalculatorTokenizer.tokens(of: input)
            guard !tokens.isEmpty else { return .failure(.empty) }
            var parser = CalculatorParser(tokens: tokens, angle: angle)
            let value = try parser.parseAll()
            return .success(CalculatorValue(number: value))
        } catch let error as CalculatorError {
            return .failure(error)
        } catch {
            return .failure(.incomplete)
        }
    }
}

enum CalculatorToken: Equatable {
    case number(Double)
    case word(String)
    case symbol(Character)

    var text: String {
        switch self {
        case let .number(value): String(value)
        case let .word(word): word
        case let .symbol(symbol): String(symbol)
        }
    }
}

enum CalculatorTokenizer {
    static let symbols: Set<Character> = ["+", "-", "−", "*", "×", "·", "/", "÷", "^", "(", ")", "%"]

    static func tokens(of input: String) throws -> [CalculatorToken] {
        let characters = Array(input)
        var tokens: [CalculatorToken] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
            } else if character.isASCII, character.isNumber || character == "." {
                tokens.append(.number(try number(in: characters, from: &index)))
            } else if isWordCharacter(character) {
                let start = index
                while index < characters.count, isWordCharacter(characters[index]) { index += 1 }
                tokens.append(.word(String(characters[start..<index])))
            } else if symbols.contains(character) {
                tokens.append(.symbol(character))
                index += 1
            } else {
                throw CalculatorError.unexpected(String(character))
            }
        }
        return tokens
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character == "°"
    }

    /// Digits with an optional fraction. A comma is a thousands separator only between groups of exactly three
    /// digits after a first group of one to three, so "1,20" and "1234,567" are refused rather than misread.
    private static func number(in characters: [Character], from index: inout Int) throws -> Double {
        func isDigit(_ offset: Int) -> Bool {
            offset < characters.count && characters[offset].isASCII && characters[offset].isNumber
        }
        var digits = ""
        var groupLength = 0
        var grouped = false
        while index < characters.count {
            if isDigit(index) {
                digits.append(characters[index])
                groupLength += 1
                index += 1
            } else if characters[index] == ",", !digits.isEmpty {
                let validGroup = grouped ? groupLength == 3 : groupLength <= 3
                guard validGroup, isDigit(index + 1), isDigit(index + 2), isDigit(index + 3), !isDigit(index + 4) else {
                    throw CalculatorError.unexpected(",")
                }
                grouped = true
                groupLength = 0
                index += 1
            } else {
                break
            }
        }
        if index < characters.count, characters[index] == "." {
            digits.append(".")
            index += 1
            while isDigit(index) {
                digits.append(characters[index])
                index += 1
            }
            if index < characters.count, characters[index] == "." || characters[index] == "," {
                throw CalculatorError.unexpected(String(characters[index]))
            }
        }
        guard digits != ".", let value = Double(digits) else { throw CalculatorError.unexpected(digits) }
        return value
    }
}

struct CalculatorParser {
    /// A value whose trailing "%" is not applied yet, so + and - can read it as a share of their left side.
    private struct Operand {
        var value: Double
        var percent = false

        var resolved: Double { percent ? value / 100 : value }
    }

    static let constants: [String: Double] = ["pi": .pi, "π": .pi, "e": M_E]
    static let functions: Set<String> = ["sqrt", "sin", "cos", "tan", "ln", "log", "abs", "round"]

    private let tokens: [CalculatorToken]
    private let angle: CalculatorAngleUnit
    private var position = 0
    private var depth = 0

    init(tokens: [CalculatorToken], angle: CalculatorAngleUnit) {
        self.tokens = tokens
        self.angle = angle
    }

    mutating func parseAll() throws -> Double {
        let value = try parseSum().resolved
        if let extra = peek { throw CalculatorError.unexpected(extra.text) }
        return try checked(value)
    }

    private var peek: CalculatorToken? { position < tokens.count ? tokens[position] : nil }

    private mutating func take(_ symbols: Set<Character>) -> Character? {
        guard case let .symbol(symbol) = peek, symbols.contains(symbol) else { return nil }
        position += 1
        return symbol
    }

    private mutating func takeWord(_ words: Set<String>) -> Bool {
        guard case let .word(word) = peek, words.contains(word.lowercased()) else { return false }
        position += 1
        return true
    }

    private mutating func parseSum() throws -> Operand {
        var value = try parseProduct()
        while let symbol = take(["+", "-", "−"]) {
            let right = try parseProduct()
            let base = value.resolved
            let amount = right.percent ? base * right.value / 100 : right.value
            value = Operand(value: try checked(symbol == "+" ? base + amount : base - amount))
        }
        return value
    }

    private mutating func parseProduct() throws -> Operand {
        var value = try parseUnary()
        while true {
            if take(["*", "×", "·"]) != nil || takeWord(["x"]) {
                value = Operand(value: try checked(value.resolved * parseUnary().resolved))
            } else if take(["/", "÷"]) != nil {
                let divisor = try parseUnary().resolved
                guard divisor != 0 else { throw CalculatorError.divisionByZero }
                value = Operand(value: try checked(value.resolved / divisor))
            } else {
                return value
            }
        }
    }

    /// Every recursive path passes through here, so this one counter bounds the recursion.
    private mutating func parseUnary() throws -> Operand {
        depth += 1
        defer { depth -= 1 }
        guard depth <= CalculatorEngine.maxDepth else { throw CalculatorError.tooDeep(limit: CalculatorEngine.maxDepth) }
        if take(["-", "−"]) != nil {
            var operand = try parseUnary()
            operand.value = -operand.value
            return operand
        }
        if take(["+"]) != nil { return try parseUnary() }
        return try parsePower()
    }

    private mutating func parsePower() throws -> Operand {
        let base = try parsePostfix()
        guard take(["^"]) != nil else { return base }
        let (root, exponent) = (base.resolved, try parseUnary().resolved)
        if root == 0, exponent < 0 { throw CalculatorError.divisionByZero }
        return Operand(value: try checked(pow(root, exponent)))
    }

    private mutating func parsePostfix() throws -> Operand {
        let operand = try parsePrimary()
        guard take(["%"]) != nil else { return operand }
        let share = Operand(value: operand.resolved, percent: true)
        guard takeWord(["of"]) else { return share }
        return Operand(value: try checked(share.resolved * parseUnary().resolved))
    }

    private mutating func parsePrimary() throws -> Operand {
        guard let token = peek else { throw CalculatorError.incomplete }
        position += 1
        switch token {
        case let .number(value):
            return Operand(value: try checked(value))
        case .symbol("("):
            let value = try parseSum()
            guard take([")"]) != nil else {
                if let extra = peek { throw CalculatorError.unexpected(extra.text) }
                throw CalculatorError.incomplete
            }
            return value
        case let .word(word):
            let name = word.lowercased()
            if let constant = Self.constants[name] { return Operand(value: constant) }
            guard Self.functions.contains(name) else { throw CalculatorError.unknownWord(word) }
            // "sin(30)^2" squares the sine: parentheses right after a function are its whole argument.
            let argument = if case .symbol("(") = peek { try parsePrimary() } else { try parseUnary() }
            return Operand(value: try apply(name, to: argument.resolved))
        case let .symbol(symbol):
            throw CalculatorError.unexpected(String(symbol))
        }
    }

    private func apply(_ function: String, to x: Double) throws -> Double {
        switch function {
        case "sqrt":
            guard x >= 0 else { throw CalculatorError.undefined }
            return sqrt(x)
        case "ln", "log":
            guard x > 0 else { throw CalculatorError.undefined }
            return function == "ln" ? log(x) : log10(x)
        case "abs":
            return abs(x)
        case "round":
            return x.rounded(.toNearestOrAwayFromZero)
        default:
            return try trigonometry(function, x)
        }
    }

    /// Whole multiples of a right angle use exact values, so sin(180) is 0 and tan(90) is undefined rather than
    /// 1.2e-16 and 1.6e16.
    private func trigonometry(_ function: String, _ x: Double) throws -> Double {
        let quarterTurns = angle == .degrees ? x / 90 : x / (Double.pi / 2)
        let nearest = quarterTurns.rounded()
        if abs(quarterTurns) < 1e15, abs(quarterTurns - nearest) <= 1e-12 * max(1, abs(quarterTurns)) {
            let turn = (Int(nearest) % 4 + 4) % 4
            let (sine, cosine) = ([0.0, 1, 0, -1][turn], [1.0, 0, -1, 0][turn])
            switch function {
            case "sin": return sine
            case "cos": return cosine
            default:
                guard cosine != 0 else { throw CalculatorError.undefined }
                return sine / cosine
            }
        }
        let radians = angle == .degrees ? x * .pi / 180 : x
        switch function {
        case "sin": return try checked(sin(radians))
        case "cos": return try checked(cos(radians))
        default: return try checked(tan(radians))
        }
    }

    /// The first infinite or NaN intermediate becomes the error, so a later step cannot hide it.
    private func checked(_ value: Double) throws -> Double {
        if value.isNaN { throw CalculatorError.undefined }
        if value.isInfinite { throw CalculatorError.overflow }
        return value
    }
}
