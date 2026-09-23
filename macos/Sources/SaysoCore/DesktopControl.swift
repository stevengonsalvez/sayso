import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public struct DesktopElement: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let role: String
    public let title: String

    public init(id: String, role: String, title: String) {
        self.id = id
        self.role = role
        self.title = title
    }
}

public struct DesktopSnapshot: Codable, Equatable, Sendable {
    public let processIdentifier: Int32
    public let applicationName: String
    public let windowTitle: String
    public let focusedRole: String
    public let focusedValue: String
    public let isProtected: Bool
    public let elements: [DesktopElement]

    public init(
        processIdentifier: Int32, applicationName: String, windowTitle: String,
        focusedRole: String, focusedValue: String, isProtected: Bool,
        elements: [DesktopElement] = []
    ) {
        self.processIdentifier = processIdentifier
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.focusedRole = focusedRole
        self.focusedValue = focusedValue
        self.isProtected = isProtected
        self.elements = elements
    }

    public var fingerprint: String {
        let visibleControls = elements.map { [$0.id, $0.role, $0.title].joined(separator: "\u{1F}") }
            .joined(separator: "\u{1E}")
        return [String(processIdentifier), applicationName, windowTitle, focusedRole, focusedValue, isProtected.description, visibleControls]
            .joined(separator: "|")
    }
}

public enum DesktopKey: String, Codable, CaseIterable, Sendable {
    case tab
    case up
    case down
    case left
    case right
    case `return`
    case escape
    case goBack
    case nextTab
    case previousTab

    static func parse(_ value: String) -> DesktopKey? {
        switch value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "tab": .tab
        case "up", "up arrow": .up
        case "down", "down arrow": .down
        case "left", "left arrow": .left
        case "right", "right arrow": .right
        case "return", "enter": .return
        case "escape", "esc": .escape
        default: nil
        }
    }

    var virtualKey: CGKeyCode {
        switch self {
        case .tab: 48
        case .up: 126
        case .down: 125
        case .left: 123
        case .right: 124
        case .return: 36
        case .escape: 53
        case .goBack: 33
        case .nextTab: 48
        case .previousTab: 48
        }
    }

    var modifierFlags: CGEventFlags {
        switch self {
        case .goBack: .maskCommand
        case .nextTab: .maskControl
        case .previousTab: [.maskControl, .maskShift]
        default: []
        }
    }
}

public struct InstalledDesktopApplication: Equatable, Sendable {
    public let name: String
    public let bundleIdentifier: String
    public let applicationURL: URL

    public init(name: String, bundleIdentifier: String, applicationURL: URL) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.applicationURL = applicationURL.standardizedFileURL
    }

    public static func available(fileManager: FileManager = .default) -> [InstalledDesktopApplication] {
        let standardDirectories = fileManager.urls(
            for: .applicationDirectory,
            in: [.userDomainMask, .localDomainMask, .systemDomainMask]
        ) + [URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true)]
        var applications: [InstalledDesktopApplication] = []
        var seenPaths = Set<String>()

        for directory in standardDirectories {
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let applicationURL as URL in enumerator where applicationURL.pathExtension == "app" {
                let standardizedURL = applicationURL.standardizedFileURL
                guard seenPaths.insert(standardizedURL.path).inserted,
                      let bundle = Bundle(url: standardizedURL),
                      let bundleIdentifier = bundle.bundleIdentifier else { continue }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? standardizedURL.deletingPathExtension().lastPathComponent
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                applications.append(.init(name: name, bundleIdentifier: bundleIdentifier, applicationURL: standardizedURL))
            }
        }
        return applications.sorted {
            ($0.name, $0.bundleIdentifier, $0.applicationURL.path)
                < ($1.name, $1.bundleIdentifier, $1.applicationURL.path)
        }
    }

    public static func validatesLaunchTarget(
        bundleIdentifier: String,
        applicationURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let standardizedURL = applicationURL.standardizedFileURL.resolvingSymlinksInPath()
        guard standardizedURL.pathExtension.lowercased() == "app",
              (try? standardizedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              fileManager.fileExists(atPath: standardizedURL.path) else { return false }

        let contentsInfo = standardizedURL.appendingPathComponent("Contents/Info.plist")
        let wrappedInfos = wrappedApplicationURLs(in: standardizedURL, fileManager: fileManager)
            .map { $0.appendingPathComponent("Info.plist") }

        return ([contentsInfo] + wrappedInfos).contains { infoURL in
            guard let data = try? Data(contentsOf: infoURL),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let currentBundleIdentifier = info["CFBundleIdentifier"] as? String else { return false }
            return currentBundleIdentifier == bundleIdentifier
        }
    }

    public static func matchesRunningApplication(
        bundleURL: URL?,
        plannedApplicationURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let bundleURL else { return false }
        let runningURL = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let plannedURL = plannedApplicationURL.standardizedFileURL.resolvingSymlinksInPath()
        return runningURL == plannedURL || wrappedApplicationURLs(in: plannedURL, fileManager: fileManager).contains(runningURL)
    }

    private static func wrappedApplicationURLs(in applicationURL: URL, fileManager: FileManager) -> [URL] {
        let wrapperDirectory = applicationURL.appendingPathComponent("Wrapper", isDirectory: true)
        return (try? fileManager.contentsOfDirectory(
            at: wrapperDirectory,
            includingPropertiesForKeys: nil
        ))?
            .filter { $0.pathExtension.lowercased() == "app" }
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() } ?? []
    }
}

public enum DesktopApplicationResolution: Equatable, Sendable {
    case resolved(InstalledDesktopApplication)
    case ambiguous([InstalledDesktopApplication])
    case notFound
}

public enum DesktopApplicationResolver {
    public static func resolve(
        _ requestedName: String,
        in applications: [InstalledDesktopApplication]
    ) -> DesktopApplicationResolution {
        let requested = normalizedName(requestedName)
        guard !requested.isEmpty else { return .notFound }
        let requestsFilename = requestedApplicationFilename(requestedName)
        let matches = applications
            .filter { application in
                let filename = normalizedName(application.applicationURL.deletingPathExtension().lastPathComponent)
                if requestsFilename { return filename == requested }
                return normalizedName(application.name) == requested || filename == requested
            }
            .sorted {
                ($0.bundleIdentifier, $0.applicationURL.path)
                < ($1.bundleIdentifier, $1.applicationURL.path)
            }
        guard !matches.isEmpty else { return .notFound }
        return Set(matches.map(\.bundleIdentifier)).count == 1 ? .resolved(matches[0]) : .ambiguous(matches)
    }

    private static func normalizedName(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = trimmed.unicodeScalars.last,
              CharacterSet.punctuationCharacters.contains(last) {
            trimmed.unicodeScalars.removeLast()
        }
        if trimmed.lowercased().hasSuffix(".app") {
            trimmed.removeLast(4)
        }
        return trimmed
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func requestedApplicationFilename(_ value: String) -> Bool {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = trimmed.unicodeScalars.last,
              CharacterSet.punctuationCharacters.contains(last),
              !trimmed.lowercased().hasSuffix(".app") {
            trimmed.unicodeScalars.removeLast()
        }
        return trimmed.lowercased().hasSuffix(".app")
    }
}

public enum DesktopAction: Codable, Equatable, Sendable {
    case type(text: String, expectedFingerprint: String)
    case open(url: URL)
    case activate(bundleIdentifier: String)
    case activateApplication(bundleIdentifier: String, applicationURL: URL)
    case quit(bundleIdentifier: String)
    case scroll(lines: Int, expectedFingerprint: String)
    case press(elementID: String, expectedFingerprint: String)
    case key(DesktopKey, expectedFingerprint: String)

    public var isDestructive: Bool {
        switch self {
        case .quit:
            return true
        case .press, .key:
            // AX locators are opaque, and keyboard events may commit or dismiss state. Review both.
            return true
        default:
            return false
        }
    }
}

public struct ControlPlanStep: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let action: DesktopAction
    public let confidence: Double
    public let reason: String
    /// AX title captured with a press action. Never recover this from its opaque element ID.
    public let candidateTitle: String?
    public let requiresConfirmation: Bool

    public init(
        id: UUID = UUID(), action: DesktopAction, confidence: Double, reason: String,
        candidateTitle: String? = nil,
        requiresConfirmation: Bool = false
    ) {
        self.id = id
        self.action = action
        self.confidence = confidence
        self.reason = reason
        self.candidateTitle = candidateTitle
        self.requiresConfirmation = requiresConfirmation
    }
}

public struct ControlAuditEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let action: DesktopAction
    public let beforeFingerprint: String
    public let afterFingerprint: String?
    public let effect: ControlEffect
    /// Human-readable description of `effect`. Never parse it; branch on `effect`.
    public let result: String

    public init(
        id: UUID = UUID(), timestamp: Date = .now, action: DesktopAction,
        beforeFingerprint: String, afterFingerprint: String?, effect: ControlEffect, result: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.action = action
        self.beforeFingerprint = beforeFingerprint
        self.afterFingerprint = afterFingerprint
        self.effect = effect
        self.result = result
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        action = try container.decode(DesktopAction.self, forKey: .action)
        beforeFingerprint = try container.decode(String.self, forKey: .beforeFingerprint)
        afterFingerprint = try container.decodeIfPresent(String.self, forKey: .afterFingerprint)
        // Entries written before typed effects carry only prose; do not infer from it.
        effect = try container.decodeIfPresent(ControlEffect.self, forKey: .effect) ?? .unknown
        result = try container.decode(String.self, forKey: .result)
    }
}

public enum ControlEffect: String, Codable, Equatable, Sendable {
    case observed
    case notObserved
    case unknown
}

public enum ControlPolicy {
    public static let minimumConfidence = 0.60
    private static let destructiveWords = [
        "quit", "close", "delete", "remove", "trash", "empty", "discard", "clear", "erase",
        "archive", "uninstall", "revoke", "deactivate", "cancel", "reset",
        "send", "resend", "reply", "forward", "submit", "post", "share", "publish",
        "pay", "purchase", "order", "transfer", "book", "confirm", "approve"
    ]
    private static let destructiveStems = [
        "delet", "remov", "clos", "clear", "empt", "eras", "archiv", "uninstall", "revok",
        "deactivat", "cancel", "reset", "send", "resend", "repl", "forward", "submi", "post",
        "shar", "publish", "pay", "purchas", "order", "transfer", "book", "confirm", "approv", "unsend"
    ]
    private static let destructiveSuffixes: Set<String> = ["", "s", "es", "d", "ed", "ing", "ion", "ation", "al", "ment", "led", "ted", "red", "ied", "ies", "ting", "tted"]
    private static let destructiveIrregularForms: Set<String> = ["sent"]

    public static func canAutoRun(_ step: ControlPlanStep) -> Bool {
        step.confidence >= minimumConfidence && !requiresConfirmation(step)
    }

    /// Text and UI interactions must not be sent to a background app.
    public static func requiresActiveTarget(for action: DesktopAction) -> Bool {
        switch action {
        case .type, .scroll, .press, .key:
            true
        case .open, .activate, .activateApplication, .quit:
            false
        }
    }

    public static func requiresConfirmation(_ step: ControlPlanStep) -> Bool {
        if case .press = step.action {
            guard let candidateTitle = step.candidateTitle else { return true }
            return step.requiresConfirmation || isDestructiveControlTitle(candidateTitle)
        }
        return step.requiresConfirmation || step.action.isDestructive
    }

    public static func isDestructiveControlTitle(_ title: String) -> Bool {
        let separated = title.replacingOccurrences(
            of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression
        )
        let words = separated
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased() }
        return words.contains { word in
            destructiveWords.contains(word) || destructiveIrregularForms.contains(word)
                || destructiveStems.contains { stem in
                    guard word.hasPrefix(stem) else { return false }
                    return destructiveSuffixes.contains(String(word.dropFirst(stem.count)))
                }
        }
    }
}

public enum ControlOutcome {
    public static func effect(
        for action: DesktopAction,
        before: DesktopSnapshot,
        after: DesktopSnapshot?,
        externalEffect: ControlEffect = .unknown
    ) -> ControlEffect {
        switch action {
        case .type:
            guard let after else { return .unknown }
            return after.focusedValue != before.focusedValue ? .observed : .notObserved
        case .press, .scroll:
            guard let after else { return .unknown }
            return after.fingerprint != before.fingerprint ? .observed : .notObserved
        case .key:
            // Caret moves are not represented in DesktopSnapshot. Do not mistake them for failed actions.
            return .unknown
        case .open, .activate, .activateApplication, .quit:
            return externalEffect
        }
    }

    public static func result(for action: DesktopAction, effect: ControlEffect) -> String {
        guard effect != .unknown else { return "unknown effect" }
        let observed = effect == .observed
        switch action {
        case .type:
            return observed ? "observed text change" : "no observed text change"
        case .press, .scroll:
            return observed ? "observed interface change" : "no observed interface change"
        case .key:
            return "keyboard event sent, effect not attributable"
        case .open:
            return observed ? "observed navigation" : "no observed navigation"
        case .activate, .activateApplication:
            return observed ? "observed target active" : "no observed target active"
        case .quit:
            return observed ? "observed process termination" : "no observed process termination"
        }
    }
}

/// What an `open` action can honestly claim from before/after document URLs.
public enum OpenNavigationOutcome: Equatable, Sendable {
    /// Handler app shows the target URL, and did not before the action.
    case navigated
    /// Target URL was already showing, so a new navigation cannot be attributed.
    case alreadyOpen
    /// Target app was already frontmost, but Accessibility exposed no current URL.
    case targetAlreadyActive
    /// Handler app moved to a different URL: a redirect, or something else.
    case differentURL(URL)
    case notObserved

    public var effect: ControlEffect {
        switch self {
        case .navigated: .observed
        case .alreadyOpen, .targetAlreadyActive, .differentURL: .unknown
        case .notObserved: .notObserved
        }
    }

    public var result: String {
        switch self {
        case .navigated: "observed navigation"
        case .alreadyOpen: "target already open, navigation not attributable"
        case .targetAlreadyActive: "target app already active, navigation not attributable"
        case let .differentURL(url): "handler shows \(url.absoluteString), navigation not attributable, possible redirect"
        case .notObserved: "no observed navigation"
        }
    }
}

public enum ControlExternalEffect {
    public static func isTargetActive(
        observedProcessIdentifier: Int32,
        targetProcessIdentifier: Int32
    ) -> Bool {
        observedProcessIdentifier == targetProcessIdentifier
    }

    public static func isProcessTerminated(
        targetProcessIdentifier: Int32,
        runningProcessIdentifiers: some Sequence<Int32>
    ) -> Bool {
        !runningProcessIdentifiers.contains(targetProcessIdentifier)
    }

    public static func openNavigation(
        targetBundleIdentifier: String,
        targetURL: URL,
        targetWasFrontmost: Bool,
        beforeURL: URL?,
        observedBundleIdentifier: String?,
        observedURL: URL?
    ) -> OpenNavigationOutcome {
        guard targetBundleIdentifier == observedBundleIdentifier, let observedURL else { return .notObserved }
        if targetWasFrontmost, beforeURL == nil { return .targetAlreadyActive }
        if let beforeURL, sameDocument(beforeURL, targetURL) { return .alreadyOpen }
        if sameDocument(observedURL, targetURL) { return .navigated }
        if let beforeURL, sameDocument(observedURL, beforeURL) { return .notObserved }
        return .differentURL(observedURL)
    }

    static func sameDocument(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let target = URLComponents(url: lhs, resolvingAgainstBaseURL: false),
              let observed = URLComponents(url: rhs, resolvingAgainstBaseURL: false) else { return false }
        return target.scheme?.lowercased() == observed.scheme?.lowercased()
            && target.host?.lowercased() == observed.host?.lowercased()
            && normalizedPath(target) == normalizedPath(observed)
            && target.port == observed.port
            && target.percentEncodedQuery == observed.percentEncodedQuery
            && target.fragment == observed.fragment
    }

    private static func normalizedPath(_ components: URLComponents) -> String {
        components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
    }
}

public struct ControlObservationResult<Snapshot: Sendable>: Sendable {
    public let snapshot: Snapshot?
    public let effectObserved: Bool
    public let attempts: Int

    public init(snapshot: Snapshot?, effectObserved: Bool, attempts: Int) {
        self.snapshot = snapshot
        self.effectObserved = effectObserved
        self.attempts = attempts
    }
}

public enum ControlObservation {
    public static func observe<Snapshot: Sendable>(
        maximumAttempts: Int = 8,
        interval: Duration = .milliseconds(125),
        capture: () async -> Snapshot?,
        hasObservedEffect: (Snapshot) -> Bool
    ) async throws -> ControlObservationResult<Snapshot> {
        let attempts = max(1, maximumAttempts)
        var latest: Snapshot?

        for attempt in 1 ... attempts {
            try Task.checkCancellation()
            if let snapshot = await capture() {
                latest = snapshot
                if hasObservedEffect(snapshot) {
                    return .init(snapshot: snapshot, effectObserved: true, attempts: attempt)
                }
            }
            if attempt < attempts, (interval > .zero) {
                try await Task.sleep(for: interval)
            }
        }
        return .init(snapshot: latest, effectObserved: false, attempts: attempts)
    }
}

public enum ControlPlanner {
    public static func commands(
        from command: String,
        maximumSteps: Int = ControlSessionLimits().maxActions
    ) throws -> [String] {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SaysoError.invalidAction("Say a control command.") }
        if trimmed.lowercased().hasPrefix("type ") { return [trimmed] }
        let normalized = trimmed.lowercased()
        guard !normalized.hasPrefix("then "), !normalized.hasSuffix(" then") else {
            throw SaysoError.invalidAction("Separate control steps with a command on both sides of 'then'.")
        }
        var commands: [String] = []
        var remaining = trimmed[...]
        while let separator = remaining.range(of: " then ", options: .caseInsensitive) {
            let current = remaining[..<separator.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !current.isEmpty else {
                throw SaysoError.invalidAction("Separate control steps with a command on both sides of 'then'.")
            }
            commands.append(current)
            remaining = remaining[separator.upperBound...]
            if remaining.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("type ") {
                break
            }
        }
        let tail = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else {
            throw SaysoError.invalidAction("Separate control steps with a command on both sides of 'then'.")
        }
        commands.append(tail)
        guard commands.allSatisfy({ !$0.isEmpty }) else {
            throw SaysoError.invalidAction("Separate control steps with a command on both sides of 'then'.")
        }
        guard commands.count <= max(1, maximumSteps) else {
            throw SaysoError.invalidAction("Control supports at most \(max(1, maximumSteps)) steps per command.")
        }
        return commands
    }

    public static func plan(
        command: String,
        snapshot: DesktopSnapshot,
        installedApplications: [InstalledDesktopApplication]? = nil
    ) throws -> ControlPlanStep {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        if normalized == "scroll down" || normalized == "scroll down a bit" {
            return .init(action: .scroll(lines: -6, expectedFingerprint: snapshot.fingerprint), confidence: 0.90, reason: "Exact scroll command")
        }
        if normalized == "scroll up" || normalized == "scroll up a bit" {
            return .init(action: .scroll(lines: 6, expectedFingerprint: snapshot.fingerprint), confidence: 0.90, reason: "Exact scroll command")
        }
        if normalized == "go back" {
            return .init(
                action: .key(.goBack, expectedFingerprint: snapshot.fingerprint),
                confidence: 0.85,
                reason: "Go back",
                requiresConfirmation: true
            )
        }
        if normalized == "next tab" {
            return .init(
                action: .key(.nextTab, expectedFingerprint: snapshot.fingerprint),
                confidence: 0.85,
                reason: "Next tab",
                requiresConfirmation: true
            )
        }
        if normalized == "previous tab" {
            return .init(
                action: .key(.previousTab, expectedFingerprint: snapshot.fingerprint),
                confidence: 0.85,
                reason: "Previous tab",
                requiresConfirmation: true
            )
        }
        if normalized.hasPrefix("type ") {
            let text = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { throw SaysoError.invalidAction("Say what to type after 'type'.") }
            return .init(action: .type(text: text, expectedFingerprint: snapshot.fingerprint), confidence: 0.90, reason: "Exact type command")
        }
        if normalized.hasPrefix("press ") {
            let keyName = String(trimmed.dropFirst(6))
            guard let key = DesktopKey.parse(keyName) else {
                throw SaysoError.invalidAction("Press supports: tab, arrows, return, or escape.")
            }
            return .init(
                action: .key(key, expectedFingerprint: snapshot.fingerprint),
                confidence: 0.85,
                reason: "Press \(key.rawValue)",
                requiresConfirmation: true
            )
        }
        if normalized.hasPrefix("open ") {
            let target = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else {
                throw SaysoError.invalidAction("Say an http address or exact installed application name after 'open'.")
            }
            if let url = httpURL(target) {
                return .init(action: .open(url: url), confidence: 0.80, reason: "Explicit web address")
            }
            let applications = installedApplications ?? InstalledDesktopApplication.available()
            if case .notFound = DesktopApplicationResolver.resolve(target, in: applications), looksLikeUnsupportedWebAddress(target) {
                throw SaysoError.invalidAction("Open web addresses must include http:// or https://.")
            }
            return try namedApplicationPlan(
                requestedName: target,
                applications: applications
            )
        }
        if normalized.hasPrefix("switch to ") {
            let target = String(trimmed.dropFirst(10)).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else {
                throw SaysoError.invalidAction("Say an exact installed application name after 'switch to'.")
            }
            return try namedApplicationPlan(
                requestedName: target,
                applications: installedApplications ?? InstalledDesktopApplication.available()
            )
        }
        if normalized.hasPrefix("click ") {
            let title = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            let matches = snapshot.elements.filter { $0.title.compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            guard matches.count == 1, let element = matches.first else {
                throw SaysoError.invalidAction("Click commands need one visible control with an exact title.")
            }
            return .init(
                action: .press(elementID: element.id, expectedFingerprint: snapshot.fingerprint),
                confidence: 0.85,
                reason: "Exact visible control",
                candidateTitle: element.title
            )
        }
        if normalized.hasPrefix("activate "), let identifier = bundleIdentifier(from: trimmed, prefix: 9) {
            return .init(action: .activate(bundleIdentifier: identifier), confidence: 0.80, reason: "Exact bundle identifier")
        }
        if normalized.hasPrefix("quit "), let identifier = bundleIdentifier(from: trimmed, prefix: 5) {
            return .init(action: .quit(bundleIdentifier: identifier), confidence: 0.70, reason: "Exact bundle identifier")
        }
        throw SaysoError.invalidAction("Control supports: type, press key, go back, next or previous tab, click exact title, scroll, open an https URL or installed app, switch to an installed app, activate bundle ID, or quit bundle ID.")
    }

    public static func requiresInstalledApplicationCatalog(for command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        if normalized.hasPrefix("open ") {
            let target = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            return !target.isEmpty && httpURL(target) == nil && !target.contains("://")
        }
        if normalized.hasPrefix("switch to ") {
            return !String(trimmed.dropFirst(10)).trimmingCharacters(in: .whitespaces).isEmpty
        }
        return false
    }

    private static func namedApplicationPlan(
        requestedName: String,
        applications: [InstalledDesktopApplication]
    ) throws -> ControlPlanStep {
        switch DesktopApplicationResolver.resolve(requestedName, in: applications) {
        case let .resolved(application):
            return .init(
                action: .activateApplication(
                    bundleIdentifier: application.bundleIdentifier,
                    applicationURL: application.applicationURL
                ),
                confidence: 0.85,
                reason: "Launch \(application.name) at \(application.applicationURL.path)",
                requiresConfirmation: true
            )
        case .notFound:
            throw SaysoError.invalidAction("No installed application exactly named '\(requestedName)'.")
        case let .ambiguous(applications):
            let filenames = Set(applications.map { $0.applicationURL.lastPathComponent })
                .sorted()
                .joined(separator: " or ")
            throw SaysoError.invalidAction("More than one installed application is named '\(requestedName)'. Say an exact unique .app filename: \(filenames), or remove a duplicate.")
        }
    }

    private static func httpURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else { return nil }
        return url
    }

    private static func looksLikeUnsupportedWebAddress(_ value: String) -> Bool {
        if URL(string: value)?.scheme != nil { return true }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.contains(where: \.isWhitespace)
            && trimmed.contains(".")
            && !trimmed.lowercased().hasSuffix(".app")
    }

    private static func bundleIdentifier(from command: String, prefix: Int) -> String? {
        let identifier = String(command.dropFirst(prefix)).trimmingCharacters(in: .whitespaces)
        guard identifier.split(separator: ".").count >= 2,
              identifier.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        return identifier
    }
}

public actor ControlAuditStore {
    private let fileURL: URL

    public init(fileManager: FileManager = .default) {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SaysoNotch", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        fileURL = root.appendingPathComponent("control-audit.json")
    }

    public func entries() -> [ControlAuditEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([ControlAuditEntry].self, from: data)) ?? []
    }

    public func append(_ entry: ControlAuditEntry) {
        var values = entries()
        values.insert(entry, at: 0)
        if values.count > 500 { values.removeLast(values.count - 500) }
        guard let data = try? JSONEncoder().encode(values) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

public final class AXDesktopController: @unchecked Sendable {
    private let candidateCapture = AXCandidateCapture()
    private static let observationAttempts = 8
    private static let observationInterval = Duration.milliseconds(125)

    public init() {}

    public func capture(application targetApplication: NSRunningApplication? = nil) throws -> DesktopSnapshot {
        guard AXIsProcessTrusted() else { throw SaysoError.permissionDenied("Accessibility") }
        guard let app = targetApplication ?? NSWorkspace.shared.frontmostApplication else {
            throw SaysoError.unavailable("Frontmost application")
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let focused = copyElement(kAXFocusedUIElementAttribute as CFString, from: application)
        let window = copyElement(kAXFocusedWindowAttribute as CFString, from: application)
        let focusedRole = focused.flatMap { copyAttribute(kAXRoleAttribute as CFString, from: $0) as? String } ?? ""
        let focusedSubrole = focused.flatMap { copyAttribute(kAXSubroleAttribute as CFString, from: $0) as? String } ?? ""
        let isProtected = AXCandidateCapturePolicy.isProtected(role: focusedRole, subrole: focusedSubrole)
        let focusedValue = isProtected ? "" : (focused.flatMap { copyAttribute(kAXValueAttribute as CFString, from: $0) as? String } ?? "")
        let candidateSnapshot = try candidateCapture.capture(application: app)
        return DesktopSnapshot(
            processIdentifier: app.processIdentifier,
            applicationName: app.localizedName ?? "Unknown",
            windowTitle: window.flatMap { copyAttribute(kAXTitleAttribute as CFString, from: $0) as? String } ?? "",
            focusedRole: focusedRole,
            focusedValue: AXCandidateCapturePolicy.focusedValue(
                focusedValue,
                role: focusedRole,
                subrole: focusedSubrole
            ),
            isProtected: isProtected,
            elements: candidateSnapshot.candidates.filter(\.state.isTargetable).map {
                DesktopElement(id: $0.id.rawValue, role: $0.role, title: $0.title)
            }
        )
    }

    public func execute(
        _ step: ControlPlanStep,
        approved: Bool = false,
        targetApplication: NSRunningApplication? = nil
    ) async throws -> ControlAuditEntry {
        guard step.confidence >= ControlPolicy.minimumConfidence else {
            throw SaysoError.invalidAction("Confidence below Sayso control threshold")
        }
        guard approved || !ControlPolicy.requiresConfirmation(step) else {
            throw SaysoError.invalidAction("Review required before this action can run")
        }
        var before = try capture(application: targetApplication)
        guard !before.isProtected else { throw SaysoError.protectedTarget }
        if ControlPolicy.requiresActiveTarget(for: step.action) {
            try await activateInteractionTarget(
                processIdentifier: before.processIdentifier,
                applicationName: before.applicationName
            )
            before = try capture(application: targetApplication)
            guard !before.isProtected else { throw SaysoError.protectedTarget }
        }
        var targetProcessIdentifier: Int32?
        var openTargetBundleIdentifier: String?
        var openTargetWasFrontmost = false
        var openBeforeURL: URL?

        switch step.action {
        case let .type(text, expectedFingerprint):
            guard before.fingerprint == expectedFingerprint else { throw SaysoError.staleTarget }
            try setFocusedText(text, in: before.processIdentifier)
        case let .open(url):
            guard let targetApplicationURL = NSWorkspace.shared.urlForApplication(toOpen: url),
                  let targetBundleIdentifier = Bundle(url: targetApplicationURL)?.bundleIdentifier else {
                throw SaysoError.unavailable("Application for \(url.host ?? url.absoluteString)")
            }
            if let frontmost = NSWorkspace.shared.frontmostApplication,
               frontmost.bundleIdentifier == targetBundleIdentifier {
                openTargetWasFrontmost = true
                openBeforeURL = documentURL(in: frontmost)
            }
            guard NSWorkspace.shared.open(url) else {
                throw SaysoError.unavailable("Open \(url.host ?? url.absoluteString)")
            }
            openTargetBundleIdentifier = targetBundleIdentifier
        case let .activate(bundleIdentifier):
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
                throw SaysoError.unavailable(bundleIdentifier)
            }
            targetProcessIdentifier = app.processIdentifier
            app.activate()
        case let .activateApplication(bundleIdentifier, applicationURL):
            let standardizedURL = applicationURL.standardizedFileURL.resolvingSymlinksInPath()
            guard InstalledDesktopApplication.validatesLaunchTarget(
                bundleIdentifier: bundleIdentifier,
                applicationURL: standardizedURL
            ) else {
                throw SaysoError.unavailable("Installed application changed")
            }
            let app: NSRunningApplication
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .first(where: {
                    InstalledDesktopApplication.matchesRunningApplication(
                        bundleURL: $0.bundleURL,
                        plannedApplicationURL: standardizedURL
                    )
                }) {
                app = running
            } else {
                app = try await launchApplication(at: standardizedURL)
            }
            targetProcessIdentifier = app.processIdentifier
            _ = app.activate()
        case let .quit(bundleIdentifier):
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
                throw SaysoError.unavailable(bundleIdentifier)
            }
            targetProcessIdentifier = app.processIdentifier
            app.terminate()
        case let .scroll(lines, expectedFingerprint):
            guard before.fingerprint == expectedFingerprint else { throw SaysoError.staleTarget }
            guard NSRunningApplication(processIdentifier: before.processIdentifier) != nil else {
                throw SaysoError.unavailable(before.applicationName)
            }
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(lines), wheel2: 0, wheel3: 0) else {
                throw SaysoError.unavailable("Scroll event")
            }
            event.post(tap: .cghidEventTap)
        case let .press(elementID, expectedFingerprint):
            guard before.fingerprint == expectedFingerprint else { throw SaysoError.staleTarget }
            guard let target = NSRunningApplication(processIdentifier: before.processIdentifier) else {
                throw SaysoError.staleTarget
            }
            try candidateCapture.press(candidateID: .init(rawValue: elementID), application: target)
        case let .key(key, expectedFingerprint):
            guard before.fingerprint == expectedFingerprint else { throw SaysoError.staleTarget }
            guard let target = NSRunningApplication(processIdentifier: before.processIdentifier) else {
                throw SaysoError.staleTarget
            }
            guard
                  let source = CGEventSource(stateID: .combinedSessionState),
                  let keyDown = CGEvent(keyboardEventSource: source, virtualKey: key.virtualKey, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: key.virtualKey, keyDown: false) else {
                throw SaysoError.unavailable("Keyboard event")
            }
            keyDown.flags = key.modifierFlags
            keyUp.flags = key.modifierFlags
            keyDown.postToPid(target.processIdentifier)
            keyUp.postToPid(target.processIdentifier)
        }

        let observation = try await observeEffect(
            for: step.action,
            before: before,
            targetApplication: targetApplication,
            targetProcessIdentifier: targetProcessIdentifier,
            openTargetBundleIdentifier: openTargetBundleIdentifier,
            openTargetWasFrontmost: openTargetWasFrontmost,
            openBeforeURL: openBeforeURL
        )
        return ControlAuditEntry(
            action: step.action,
            beforeFingerprint: before.fingerprint,
            afterFingerprint: observation.snapshot?.fingerprint,
            effect: observation.effect,
            result: observation.result
        )
    }

    public func verify(
        _ snapshot: DesktopSnapshot,
        targetApplication: NSRunningApplication? = nil
    ) throws -> DesktopSnapshot {
        let current = try capture(application: targetApplication)
        guard !current.isProtected else { throw SaysoError.protectedTarget }
        guard current.fingerprint == snapshot.fingerprint else { throw SaysoError.staleTarget }
        return current
    }

    private func setFocusedText(_ text: String, in processIdentifier: Int32) throws {
        let application = AXUIElementCreateApplication(processIdentifier)
        guard let focused = copyElement(kAXFocusedUIElementAttribute as CFString, from: application) else {
            throw SaysoError.unavailable("Focused text field")
        }
        let role = copyAttribute(kAXRoleAttribute as CFString, from: focused) as? String ?? ""
        let subrole = copyAttribute(kAXSubroleAttribute as CFString, from: focused) as? String ?? ""
        guard !AXCandidateCapturePolicy.isProtected(role: role, subrole: subrole) else { throw SaysoError.protectedTarget }
        guard AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success else {
            throw SaysoError.invalidAction("Text field rejected insertion")
        }
    }

    private func activateInteractionTarget(
        processIdentifier: Int32,
        applicationName: String
    ) async throws {
        guard let target = NSRunningApplication(processIdentifier: processIdentifier), !target.isTerminated else {
            throw SaysoError.staleTarget
        }
        guard target.activate() else {
            throw SaysoError.unavailable("Activate \(applicationName)")
        }
        let observation = try await ControlObservation.observe(
            maximumAttempts: Self.observationAttempts,
            interval: Self.observationInterval,
            capture: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            hasObservedEffect: { $0 == processIdentifier }
        )
        guard observation.effectObserved else {
            throw SaysoError.unavailable("Activate \(applicationName)")
        }
    }

    private func launchApplication(at applicationURL: URL) async throws -> NSRunningApplication {
        try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: .init()
            ) { application, error in
                if let application {
                    continuation.resume(returning: application)
                } else {
                    continuation.resume(throwing: error ?? SaysoError.unavailable(applicationURL.lastPathComponent))
                }
            }
        }
    }

    private struct ActionObservation {
        let snapshot: DesktopSnapshot?
        let effect: ControlEffect
        let result: String

        init(snapshot: DesktopSnapshot?, action: DesktopAction, effect: ControlEffect) {
            self.snapshot = snapshot
            self.effect = effect
            result = ControlOutcome.result(for: action, effect: effect)
        }

        init(snapshot: DesktopSnapshot?, open outcome: OpenNavigationOutcome) {
            self.snapshot = snapshot
            effect = outcome.effect
            result = outcome.result
        }
    }

    private struct OpenObservation: Sendable {
        let snapshot: DesktopSnapshot
        let bundleIdentifier: String?
        let documentURL: URL?
    }

    private func observeEffect(
        for action: DesktopAction,
        before: DesktopSnapshot,
        targetApplication: NSRunningApplication?,
        targetProcessIdentifier: Int32?,
        openTargetBundleIdentifier: String?,
        openTargetWasFrontmost: Bool,
        openBeforeURL: URL?
    ) async throws -> ActionObservation {
        switch action {
        case .type, .press, .scroll:
            let observation = try await ControlObservation.observe(
                maximumAttempts: Self.observationAttempts,
                interval: Self.observationInterval,
                capture: { [weak self] () async -> DesktopSnapshot? in
                    guard let self else { return nil }
                    do { return try self.capture(application: targetApplication) }
                    catch { return nil }
                },
                hasObservedEffect: { after in
                    ControlOutcome.effect(for: action, before: before, after: after) == .observed
                }
            )
            return .init(
                snapshot: observation.snapshot,
                action: action,
                effect: ControlOutcome.effect(for: action, before: before, after: observation.snapshot)
            )

        case .key:
            return .init(snapshot: nil, action: action, effect: .unknown)

        case let .open(url):
            // Redirects and already-open targets settle as unknown, never as observed.
            func openOutcome(_ after: OpenObservation?) -> OpenNavigationOutcome {
                guard let openTargetBundleIdentifier, let after else { return .notObserved }
                return ControlExternalEffect.openNavigation(
                    targetBundleIdentifier: openTargetBundleIdentifier,
                    targetURL: url,
                    targetWasFrontmost: openTargetWasFrontmost,
                    beforeURL: openBeforeURL,
                    observedBundleIdentifier: after.bundleIdentifier,
                    observedURL: after.documentURL
                )
            }
            let observation = try await ControlObservation.observe(
                maximumAttempts: Self.observationAttempts,
                interval: Self.observationInterval,
                capture: { [weak self] () async -> OpenObservation? in
                    guard let self,
                          let application = NSWorkspace.shared.frontmostApplication,
                          let snapshot = try? self.capture(application: application) else { return nil }
                    return .init(
                        snapshot: snapshot,
                        bundleIdentifier: application.bundleIdentifier,
                        documentURL: self.documentURL(in: application)
                    )
                },
                hasObservedEffect: { after in
                    let outcome = openOutcome(after)
                    return outcome == .navigated || outcome == .alreadyOpen
                }
            )
            return .init(snapshot: observation.snapshot?.snapshot, open: openOutcome(observation.snapshot))

        case .activate, .activateApplication:
            let observation = try await ControlObservation.observe(
                maximumAttempts: Self.observationAttempts,
                interval: Self.observationInterval,
                capture: { [weak self] () async -> DesktopSnapshot? in
                    guard let self else { return nil }
                    do { return try self.capture() }
                    catch { return nil }
                },
                hasObservedEffect: { after in
                    guard let targetProcessIdentifier else { return false }
                    return ControlExternalEffect.isTargetActive(
                        observedProcessIdentifier: after.processIdentifier,
                        targetProcessIdentifier: targetProcessIdentifier
                    )
                }
            )
            return .init(
                snapshot: observation.snapshot,
                action: action,
                effect: observation.effectObserved ? .observed : .notObserved
            )

        case .quit:
            let observation = try await ControlObservation.observe(
                maximumAttempts: Self.observationAttempts,
                interval: Self.observationInterval,
                capture: {
                    NSWorkspace.shared.runningApplications.map(\.processIdentifier)
                },
                hasObservedEffect: { runningProcessIdentifiers in
                    guard let targetProcessIdentifier else { return false }
                    return ControlExternalEffect.isProcessTerminated(
                        targetProcessIdentifier: targetProcessIdentifier,
                        runningProcessIdentifiers: runningProcessIdentifiers
                    )
                }
            )
            return .init(snapshot: nil, action: action, effect: observation.effectObserved ? .observed : .notObserved)
        }
    }

    private func documentURL(in application: NSRunningApplication) -> URL? {
        let root = AXUIElementCreateApplication(application.processIdentifier)
        let focused = copyElement(kAXFocusedUIElementAttribute as CFString, from: root)
        let window = copyElement(kAXFocusedWindowAttribute as CFString, from: root)
        return focused.flatMap(documentURL)
            ?? window.flatMap(documentURL)
            ?? window.flatMap(firstDocumentURL)
    }

    private func firstDocumentURL(in root: AXUIElement) -> URL? {
        var pending = [root]
        var visited = 0
        while let element = pending.popLast(), visited < 300 {
            visited += 1
            if let url = documentURL(from: element) { return url }
            let children = copyAttribute(kAXChildrenAttribute as CFString, from: element) as? [AXUIElement] ?? []
            pending.append(contentsOf: children.reversed())
        }
        return nil
    }

    private func documentURL(from element: AXUIElement) -> URL? {
        guard (copyAttribute(kAXRoleAttribute as CFString, from: element) as? String) == "AXWebArea" else { return nil }
        return urlAttribute(from: element)
    }

    private func urlAttribute(from element: AXUIElement) -> URL? {
        guard let value = copyAttribute(kAXURLAttribute as CFString, from: element) else { return nil }
        return value as? URL ?? (value as? String).flatMap(URL.init(string:))
    }

    private func copyAttribute(_ attribute: CFString, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value
    }

    private func copyElement(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        guard let value = copyAttribute(attribute, from: element) else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
}
