import AppKit

/// Reads and drives Music and Spotify through AppleScript, and only a player that is already running: the running
/// applications list is checked first, and every script checks `is running` again before it addresses the player,
/// so a player that quits in between is not relaunched. Before the first script to each player, macOS is asked for
/// Automation permission, which shows the system prompt once. MediaRemote is not used: it is private and restricted
/// on recent macOS.
///
/// Calls block: the permission check waits for the user's answer, and each Apple event in a script may wait up to
/// `timeoutSeconds`. Call only from one serial background queue, never the main thread; AppleScript is safe off the
/// main thread as long as no two threads use it at once.
public struct ScriptingNowPlayingPort: NowPlayingPort, @unchecked Sendable {
    public struct ScriptError: Error, Equatable, Sendable {
        public let code: Int
        public init(code: Int) { self.code = code }
    }

    /// Per Apple event, not per script: a read sends about six events to each player.
    static let timeoutSeconds = 2
    private static let notPermitted: Set<Int> = [-1743, -1744]
    /// The player quit or has no current track.
    private static let gone: Set<Int> = [-600, -609, -1728]

    private let isRunning: @Sendable (NowPlayingApp) -> Bool
    private let askPermission: @Sendable (NowPlayingApp) -> OSStatus
    private let run: @Sendable (String) -> Result<NSAppleEventDescriptor, ScriptError>
    private let granted = Granted()

    init(
        isRunning: @escaping @Sendable (NowPlayingApp) -> Bool,
        askPermission: @escaping @Sendable (NowPlayingApp) -> OSStatus,
        run: @escaping @Sendable (String) -> Result<NSAppleEventDescriptor, ScriptError>
    ) {
        self.isRunning = isRunning
        self.askPermission = askPermission
        self.run = run
    }

    public init() {
        let scripts = CompiledScripts()
        self.init(
            isRunning: { !Self.running($0).isEmpty },
            askPermission: Self.askAutomation,
            run: { scripts.run($0) }
        )
    }

    public func current(preferring: NowPlayingApp?) throws(NowPlayingPortError) -> NowPlayingSnapshot? {
        var paused: [NowPlayingSnapshot] = []
        var refusal: NowPlayingPortError?
        for app in NowPlayingApp.allCases where isRunning(app) {
            do throws(NowPlayingPortError) {
                guard let snapshot = try read(app) else { continue }
                if snapshot.isPlaying { return snapshot }
                paused.append(snapshot)
            } catch {
                refusal = refusal ?? error
            }
        }
        if let first = paused.first { return paused.first { $0.app == preferring } ?? first }
        if let refusal { throw refusal }
        return nil
    }

    public func send(_ command: NowPlayingCommand, to app: NowPlayingApp) throws(NowPlayingPortError) {
        guard isRunning(app) else { throw .playerGone }
        if case let .failure(error) = run(Self.commandScript(command, app)) { throw Self.portError(error) }
    }

    /// Nil when the player has no track or quit meanwhile.
    private func read(_ app: NowPlayingApp) throws(NowPlayingPortError) -> NowPlayingSnapshot? {
        if !granted.contains(app) {
            switch askPermission(app) {
            case 0: granted.insert(app)
            case -600: return nil
            case let status where Self.notPermitted.contains(Int(status)): throw .automationDenied
            default: throw .unavailable
            }
        }
        switch run(Self.readScript(app)) {
        case let .success(answer): return Self.snapshot(from: answer, app: app)
        case let .failure(error) where Self.gone.contains(error.code): return nil
        case let .failure(error): throw Self.portError(error)
        }
    }

    private static func portError(_ error: ScriptError) -> NowPlayingPortError {
        if notPermitted.contains(error.code) { return .automationDenied }
        return gone.contains(error.code) ? .playerGone : .unavailable
    }

    /// `{state, name, artist, position, duration}`, or `{}` when the player is stopped.
    static func readScript(_ app: NowPlayingApp) -> String {
        guarded(app, """
                set playerState to player state as text
                if playerState is not "playing" and playerState is not "paused" then return {}
                set t to current track
                return {playerState, name of t, artist of t, player position, duration of t}
        """) + "\nreturn {}"
    }

    static func commandScript(_ command: NowPlayingCommand, _ app: NowPlayingApp) -> String {
        let verb = switch command {
        case .playPause: "playpause"
        case .next: "next track"
        case .previous: "previous track"
        }
        return guarded(app, "        \(verb)")
    }

    private static func guarded(_ app: NowPlayingApp, _ body: String) -> String {
        """
        if application id "\(app.bundleID)" is running then
            tell application id "\(app.bundleID)"
                with timeout of \(timeoutSeconds) seconds
        \(body)
                end timeout
            end tell
        end if
        """
    }

    /// Music reports a track's length in seconds. Spotify's dictionary also says seconds, but Spotify is widely reported
    /// to answer in milliseconds, which is what this reads unless the value is too short to be milliseconds (it would
    /// end before the position); not checked against a live Spotify. Both report the position in seconds.
    static func snapshot(from answer: NSAppleEventDescriptor, app: NowPlayingApp) -> NowPlayingSnapshot? {
        guard answer.descriptorType == typeAEList, answer.numberOfItems == 5,
              let state = answer.atIndex(1)?.stringValue,
              let position = answer.atIndex(4)?.doubleValue,
              let length = answer.atIndex(5)?.doubleValue
        else { return nil }
        let seconds = app == .spotify && length / 1000 >= position ? length / 1000 : length
        return NowPlayingSnapshot(
            app: app,
            title: answer.atIndex(2)?.stringValue ?? "",
            artist: answer.atIndex(3)?.stringValue ?? "",
            isPlaying: state == "playing",
            elapsed: position,
            duration: seconds
        )
    }

    private static func running(_ app: NowPlayingApp) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
    }

    /// Asks macOS whether Sayso may send Apple events to the running player, showing the prompt the first time;
    /// blocks until the user answers. Targets the process, so it never launches the player.
    private static func askAutomation(_ app: NowPlayingApp) -> OSStatus {
        guard let pid = running(app).first?.processIdentifier else { return OSStatus(procNotFound) }
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true)
    }
}

/// Players the user has allowed; a refusal is asked about again on the next read, since the user may have
/// changed it in System Settings.
private final class Granted: @unchecked Sendable {
    private let lock = NSLock()
    private var apps: Set<NowPlayingApp> = []

    func contains(_ app: NowPlayingApp) -> Bool { lock.withLock { apps.contains(app) } }
    func insert(_ app: NowPlayingApp) { lock.withLock { _ = apps.insert(app) } }
}

/// Compiles each script once and reuses it, so the player's scripting dictionary is not reloaded on every check.
private final class CompiledScripts: @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [String: NSAppleScript] = [:]

    func run(_ source: String) -> Result<NSAppleEventDescriptor, ScriptingNowPlayingPort.ScriptError> {
        lock.lock()
        defer { lock.unlock() }
        guard let script = scripts[source] ?? NSAppleScript(source: source) else {
            return .failure(.init(code: 0))
        }
        scripts[source] = script
        var info: NSDictionary?
        let answer = script.executeAndReturnError(&info)
        if let info { return .failure(.init(code: (info[NSAppleScript.errorNumber] as? Int) ?? 0)) }
        return .success(answer)
    }
}
