import Foundation

/// One chosen place: an IANA time zone identifier and the label the user sees.
public struct WorldClockZone: Codable, Equatable, Sendable {
    public let identifier: String
    public let city: String

    public init(identifier: String, city: String) {
        self.identifier = identifier
        self.city = city
    }
}

/// Where the chosen zones are kept between launches.
public protocol WorldClocksStore: Sendable {
    func load() -> [WorldClockZone]
    func save(_ zones: [WorldClockZone])
}

/// Keeps the list as JSON under one key. Missing or unreadable data reads as an empty list, and an unreadable
/// entry is skipped rather than losing the rest.
public final class UserDefaultsWorldClocksStore: WorldClocksStore, @unchecked Sendable {
    public static let key = "ai.sayso.notch.worldClocks.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [WorldClockZone] {
        guard let data = defaults.data(forKey: Self.key),
              let entries = try? JSONDecoder().decode([Lenient].self, from: data) else { return [] }
        return entries.compactMap(\.zone)
    }

    public func save(_ zones: [WorldClockZone]) {
        guard let data = try? JSONEncoder().encode(zones) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private struct Lenient: Decodable {
        let zone: WorldClockZone?
        init(from decoder: Decoder) throws { zone = try? WorldClockZone(from: decoder) }
    }
}
