import Foundation

/// The ways a colour can be shown and copied.
public enum ColorPickerFormat: String, CaseIterable, Sendable {
    case hex, rgb, hsl
}

/// Hue in whole degrees 0...359, saturation and lightness in whole percents 0...100.
public struct ColorPickerHSL: Equatable, Sendable {
    public let hue: Int
    public let saturation: Int
    public let lightness: Int

    public init(hue: Int, saturation: Int, lightness: Int) {
        self.hue = hue
        self.saturation = saturation
        self.lightness = lightness
    }

    /// "hsl(210, 50%, 40%)"
    public var text: String { "hsl(\(hue), \(saturation)%, \(lightness)%)" }
}

/// One 8-bit sRGB colour, as picked from the screen or typed.
public struct ColorPickerColor: Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    /// Longer input is refused before any parsing, counted as given (before trimming).
    public static let maxInputLength = 64

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// From sRGB components in 0...1. A wide-gamut pixel can fall outside that range, so values are clamped, and NaN
    /// reads as 0.
    public init(srgbRed: Double, green: Double, blue: Double) {
        self.init(red: Self.channel(srgbRed), green: Self.channel(green), blue: Self.channel(blue))
    }

    /// "#336699"
    public var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    /// "rgb(51, 102, 153)"
    public var rgb: String { "rgb(\(red), \(green), \(blue))" }

    public var hsl: ColorPickerHSL {
        let (r, g, b) = (Double(red) / 255, Double(green) / 255, Double(blue) / 255)
        let high = max(r, g, b), low = min(r, g, b), delta = high - low
        let lightness = (high + low) / 2
        guard delta > 0 else { return ColorPickerHSL(hue: 0, saturation: 0, lightness: Self.percent(lightness)) }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        let sector = if high == r { (g - b) / delta } else if high == g { (b - r) / delta + 2 } else { (r - g) / delta + 4 }
        // A hue just under 360 rounds up to 360, which is 0.
        let hue = Int((sector * 60 + 360).truncatingRemainder(dividingBy: 360).rounded()) % 360
        return ColorPickerHSL(hue: hue, saturation: Self.percent(saturation), lightness: Self.percent(lightness))
    }

    public func text(_ format: ColorPickerFormat) -> String {
        switch format {
        case .hex: hex
        case .rgb: rgb
        case .hsl: hsl.text
        }
    }

    /// Reads `#abc`, `#aabbcc`, `rgb(51, 102, 153)` and `hsl(210 50% 40%)`, with commas or spaces between values and in
    /// either case. Out-of-range numbers are clamped (rgb to 0...255, percents to 0...100) and hue wraps around 360;
    /// anything else, including exponents, `inf` and `nan`, is not a colour.
    public static func parse(_ input: String) -> ColorPickerColor? {
        guard input.utf8.count <= maxInputLength else { return nil }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("#") { return hex(text.dropFirst()) }
        if let values = arguments(of: "rgb", in: text) {
            let numbers = values.compactMap(number)
            guard numbers.count == 3 else { return nil }
            return ColorPickerColor(srgbRed: numbers[0] / 255, green: numbers[1] / 255, blue: numbers[2] / 255)
        }
        if let values = arguments(of: "hsl", in: text) {
            guard let hue = number(values[0]), let saturation = percentNumber(values[1]), let lightness = percentNumber(values[2])
            else { return nil }
            return fromHSL(hue: hue, saturation: saturation, lightness: lightness)
        }
        return nil
    }

    private static func channel(_ component: Double) -> UInt8 {
        guard !component.isNaN else { return 0 }
        return UInt8((min(max(component, 0), 1) * 255).rounded())
    }

    private static func percent(_ fraction: Double) -> Int { min(max(Int((fraction * 100).rounded()), 0), 100) }

    private static func hex(_ digits: Substring) -> ColorPickerColor? {
        guard [3, 6].contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        let pairs = digits.count == 3 ? digits.map { "\($0)\($0)" } : stride(from: 0, to: 6, by: 2).map { offset in
            let start = digits.index(digits.startIndex, offsetBy: offset)
            return String(digits[start..<digits.index(start, offsetBy: 2)])
        }
        let values = pairs.compactMap { UInt8($0, radix: 16) }
        return ColorPickerColor(red: values[0], green: values[1], blue: values[2])
    }

    /// The three values inside `name(...)`, separated by commas or, with no comma at all, by spaces.
    private static func arguments(of name: String, in text: String) -> [String]? {
        guard text.hasPrefix(name + "("), text.hasSuffix(")") else { return nil }
        let inner = text.dropFirst(name.count + 1).dropLast()
        let values = inner.contains(",")
            ? inner.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            : inner.split(whereSeparator: \.isWhitespace).map(String.init)
        guard values.count == 3, values.allSatisfy({ !$0.isEmpty }) else { return nil }
        return values
    }

    /// A plain decimal: optional sign, digits, optional fraction. No exponent, hex, `inf` or `nan`.
    private static func number(_ token: String) -> Double? {
        let unsigned = token.first == "-" || token.first == "+" ? token.dropFirst() : Substring(token)
        let pieces = unsigned.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(pieces.count), pieces.last?.isEmpty == false,
              pieces.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } })
        else { return nil }
        return Double(token).flatMap { $0.isFinite ? $0 : nil }
    }

    /// A number with or without one trailing percent sign.
    private static func percentNumber(_ token: String) -> Double? {
        number(token.hasSuffix("%") ? String(token.dropLast()) : token)
    }

    private static func fromHSL(hue: Double, saturation: Double, lightness: Double) -> ColorPickerColor {
        let wrapped = hue.truncatingRemainder(dividingBy: 360)
        let sector = (wrapped < 0 ? wrapped + 360 : wrapped) / 60
        let s = min(max(saturation / 100, 0), 1), l = min(max(lightness / 100, 0), 1)
        let chroma = (1 - abs(2 * l - 1)) * s
        let x = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double) = switch sector {
        case ..<1: (chroma, x, 0)
        case ..<2: (x, chroma, 0)
        case ..<3: (0, chroma, x)
        case ..<4: (0, x, chroma)
        case ..<5: (x, 0, chroma)
        default: (chroma, 0, x)
        }
        let m = l - chroma / 2
        return ColorPickerColor(srgbRed: r + m, green: g + m, blue: b + m)
    }
}
