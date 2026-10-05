import Foundation

/// What a surface needs to draw one activity, decided once so every surface agrees.
public struct SaysoActivityPresentation: Equatable, Sendable {
    public enum Tone: Equatable, Sendable { case quiet, active, success, attention, critical }

    public let title: String
    public let subtitle: String?
    public let tone: Tone
    public let symbolName: String
    public let actions: [SaysoAction]
    public let accessibilityLabel: String

    public var primaryActionID: String? { actions.first?.id }

    public init(_ activity: SaysoActivity) {
        title = activity.title
        subtitle = activity.progress.map { "\(Int(($0 * 100).rounded()))%" }
        actions = activity.actions
        accessibilityLabel = subtitle.map { "\(activity.title), \($0.dropLast()) percent" } ?? activity.title
        switch activity.kind {
        case .background: (tone, symbolName) = (.quiet, "clock")
        case .media: (tone, symbolName) = (.quiet, "music.note")
        case .ambient: (tone, symbolName) = (.quiet, "circle.fill")
        case .activeTask: (tone, symbolName) = (.active, "arrow.triangle.2.circlepath")
        case .completion: (tone, symbolName) = (.success, "checkmark.circle.fill")
        case .failure: (tone, symbolName) = (.critical, "exclamationmark.triangle.fill")
        case .confirmation: (tone, symbolName) = (.attention, "questionmark.circle.fill")
        }
    }
}
