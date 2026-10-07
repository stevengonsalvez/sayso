import Foundation

/// A battery condition worth a notch line. Each has its own line, so dismissing one never hides the other. Each
/// enters at one threshold and clears at a safer one, so a reading that wobbles around the threshold never makes the
/// line flap.
enum BatteryHealthAlert: String, CaseIterable, Sendable {
    case worn
    case hot

    /// Health below this whole percent is notable (the Replace soon label)...
    static let wornBelowPercent = BatteryCondition.servicePercent
    /// ...until it reads at least this again.
    static let wornRecoveredPercent = 62
    /// At or above this temperature is notable...
    static let hotCelsius = 45.0
    /// ...until it is at or below this again.
    static let cooledCelsius = 42.0

    var stackID: String { "battery-health-\(rawValue)" }

    init?(stackID: String) {
        guard let alert = Self.allCases.first(where: { $0.stackID == stackID }) else { return nil }
        self = alert
    }

    /// True enters, false clears, nil keeps whatever state the condition is already in. A missing figure, or no
    /// battery at all, cannot vouch for a line, so it clears.
    func verdict(for snapshot: BatteryHealthSnapshot) -> Bool? {
        switch self {
        case .worn:
            guard let percent = snapshot.healthPercent else { return false }
            if percent < Self.wornBelowPercent { return true }
            return percent >= Self.wornRecoveredPercent ? false : nil
        case .hot:
            guard let celsius = snapshot.temperatureCelsius else { return false }
            if celsius >= Self.hotCelsius { return true }
            return celsius <= Self.cooledCelsius ? false : nil
        }
    }

    /// The hot title holds no figure: the temperature moves on every sample, and each new title repaints the notch.
    func title(for snapshot: BatteryHealthSnapshot) -> String {
        switch self {
        case .worn: "Battery health \(snapshot.healthText)"
        case .hot: "Battery is hot, over \(Int(Self.hotCelsius)) °C"
        }
    }
}
