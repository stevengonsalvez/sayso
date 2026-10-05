import Foundation
import Testing
@testable import SaysoCore

/// Records every script the port would run and answers with canned AppleScript results, so no real player is
/// asked, launched or prompted for.
private final class FakeScripts: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [String] = []
    private var answers: [NowPlayingApp: Result<NSAppleEventDescriptor, ScriptingNowPlayingPort.ScriptError>] = [:]
    private var asked: [NowPlayingApp] = []
    var running: Set<NowPlayingApp> = []
    /// What macOS answers when asked for Automation of each player; granted unless set.
    var permission: [NowPlayingApp: OSStatus] = [:]

    var permissionRequests: [NowPlayingApp] { lock.withLock { asked } }

    var ran: [String] { lock.withLock { sources } }

    func answer(_ app: NowPlayingApp, _ result: Result<NSAppleEventDescriptor, ScriptingNowPlayingPort.ScriptError>) {
        lock.withLock { answers[app] = result }
    }

    func run(_ source: String) -> Result<NSAppleEventDescriptor, ScriptingNowPlayingPort.ScriptError> {
        lock.withLock {
            sources.append(source)
            let app = NowPlayingApp.allCases.first { source.contains($0.bundleID) }
            return app.flatMap { answers[$0] } ?? .success(.list())
        }
    }

    func askPermission(_ app: NowPlayingApp) -> OSStatus {
        lock.withLock {
            asked.append(app)
            return permission[app] ?? 0
        }
    }

    /// One port per fake, so what it remembers between calls is exercised.
    private(set) lazy var port = ScriptingNowPlayingPort(
        isRunning: { [self] in running.contains($0) },
        askPermission: { [self] in askPermission($0) },
        run: { [self] in run($0) }
    )
}

private func track(_ state: String, _ title: String, _ artist: String, position: Double, duration: Double) -> NSAppleEventDescriptor {
    let list = NSAppleEventDescriptor.list()
    for (index, item) in [
        NSAppleEventDescriptor(string: state), NSAppleEventDescriptor(string: title), NSAppleEventDescriptor(string: artist),
        NSAppleEventDescriptor(double: position), NSAppleEventDescriptor(double: duration),
    ].enumerated() {
        list.insert(item, at: index + 1)
    }
    return list
}

@Suite struct ScriptingNowPlayingPortTests {
    @Test func withNoPlayerRunningNothingIsAskedAndNoCommandIsSent() throws {
        let scripts = FakeScripts()
        #expect(try scripts.port.current() == nil)
        #expect(throws: NowPlayingPortError.playerGone) { try scripts.port.send(.playPause, to: .music) }
        #expect(scripts.ran.isEmpty, "a player that is not running is never addressed, so it is never launched")
        #expect(scripts.permissionRequests.isEmpty)
    }

    @Test func onlyARunningPlayerIsAskedAndTheScriptItselfRefusesToLaunchIt() throws {
        let scripts = FakeScripts()
        scripts.running = [.spotify]
        scripts.answer(.spotify, .success(track("playing", "Song", "Artist", position: 61.5, duration: 240_000)))

        let snapshot = try #require(try scripts.port.current())
        #expect(snapshot == NowPlayingSnapshot(app: .spotify, title: "Song", artist: "Artist", isPlaying: true, elapsed: 61.5, duration: 240))
        #expect(scripts.ran.count == 1)
        let source = try #require(scripts.ran.first)
        #expect(source.contains("if application id \"com.spotify.client\" is running then"))
        #expect(!source.contains("com.apple.Music"))
        #expect(source.contains("with timeout of"))
    }

    @Test func musicReportsSecondsAndAPausedTrack() throws {
        let scripts = FakeScripts()
        scripts.running = [.music]
        scripts.answer(.music, .success(track("paused", "Song", "Artist", position: 10, duration: 200.5)))
        #expect(try scripts.port.current() == NowPlayingSnapshot(app: .music, title: "Song", artist: "Artist", isPlaying: false, elapsed: 10, duration: 200.5))
    }

    @Test func aPlayingPlayerWinsOverAPausedOne() throws {
        let scripts = FakeScripts()
        scripts.running = [.music, .spotify]
        scripts.answer(.music, .success(track("paused", "Old", "A", position: 10, duration: 200)))
        scripts.answer(.spotify, .success(track("playing", "New", "B", position: 5, duration: 100_000)))
        #expect(try scripts.port.current()?.title == "New")
    }

    @Test func whenBothArePausedTheCallersPlayerWins() throws {
        let scripts = FakeScripts()
        scripts.running = [.music, .spotify]
        scripts.answer(.music, .success(track("paused", "Old", "A", position: 10, duration: 200)))
        scripts.answer(.spotify, .success(track("paused", "Mine", "B", position: 5, duration: 100_000)))
        #expect(try scripts.port.current(preferring: .spotify)?.title == "Mine")
        #expect(try scripts.port.current(preferring: .music)?.title == "Old")
    }

    @Test func aSpotifyLengthThatCannotBeMillisecondsIsReadAsSeconds() throws {
        let scripts = FakeScripts()
        scripts.running = [.spotify]
        scripts.answer(.spotify, .success(track("playing", "Song", "B", position: 61, duration: 240)))
        #expect(try scripts.port.current()?.duration == 240, "240 ms would end before the 61 s position")
    }

    @Test func automationIsAskedForOnceBeforeTheFirstScriptAndARefusalRunsNoScript() throws {
        let scripts = FakeScripts()
        scripts.running = [.music]
        scripts.permission[.music] = -1743
        #expect(throws: NowPlayingPortError.automationDenied) { try scripts.port.current() }
        #expect(scripts.ran.isEmpty, "no script is sent to a player the user refused")

        scripts.permission[.music] = 0
        _ = try scripts.port.current()
        _ = try scripts.port.current()
        #expect(scripts.permissionRequests == [.music, .music], "asked again after a refusal, then remembered once granted")
        #expect(scripts.ran.count == 2)
    }

    @Test func anEmptyOrMalformedAnswerMeansNoTrack() throws {
        let scripts = FakeScripts()
        scripts.running = [.music]
        #expect(try scripts.port.current() == nil, "stopped: the script returns an empty list")
        scripts.answer(.music, .success(NSAppleEventDescriptor(string: "unexpected")))
        #expect(try scripts.port.current() == nil)
    }

    @Test func refusedAutomationIsDeniedAndAQuitPlayerIsNoTrack() throws {
        let scripts = FakeScripts()
        scripts.running = [.music]
        scripts.answer(.music, .failure(.init(code: -1743)))
        #expect(throws: NowPlayingPortError.automationDenied) { try scripts.port.current() }
        scripts.answer(.music, .failure(.init(code: -600)))
        #expect(try scripts.port.current() == nil, "the player quit between the check and the script")
        scripts.answer(.music, .failure(.init(code: -1712)))
        #expect(throws: NowPlayingPortError.unavailable) { try scripts.port.current() }
    }

    @Test func oneRefusingPlayerDoesNotHideAnotherThatAnswers() throws {
        let scripts = FakeScripts()
        scripts.running = [.music, .spotify]
        scripts.answer(.music, .failure(.init(code: -1743)))
        scripts.answer(.spotify, .success(track("paused", "Song", "B", position: 5, duration: 100_000)))
        #expect(try scripts.port.current()?.app == .spotify)
    }

    @Test func commandsAreGuardedAndAddressOnlyTheGivenPlayer() throws {
        let scripts = FakeScripts()
        scripts.running = [.music]
        try scripts.port.send(.next, to: .music)
        try scripts.port.send(.playPause, to: .music)
        try scripts.port.send(.previous, to: .music)
        #expect(scripts.ran.count == 3)
        #expect(scripts.ran.allSatisfy { $0.contains("if application id \"com.apple.Music\" is running then") })
        #expect(scripts.ran[0].contains("next track"))
        #expect(scripts.ran[1].contains("playpause"))
        #expect(scripts.ran[2].contains("previous track"))

        scripts.answer(.music, .failure(.init(code: -1743)))
        #expect(throws: NowPlayingPortError.automationDenied) { try scripts.port.send(.next, to: .music) }
        #expect(throws: NowPlayingPortError.playerGone) { try scripts.port.send(.next, to: .spotify) }
        scripts.answer(.music, .failure(.init(code: -600)))
        #expect(throws: NowPlayingPortError.playerGone) { try scripts.port.send(.next, to: .music) }
        scripts.answer(.music, .failure(.init(code: -1712)))
        #expect(throws: NowPlayingPortError.unavailable) { try scripts.port.send(.next, to: .music) }
    }
}
