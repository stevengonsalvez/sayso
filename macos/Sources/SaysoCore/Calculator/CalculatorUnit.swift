import Foundation

/// A unit the calculator converts between. Names are matched case-insensitively, so "mb" is a megabyte; bits are
/// written out ("bits"). Volumes are US customary.
public struct CalculatorUnit: Equatable, Sendable {
    public enum Dimension: Sendable {
        case length, mass, temperature, volume, speed, dataSize
    }

    public let symbol: String
    public let dimension: Dimension
    /// In the base unit of the dimension (metre, kilogram, kelvin, litre, metre per second, byte):
    /// base = (value + offset) * scale. Only temperatures have an offset.
    let scale: Double
    let offset: Double

    public static func named(_ name: String) -> CalculatorUnit? { table[name.lowercased()] }

    /// Rounded to 12 significant digits, two more than are shown: this drops the noise of binary factors and of
    /// temperature offsets cancelling (0 °C was 31.999999999999943 °F), which reaches the 15th digit. A result
    /// that is tiny next to the terms it came from is that noise alone (32 °F was 5.7e-14 °C) and reads 0. Whole
    /// results, and results of 10^12 or more, are left alone: the formatter shows whole numbers digit for digit,
    /// so rounding them would invent digits (1 TiB was 1,099,511,627,780 B).
    func convert(_ value: Double, to target: CalculatorUnit) -> Double {
        let scaled = (value + offset) * scale / target.scale
        let converted = scaled - target.offset
        guard converted.isFinite else { return converted }
        if abs(converted) <= 1e-12 * max(abs(scaled), abs(target.offset)) { return 0 }
        guard converted != converted.rounded(), abs(converted) < 1e12 else { return converted }
        return Double(String(format: "%.11e", converted)) ?? converted
    }

    private static let table: [String: CalculatorUnit] = {
        var table: [String: CalculatorUnit] = [:]
        func add(_ symbol: String, _ dimension: Dimension, _ scale: Double, offset: Double = 0, _ names: [String]) {
            let unit = CalculatorUnit(symbol: symbol, dimension: dimension, scale: scale, offset: offset)
            for name in names { table[name] = unit }
        }
        add("mm", .length, 0.001, ["mm", "millimeter", "millimeters", "millimetre", "millimetres"])
        add("cm", .length, 0.01, ["cm", "centimeter", "centimeters", "centimetre", "centimetres"])
        add("m", .length, 1, ["m", "meter", "meters", "metre", "metres"])
        add("km", .length, 1000, ["km", "kilometer", "kilometers", "kilometre", "kilometres"])
        add("in", .length, 0.0254, ["in", "inch", "inches"])
        add("ft", .length, 0.3048, ["ft", "foot", "feet"])
        add("yd", .length, 0.9144, ["yd", "yard", "yards"])
        add("mi", .length, 1609.344, ["mi", "mile", "miles"])

        add("mg", .mass, 0.000001, ["mg", "milligram", "milligrams"])
        add("g", .mass, 0.001, ["g", "gram", "grams"])
        add("kg", .mass, 1, ["kg", "kilogram", "kilograms", "kilo", "kilos"])
        add("t", .mass, 1000, ["t", "tonne", "tonnes"])
        add("oz", .mass, 0.028349523125, ["oz", "ounce", "ounces"])
        add("lb", .mass, 0.45359237, ["lb", "lbs", "pound", "pounds"])
        add("st", .mass, 6.35029318, ["st", "stone", "stones"])

        add("°C", .temperature, 1, offset: 273.15, ["c", "°c", "celsius"])
        add("°F", .temperature, 5.0 / 9.0, offset: 459.67, ["f", "°f", "fahrenheit"])
        add("K", .temperature, 1, ["k", "kelvin"])

        add("mL", .volume, 0.001, ["ml", "milliliter", "milliliters", "millilitre", "millilitres"])
        add("L", .volume, 1, ["l", "liter", "liters", "litre", "litres"])
        add("tsp", .volume, 0.00492892159375, ["tsp", "teaspoon", "teaspoons"])
        add("tbsp", .volume, 0.01478676478125, ["tbsp", "tablespoon", "tablespoons"])
        add("fl oz", .volume, 0.0295735295625, ["floz"])
        add("cup", .volume, 0.2365882365, ["cup", "cups"])
        add("pt", .volume, 0.473176473, ["pt", "pint", "pints"])
        add("qt", .volume, 0.946352946, ["qt", "quart", "quarts"])
        add("gal", .volume, 3.785411784, ["gal", "gallon", "gallons"])

        add("m/s", .speed, 1, ["m/s", "mps"])
        add("km/h", .speed, 1 / 3.6, ["km/h", "kph", "kmh"])
        add("mph", .speed, 0.44704, ["mph", "mi/h"])
        add("kn", .speed, 1852.0 / 3600.0, ["kn", "knot", "knots"])
        add("ft/s", .speed, 0.3048, ["ft/s", "fps"])

        add("bit", .dataSize, 0.125, ["bit", "bits"])
        add("B", .dataSize, 1, ["b", "byte", "bytes"])
        add("KB", .dataSize, 1e3, ["kb", "kilobyte", "kilobytes"])
        add("MB", .dataSize, 1e6, ["mb", "megabyte", "megabytes"])
        add("GB", .dataSize, 1e9, ["gb", "gigabyte", "gigabytes"])
        add("TB", .dataSize, 1e12, ["tb", "terabyte", "terabytes"])
        add("KiB", .dataSize, 1024, ["kib"])
        add("MiB", .dataSize, 1_048_576, ["mib"])
        add("GiB", .dataSize, 1_073_741_824, ["gib"])
        add("TiB", .dataSize, 1_099_511_627_776, ["tib"])
        return table
    }()
}
