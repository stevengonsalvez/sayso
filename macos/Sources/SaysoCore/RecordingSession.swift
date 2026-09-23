import Foundation

public enum RecordingSessionPhase: String, Codable, Equatable, Sendable {
    case starting
    case listening
    case processing
    case delivered
    case copiedToClipboard
    case edited
    case handedToControl
    case failed
    case cancelled
}

public enum TextDeliveryMethod: String, Codable, Equatable, Sendable {
    case directInsertion
    case pidPaste
    case clipboard
}

public struct RecordingDestination: Codable, Equatable, Sendable {
    public let processIdentifier: Int32
    public let applicationName: String
    public let fieldRole: String
    public let windowTitle: String

    public init(processIdentifier: Int32, applicationName: String, fieldRole: String, windowTitle: String) {
        self.processIdentifier = processIdentifier
        self.applicationName = applicationName
        self.fieldRole = fieldRole
        self.windowTitle = windowTitle
    }
}

public struct RecordingSession: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public var updatedAt: Date
    public let language: DictationLanguage
    public let route: ProviderRoute
    public let destination: RecordingDestination?
    public var phase: RecordingSessionPhase
    public var finalText: String?
    public var delivery: TextDeliveryMethod?
    public var failure: String?

    public init(
        id: UUID = UUID(), startedAt: Date = .now, language: DictationLanguage,
        route: ProviderRoute, destination: RecordingDestination?
    ) {
        self.id = id
        self.startedAt = startedAt
        updatedAt = startedAt
        self.language = language
        self.route = route
        self.destination = destination
        phase = .starting
    }

    public mutating func transition(to phase: RecordingSessionPhase, now: Date = .now) {
        self.phase = phase
        updatedAt = now
    }

    public mutating func complete(
        text: String, delivery: TextDeliveryMethod, now: Date = .now
    ) {
        finalText = text
        self.delivery = delivery
        phase = delivery == .clipboard ? .copiedToClipboard : .delivered
        updatedAt = now
    }

    public mutating func completeVoiceEdit(_ text: String, now: Date = .now) {
        finalText = text
        phase = .edited
        updatedAt = now
    }

    public mutating func completeControlCommand(_ text: String, now: Date = .now) {
        finalText = text
        phase = .handedToControl
        updatedAt = now
    }

    public mutating func fail(_ message: String, now: Date = .now) {
        failure = message
        phase = .failed
        updatedAt = now
    }
}

public actor RecordingSessionStore {
    private let fileURL: URL

    public init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        if let fileURL {
            self.fileURL = fileURL
            return
        }
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SaysoNotch", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        self.fileURL = root.appendingPathComponent("recording-sessions.json")
    }

    public func all() -> [RecordingSession] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([RecordingSession].self, from: data)) ?? []
    }

    public func upsert(_ session: RecordingSession) {
        var sessions = all()
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
        sessions.sort { $0.updatedAt > $1.updatedAt }
        if sessions.count > 500 { sessions.removeLast(sessions.count - 500) }
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
