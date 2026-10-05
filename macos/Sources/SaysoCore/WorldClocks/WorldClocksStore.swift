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
