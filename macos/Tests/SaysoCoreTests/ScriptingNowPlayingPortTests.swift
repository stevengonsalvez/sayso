import Foundation
import Testing
@testable import SaysoCore

/// Records every script the port would run and answers with canned AppleScript results, so no real player is
/// asked, launched or prompted for.
private final class FakeScripts: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [String] = []
    private var answers: [NowPlayingApp: Result<NSAppleEventDescriptor, ScriptingNowPlayingPort.ScriptError>] = [:]
    var running: Set<NowPlayingApp> = []

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

    var port: ScriptingNowPlayingPort {
        ScriptingNowPlayingPort(isRunning: { [self] in running.contains($0) }, run: { [self] in run($0) })
    }
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
        #expect(throws: NowPlayingPortError.unavailable) { try scripts.port.send(.playPause, to: .music) }
        #expect(scripts.ran.isEmpty, "a player that is not running is never addressed, so it is never launched")
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
        #expect(throws: NowPlayingPortError.unavailable) { try scripts.port.send(.next, to: .spotify) }
    }
}
