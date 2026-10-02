import Foundation

/// Decides whether a pasteboard change may enter history; password-manager items never do.
public enum ClipboardPrivacy {
    private static let excludedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "com.agilebits.onepassword",
    ]

    public static func shouldRecord(_ snapshot: ClipboardSnapshot) -> Bool {
        guard snapshot.types.isDisjoint(with: excludedTypes),
              let text = snapshot.text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return true
    }
}
