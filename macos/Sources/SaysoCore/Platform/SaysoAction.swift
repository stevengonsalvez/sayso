import Foundation

/// A typed, user-invocable action carried by an activity.
public struct SaysoAction: Equatable, Sendable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}
