import Foundation

/// Shows a result with at most ten significant digits in the given locale, so binary float noise never shows
/// (0.1 + 0.2 reads 0.3). Whole numbers below 10^15 are exact in a Double and show in full.
public struct CalculatorFormatter: Sendable {
    public static let significantDigits = 10
    private let locale: Locale

    public init(locale: Locale) {
        self.locale = locale
    }

    /// The number followed by the unit symbol, if any: "3.106855961 mi".
    public func string(for value: CalculatorValue) -> String {
        let number = string(for: value.number)
        guard let unit = value.unit else { return number }
        return "\(number) \(unit.symbol)"
    }

    public func string(for number: Double) -> String {
        // Also catches -0, which would otherwise read "-0".
        guard number != 0 else { return "0" }
        let formatter = NumberFormatter()
        formatter.locale = locale
        let magnitude = abs(number)
        if number == number.rounded(), magnitude < 1e15 {
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 0
        } else {
            formatter.usesSignificantDigits = true
            formatter.maximumSignificantDigits = Self.significantDigits
            // Outside this range ten digits would either drop the fraction silently or show only leading zeros.
            formatter.numberStyle = magnitude >= 1e-6 && magnitude < 1e10 ? .decimal : .scientific
        }
        return formatter.string(from: NSNumber(value: number)) ?? String(number)
    }
}
