import Foundation

/// The one action a tap on the status text may run, bound to the exact activity that was painted.
public struct NotchTapAction: Equatable, Sendable {
    public let moduleID: String
    public let stackID: String
    public let actionID: String
    public let title: String
}

public struct NotchStatus: Equatable, Sendable {
    public let text: String
    /// Buttons that must be pressed explicitly; never triggered by tapping the status text.
    public let criticalActions: [SaysoAction]
    /// Set only for a failure the user can safely retry; never for confirmations, clarifications or cancels.
    public let tapAction: NotchTapAction?
    /// Action the "Dismiss" menu item should run; a critical review dismisses as Deny, never as a silent clear.
    public let dismissActionID: String?
    /// The activity the text paints; nil when dictation, a notice or Control status shows instead, so controls
    /// that belong to an activity are never drawn beside unrelated text.
    public let activity: SaysoActivity?
}

/// One owner for what the notch status line says and which actions it may expose.
public enum NotchStatusPolicy {
    public static func resolve(
        partialText: String,
        isLive: Bool,
        isControl: Bool,
        notice: String?,
        controlStatus: String,
        primary: SaysoActivity?,
        isListening: Bool? = nil
    ) -> NotchStatus {
        if let primary, primary.interruption == .critical {
            let denial = primary.actions.first { $0.id == "dismiss" || $0.id == "deny" || $0.id.hasPrefix("deny-") }
            return NotchStatus(
                text: SaysoActivityPresentation(primary).title,
                criticalActions: primary.actions,
                tapAction: nil,
                dismissActionID: denial?.id,
                activity: primary
            )
        }
        func plain(_ text: String, tap: NotchTapAction? = nil, activity: SaysoActivity? = nil) -> NotchStatus {
            NotchStatus(text: text, criticalActions: [], tapAction: tap, dismissActionID: nil, activity: activity)
        }
        if !partialText.isEmpty, isLive || !isControl { return plain(partialText) }
        if let notice { return plain(notice) }
        if !isLive, !isControl, let primary {
            let presentation = SaysoActivityPresentation(primary)
            let text = [presentation.title, presentation.subtitle].compactMap { $0 }.joined(separator: " · ")
            let retry = primary.kind == .failure ? primary.actions.first { $0.id == "retry" } : nil
            return plain(text, tap: retry.map {
                NotchTapAction(moduleID: primary.moduleID, stackID: primary.stackID, actionID: $0.id, title: $0.title)
            }, activity: primary)
        }
        if isControl { return plain(controlStatus) }
        if isListening ?? isLive { return plain("Listening for dictation") }
        return plain("Ready to dictate into the focused app")
    }
}
