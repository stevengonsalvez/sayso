import Foundation

/// Strips tracking query parameters from a copied link; nil when there is nothing to clean.
public enum ClipboardLinkCleaner {
    private static let trackingNames: Set<String> = ["fbclid", "gclid", "igshid", "mc_cid", "mc_eid", "si", "msclkid", "yclid"]

    public static func cleaned(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let items = components.queryItems else { return nil }
        let kept = items.filter { !isTracking($0.name) }
        guard kept.count != items.count else { return nil }
        components.queryItems = kept.isEmpty ? nil : kept
        return components.string
    }

    private static func isTracking(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.hasPrefix("utm_") || trackingNames.contains(lowered)
    }
}
