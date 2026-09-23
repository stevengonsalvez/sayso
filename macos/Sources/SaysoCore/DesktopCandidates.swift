import Foundation

public struct DesktopCandidateID: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let rawValue: String

    public var id: String { rawValue }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(
        processIdentifier: Int32,
        windowTitle: String,
        role: String,
        identifier: String?,
        ancestry: [Int]
    ) {
        let locator = identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [
            String(processIdentifier),
            windowTitle,
            role,
            locator?.isEmpty == false ? locator! : "",
            ancestry.map(String.init).joined(separator: "."),
        ]
        rawValue = Data(parts.joined(separator: "\u{1E}").utf8).base64EncodedString()
    }
}

public struct DesktopCandidateState: Codable, Equatable, Sendable {
    public let isEnabled: Bool
    public let supportsPress: Bool
    public let supportsFocus: Bool
    public let isProtected: Bool

    public init(
        isEnabled: Bool,
        supportsPress: Bool,
        supportsFocus: Bool,
        isProtected: Bool
    ) {
        self.isEnabled = isEnabled
        self.supportsPress = supportsPress
        self.supportsFocus = supportsFocus
        self.isProtected = isProtected
    }

    public var isTargetable: Bool {
        isEnabled && supportsPress && !isProtected
    }

    public var isSelectable: Bool {
        isEnabled && supportsFocus && !isProtected
    }
}

public struct DesktopCandidate: Codable, Equatable, Identifiable, Sendable {
    public let id: DesktopCandidateID
    public let role: String
    public let title: String
    public let identifier: String?
    public let state: DesktopCandidateState

    public init(
        id: DesktopCandidateID,
        role: String,
        title: String,
        identifier: String? = nil,
        state: DesktopCandidateState
    ) {
        self.id = id
        self.role = role
        self.title = title
        self.identifier = identifier
        self.state = state
    }
}

public struct DesktopCandidateSnapshot: Codable, Equatable, Sendable {
    public let processIdentifier: Int32
    public let applicationName: String
    public let windowTitle: String
    public let candidates: [DesktopCandidate]

    public init(
        processIdentifier: Int32,
        applicationName: String,
        windowTitle: String,
        candidates: [DesktopCandidate]
    ) {
        self.processIdentifier = processIdentifier
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.candidates = candidates
    }
}

public enum DesktopCandidateResolution: Equatable, Sendable {
    case resolved(DesktopCandidate)
    case notFound
    case ambiguous([DesktopCandidateID])
    case excluded([DesktopCandidateID])
}

public enum DesktopCandidateResolver {
    public static func resolve(_ query: String, in snapshot: DesktopCandidateSnapshot) -> DesktopCandidateResolution {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return .notFound }

        let matches = snapshot.candidates.filter {
            normalize($0.id.rawValue) == normalizedQuery ||
                normalize($0.title) == normalizedQuery ||
                normalize($0.identifier ?? "") == normalizedQuery
        }
        let targetable = matches.filter(\.state.isTargetable)
        if targetable.count == 1, let candidate = targetable.first {
            return .resolved(candidate)
        }
        if targetable.count > 1 {
            return .ambiguous(targetable.map(\.id).sorted { $0.rawValue < $1.rawValue })
        }
        if !matches.isEmpty {
            return .excluded(matches.map(\.id).sorted { $0.rawValue < $1.rawValue })
        }
        return .notFound
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
