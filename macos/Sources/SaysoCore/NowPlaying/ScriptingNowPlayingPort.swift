import AppKit

/// Reads and drives Music and Spotify through AppleScript, and only a player that is already running: the running
/// applications list is checked first, and every script checks `is running` again before it addresses the player,
/// so a player that quits in between is not relaunched. The first script sent to each player makes macOS ask the
/// user for Automation permission. MediaRemote is not used: it is private and restricted on recent macOS.
///
/// NSAppleScript is not thread safe; call from the main thread, which is where the app's scheduler and UI run.
public struct ScriptingNowPlayingPort: NowPlayingPort, @unchecked Sendable {
    public struct ScriptError: Error, Equatable, Sendable {
        public let code: Int
        public init(code: Int) { self.code = code }
    }

    /// Bounds how long a hung player can hold the calling thread.
    static let timeoutSeconds = 2
    private static let notPermitted: Set<Int> = [-1743, -1744]
    /// The player quit or has no current track: nothing to show, not a failure.
    private static let gone: Set<Int> = [-600, -609, -1728]

    private let isRunning: @Sendable (NowPlayingApp) -> Bool
    private let run: @Sendable (String) -> Result<NSAppleEventDescriptor, ScriptError>

    init(
        isRunning: @escaping @Sendable (NowPlayingApp) -> Bool,
        run: @escaping @Sendable (String) -> Result<NSAppleEventDescriptor, ScriptError>
    ) {
        self.isRunning = isRunning
        self.run = run
    }

    public init() {
        self.init(
            isRunning: { app in NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == app.bundleID } },
            run: Self.execute
        )
    }

    public func current() throws(NowPlayingPortError) -> NowPlayingSnapshot? {
        var paused: NowPlayingSnapshot?
        var refusal: NowPlayingPortError?
        for app in NowPlayingApp.allCases where isRunning(app) {
            switch run(Self.readScript(app)) {
            case let .success(answer):
                guard let snapshot = Self.snapshot(from: answer, app: app) else { continue }
                if snapshot.isPlaying { return snapshot }
                paused = paused ?? snapshot
            case let .failure(error):
                guard !Self.gone.contains(error.code) else { continue }
                refusal = refusal ?? Self.portError(error)
            }
        }
        if let paused { return paused }
        if let refusal { throw refusal }
        return nil
    }

    public func send(_ command: NowPlayingCommand, to app: NowPlayingApp) throws(NowPlayingPortError) {
        guard isRunning(app) else { throw .unavailable }
        if case let .failure(error) = run(Self.commandScript(command, app)) { throw Self.portError(error) }
    }

    private static func portError(_ error: ScriptError) -> NowPlayingPortError {
        notPermitted.contains(error.code) ? .automationDenied : .unavailable
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
    /// to answer in milliseconds, which is what this reads; not checked against a live Spotify. Both report the
    /// position in seconds.
    static func snapshot(from answer: NSAppleEventDescriptor, app: NowPlayingApp) -> NowPlayingSnapshot? {
        guard answer.descriptorType == typeAEList, answer.numberOfItems == 5,
              let state = answer.atIndex(1)?.stringValue,
              let position = answer.atIndex(4)?.doubleValue,
              let length = answer.atIndex(5)?.doubleValue
        else { return nil }
        return NowPlayingSnapshot(
            app: app,
            title: answer.atIndex(2)?.stringValue ?? "",
            artist: answer.atIndex(3)?.stringValue ?? "",
            isPlaying: state == "playing",
            elapsed: position,
            duration: app == .spotify ? length / 1000 : length
        )
    }

    private static func execute(_ source: String) -> Result<NSAppleEventDescriptor, ScriptError> {
        guard let script = NSAppleScript(source: source) else { return .failure(ScriptError(code: 0)) }
        var info: NSDictionary?
        let answer = script.executeAndReturnError(&info)
        if let info { return .failure(ScriptError(code: (info[NSAppleScript.errorNumber] as? Int) ?? 0)) }
        return .success(answer)
    }
}
