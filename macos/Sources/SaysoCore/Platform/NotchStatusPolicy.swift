import Foundation

public struct NotchStatus: Equatable, Sendable {
    public let text: String
    /// Buttons that must be pressed explicitly; never triggered by tapping the status text.
    public let criticalActions: [SaysoAction]
    /// True only when the text is a non-critical module activity whose first action is safe to run on tap.
    public let tapRunsPrimaryAction: Bool
    /// Action the "Dismiss" menu item should run; a critical review dismisses as Deny, never as a silent clear.
    public let dismissActionID: String?
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
            let denial = primary.actions.first { $0.id == "deny" || $0.id == "dismiss" }
            return NotchStatus(
                text: SaysoActivityPresentation(primary).title,
                criticalActions: primary.actions,
                tapRunsPrimaryAction: false,
                dismissActionID: denial?.id
            )
        }
        func plain(_ text: String, tap: Bool = false) -> NotchStatus {
            NotchStatus(text: text, criticalActions: [], tapRunsPrimaryAction: tap, dismissActionID: nil)
        }
        if !partialText.isEmpty, isLive || !isControl { return plain(partialText) }
        if let notice { return plain(notice) }
        if !isLive, !isControl, let primary {
            let presentation = SaysoActivityPresentation(primary)
            let text = [presentation.title, presentation.subtitle].compactMap { $0 }.joined(separator: " · ")
            return plain(text, tap: !primary.actions.isEmpty)
        }
        if isControl { return plain(controlStatus) }
        if isListening ?? isLive { return plain("Listening for dictation") }
        return plain("Ready to dictate into the focused app")
    }
}
