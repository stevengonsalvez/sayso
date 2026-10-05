import Foundation
import Testing
@testable import SaysoCore

private final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000_000) }

private struct Sent: Equatable {
    let command: NowPlayingCommand
    let app: NowPlayingApp
}

/// Behaves like an already running player: its position moves with the shared clock while it plays.
private final class FakePlayer: NowPlayingPort, @unchecked Sendable {
    private struct Track {
        let app: NowPlayingApp
        let title: String
        let artist: String
        let duration: TimeInterval?
    }

    private let lock = NSLock()
    private let clock: Clock
    private var track: Track?
    private var upNext: Track?
    private var position: TimeInterval = 0
    private var playingSince: Date?
    private var readError: NowPlayingPortError?
    private var commandError: NowPlayingPortError?
    private var readCount = 0
    private var sentCommands: [Sent] = []
    private var preferences: [NowPlayingApp?] = []

    init(clock: Clock) { self.clock = clock }

    var reads: Int { locked { readCount } }
    var commands: [Sent] { locked { sentCommands } }
    /// The player the module asked to be preferred on each read.
    var preferred: [NowPlayingApp?] { locked { preferences } }

    func load(_ title: String, artist: String = "Artist", app: NowPlayingApp = .spotify, duration: TimeInterval?, at start: TimeInterval = 0, playing: Bool = true) {
        locked {
            track = Track(app: app, title: title, artist: artist, duration: duration)
            position = start
            playingSince = playing ? clock.now : nil
        }
    }

    /// The track `next` switches to.
    func queue(_ title: String, artist: String = "Artist", duration: TimeInterval?) {
        locked { upNext = Track(app: track?.app ?? .spotify, title: title, artist: artist, duration: duration) }
    }

    func pause() { locked { settle(); playingSince = nil } }
    func resume() { locked { settle(); playingSince = clock.now } }
    func quit() { locked { track = nil; playingSince = nil } }
    func failReads(_ error: NowPlayingPortError?) { locked { readError = error } }
    func failCommands(_ error: NowPlayingPortError?) { locked { commandError = error } }

    func current(preferring app: NowPlayingApp?) throws(NowPlayingPortError) -> NowPlayingSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        readCount += 1
        preferences.append(app)
        if let readError { throw readError }
        guard let track else { return nil }
        let elapsed = position + (playingSince.map { clock.now.timeIntervalSince($0) } ?? 0)
        return NowPlayingSnapshot(
            app: track.app, title: track.title, artist: track.artist,
            isPlaying: playingSince != nil, elapsed: elapsed, duration: track.duration
        )
    }

    func send(_ command: NowPlayingCommand, to app: NowPlayingApp) throws(NowPlayingPortError) {
        lock.lock()
        defer { lock.unlock() }
        sentCommands.append(Sent(command: command, app: app))
        if let commandError { throw commandError }
        switch command {
        case .playPause:
            settle()
            playingSince = playingSince == nil ? clock.now : nil
        case .next:
            if let upNext { track = upNext }
            upNext = nil
            position = 0
            if playingSince != nil { playingSince = clock.now }
        case .previous:
            position = 0
            if playingSince != nil { playingSince = clock.now }
        }
    }

    /// Folds the time played so far into the position. Call with the lock held.
    private func settle() {
        if let since = playingSince { position += clock.now.timeIntervalSince(since) }
        if playingSince != nil { playingSince = clock.now }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class FakeScheduler: SaysoScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var nextID = 0
    private var pending: [(id: Int, at: Date, action: @Sendable () -> Void)] = []
    var jobs: [Date] { lock.withLock { pending.map(\.at) } }

    func schedule(at date: Date, _ action: @escaping @Sendable () -> Void) -> SaysoSubscription {
        let id = lock.withLock { () -> Int in nextID += 1; pending.append((nextID, date, action)); return nextID }
        return SaysoSubscription { [weak self] in self?.lock.withLock { self?.pending.removeAll { $0.id == id } } }
    }

    /// Fires every job due at `now`, earliest first, like a real timer firing late.
    func runDue(_ now: Date) {
        for _ in 0..<10_000 {
            let job = lock.withLock { () -> (id: Int, at: Date, action: @Sendable () -> Void)? in
                guard let index = pending.indices.filter({ pending[$0].at <= now }).min(by: { pending[$0].at < pending[$1].at })
                else { return nil }
                return pending.remove(at: index)
            }
            guard let job else { return }
            job.action()
        }
        Issue.record("jobs kept re-arming at or before now: a runaway loop")
    }
}

private final class Captured: @unchecked Sendable {
    var runtimes: [SaysoModuleRuntime] = []
}

private struct Probe: SaysoModule {
    let inner: NowPlayingModule
    let captured: Captured
    var descriptor: SaysoModuleDescriptor { inner.descriptor }
    func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        let runtime = inner.makeRuntime(context: context)
        captured.runtimes.append(runtime)
        return runtime
    }
}

/// What the module reports through a bare context, so "reported once" can be counted exactly.
private final class Reports: @unchecked Sendable {
    var failures = 0
    var published: [SaysoActivity] = []
    var dismissed = 0
}

/// Every change to the now playing line, as the notch would paint it.
private final class Painted: @unchecked Sendable {
    var lines: [String?] = []
}

private struct Rig {
    let host: SaysoModuleHost
    let module: NowPlayingModule
    let player: FakePlayer
    let scheduler: FakeScheduler
    let clock: Clock
    let captured: Captured
    let painted: Painted

    func advance(_ seconds: TimeInterval) {
        clock.now += seconds
        scheduler.runDue(clock.now)
    }

    var lines: [SaysoActivity] { host.engine.stack.filter { $0.moduleID == "now-playing" } }
    var line: SaysoActivity? { lines.first }
    var retained: Int { (captured.runtimes.last as? SaysoResourceAccounting)?.retainedResources ?? -1 }

    @discardableResult
    func tap(_ actionID: String) -> Bool {
        host.perform(actionID: actionID, stackID: "now-playing", moduleID: "now-playing")
    }
}

private func paint(_ activity: SaysoActivity?) -> String? {
    activity.map { activity in
        let presentation = SaysoActivityPresentation(activity)
        return [presentation.title, presentation.subtitle].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Enables the module with `setUp` applied to the player first, then lets the first check run.
private func rig(_ setUp: (FakePlayer) -> Void = { _ in }) -> Rig {
    let clock = Clock(), scheduler = FakeScheduler(), captured = Captured(), painted = Painted()
    let player = FakePlayer(clock: clock)
    setUp(player)
    let module = NowPlayingModule(port: player, scheduler: scheduler, now: { clock.now })
    let host = SaysoModuleHost(modules: [Probe(inner: module, captured: captured)], now: { clock.now })
    host.onActivitiesChanged = { [weak host] in
        painted.lines.append(paint(host?.engine.stack.first { $0.moduleID == "now-playing" }))
    }
    host.enable("now-playing")
    let rig = Rig(host: host, module: module, player: player, scheduler: scheduler, clock: clock, captured: captured, painted: painted)
    rig.advance(0)
    return rig
}

private func close(_ value: Double?, _ expected: Double) -> Bool {
    value.map { abs($0 - expected) < 1e-9 } ?? false
}

@Suite struct NowPlayingModuleTests {
    @Test func nothingPlayingShowsNothingAndChecksAgainSlowly() {
        let rig = rig()
        #expect(rig.lines.isEmpty)
        #expect(rig.player.reads == 1)
        #expect(rig.scheduler.jobs == [rig.clock.now + NowPlayingModule.idlePollSeconds])

        rig.advance(NowPlayingModule.idlePollSeconds)
        #expect(rig.player.reads == 2)
        #expect(rig.scheduler.jobs.count == 1)
        #expect(rig.lines.isEmpty)
    }

    @Test func theFirstCheckWaitsForTheSchedulerSoTurningItOnNeverBlocksOnAPlayer() {
        let clock = Clock(), scheduler = FakeScheduler(), player = FakePlayer(clock: clock)
        let module = NowPlayingModule(port: player, scheduler: scheduler, now: { clock.now })
        let host = SaysoModuleHost(modules: [module], now: { clock.now })
        host.enable("now-playing")
        #expect(player.reads == 0)
        #expect(scheduler.jobs == [clock.now])
    }

    @Test func aPlayingTrackShowsTitleArtistAppAndProgress() throws {
        let rig = rig { $0.load("Song", artist: "Artist", app: .spotify, duration: 240, at: 60) }
        let line = try #require(rig.line)
        #expect(rig.lines.count == 1)
        #expect(line.kind == .media)
        #expect(line.title == "Song · Artist · Spotify")
        #expect(close(line.progress, 0.25))
        #expect(line.expiresAfter == nil)
        #expect(line.actions.map(\.id) == ["previous", "play-pause", "next", "dismiss"])
        #expect(line.actions.map(\.title) == ["Previous", "Pause", "Next", "Dismiss"])
    }

    @Test func aBlankArtistIsLeftOutAndABlankTitleReadsAsUnknown() throws {
        let rig = rig { $0.load("", artist: "", app: .music, duration: 100) }
        #expect(rig.line?.title == "Unknown track · Music")
    }

    @Test func progressComesFromTheClockBetweenChecksNotFromTicks() throws {
        let rig = rig { $0.load("Song", duration: 100, at: 50) }
        let reads = rig.player.reads
        // One label tick due after 1 s fires late, at 2.9 s: the position must follow the clock, not count ticks.
        rig.advance(2.9)
        #expect(rig.player.reads == reads, "no check of the player before the check interval")
        #expect(close(rig.line?.progress, 0.529))
    }

    @Test func theLineIsRepaintedOnlyWhenItsTextChanges() {
        // 400 s track from 0: the whole percent shown changes three times in the first 12 s.
        let rig = rig { $0.load("Song", duration: 400) }
        let before = rig.painted.lines.count
        for _ in 0..<12 { rig.advance(1) }
        let repaints = Array(rig.painted.lines.dropFirst(before))
        #expect(repaints.count == 3, "\(repaints)")
        #expect(zip(rig.painted.lines, rig.painted.lines.dropFirst()).allSatisfy { $0 != $1 }, "no repaint without a change")
    }

    @Test func theCheckCadenceFollowsWhatTheLineCanShow() {
        let playing = rig { $0.load("Song", duration: 240) }
        #expect(playing.scheduler.jobs == [playing.clock.now + NowPlayingModule.labelTickSeconds], "the percent moves, so tick")

        let stream = rig { $0.load("Radio", duration: nil) }
        #expect(stream.line?.progress == nil)
        #expect(stream.scheduler.jobs == [stream.clock.now + NowPlayingModule.activePollSeconds], "nothing moves: only re-check")

        let paused = rig { $0.load("Song", duration: 240, playing: false) }
        #expect(paused.scheduler.jobs == [paused.clock.now + NowPlayingModule.activePollSeconds])
    }

    @Test func aPauseShowsPausedThenFadesAfterAMinute() throws {
        let rig = rig { $0.load("Song", duration: 240, at: 60) }
        rig.player.pause()
        rig.advance(NowPlayingModule.activePollSeconds)
        let paused = try #require(rig.line)
        #expect(paused.title == "Paused · Song · Artist · Spotify")
        #expect(paused.actions.first { $0.id == "play-pause" }?.title == "Play")
        #expect(close(paused.progress, 0.25), "the position stops with the player")
        let seen = rig.clock.now

        rig.advance(NowPlayingModule.pausedFadeSeconds - 1)
        #expect(rig.line?.title == "Paused · Song · Artist · Spotify")
        rig.advance(1)
        #expect(rig.clock.now == seen + NowPlayingModule.pausedFadeSeconds)
        #expect(rig.lines.isEmpty, "a minute after the pause was seen the line fades")
        #expect(rig.scheduler.jobs == [rig.clock.now + NowPlayingModule.idlePollSeconds], "faded: check slowly")

        rig.player.resume()
        rig.advance(NowPlayingModule.idlePollSeconds)
        #expect(rig.line?.title == "Song · Artist · Spotify")
    }

    @Test func aNewTrackReplacesTheLine() {
        let rig = rig { $0.load("First", duration: 240) }
        rig.player.load("Second", artist: "Other", duration: 180)
        rig.advance(NowPlayingModule.activePollSeconds)
        #expect(rig.lines.map(\.title) == ["Second · Other · Spotify"])
        #expect(close(rig.line?.progress, NowPlayingModule.activePollSeconds / 180), "the new track's own position")
    }

    @Test func aPlayerThatQuitsClearsTheLine() {
        let rig = rig { $0.load("Song", duration: 240) }
        rig.player.quit()
        rig.advance(NowPlayingModule.activePollSeconds)
        #expect(rig.lines.isEmpty)
        #expect(rig.scheduler.jobs == [rig.clock.now + NowPlayingModule.idlePollSeconds])
    }

    @Test func dismissHidesTheTrackUntilTheTrackChanges() {
        let rig = rig { $0.load("Song", duration: 240) }
        #expect(rig.tap("dismiss"))
        rig.advance(0)
        #expect(rig.lines.isEmpty)
        #expect(rig.scheduler.jobs == [rig.clock.now + NowPlayingModule.idlePollSeconds], "hidden: no label tick")

        rig.advance(NowPlayingModule.idlePollSeconds)
        #expect(rig.lines.isEmpty, "the same track stays hidden")

        rig.player.load("Next song", duration: 200)
        rig.advance(NowPlayingModule.idlePollSeconds)
        #expect(rig.line?.title == "Next song · Artist · Spotify")
    }

    @Test func disablingForgetsTheTrackAndStopsChecking() {
        let rig = rig { $0.load("Song", duration: 240) }
        #expect(rig.retained == 1)

        rig.host.disable("now-playing")
        #expect(rig.lines.isEmpty)
        #expect(rig.retained == 0)
        #expect(rig.scheduler.jobs.isEmpty)
        let reads = rig.player.reads
        rig.advance(60)
        #expect(rig.player.reads == reads)

        rig.host.enable("now-playing")
        rig.advance(0)
        #expect(rig.player.reads == reads + 1, "on again checks afresh")
        #expect(rig.line?.title == "Song · Artist · Spotify")
    }

    @Test func passesTheGenericModuleAcceptance() {
        let clock = Clock()
        let module = NowPlayingModule(port: FakePlayer(clock: clock), scheduler: FakeScheduler(), now: { clock.now })
        #expect(module.descriptor.id == "now-playing")
        #expect(module.descriptor.capabilities == [.automation])
        #expect(SaysoModuleAcceptance.violations(for: module).isEmpty)
    }

    @Test func transportActionsRunFromTheScheduledJobNotInsideTheTap() {
        let rig = rig { $0.load("Song", app: .music, duration: 240) }
        rig.player.queue("Next song", duration: 200)
        #expect(rig.tap("next"))
        #expect(rig.player.commands.isEmpty, "the tap returns at once; a slow player never holds the caller or the host lock")
        #expect(rig.scheduler.jobs == [rig.clock.now], "still one job, due now")
        rig.advance(0)
        #expect(rig.player.commands == [Sent(command: .next, app: .music)])
        let reads = rig.player.reads
        rig.advance(NowPlayingModule.commandSettleSeconds)
        #expect(rig.player.reads == reads + 1, "checked again soon after a command")
        #expect(rig.line?.title == "Next song · Artist · Music")

        rig.tap("play-pause")
        rig.tap("previous")
        rig.advance(0)
        #expect(rig.player.commands.map(\.command) == [.next, .playPause, .previous], "taps run in order")
        #expect(rig.player.commands.allSatisfy { $0.app == .music })
        rig.advance(NowPlayingModule.commandSettleSeconds)
        #expect(rig.line?.title == "Paused · Next song · Artist · Music")
        #expect(rig.scheduler.jobs.count == 1)
    }

    @Test func repeatedlyRefusedCommandsReportOnceAndNeverQuarantine() {
        let rig = rig { $0.load("Song", duration: 240) }
        rig.player.failCommands(.unavailable)
        for _ in 0..<3 {
            #expect(rig.tap("next"), "the action is still routed; the module absorbs the failure")
            rig.advance(0)
        }
        #expect(rig.player.commands.count == 3)
        #expect(rig.host.health(of: "now-playing") == .degraded, "reported, but three refused taps must not quarantine")
        #expect(rig.line?.title == "Song · Artist · Spotify")
        #expect(rig.scheduler.jobs.count == 1)
    }

    @Test func aCommandToAPlayerThatQuitIsNotAFailureAndClearsTheLineSoon() {
        let rig = rig { $0.load("Song", duration: 240) }
        rig.player.quit()
        rig.player.failCommands(.playerGone)
        rig.tap("play-pause")
        rig.advance(0)
        #expect(rig.host.health(of: "now-playing") == .ready)
        rig.advance(NowPlayingModule.commandSettleSeconds)
        #expect(rig.lines.isEmpty, "re-read after the command finds nothing")
    }

    @Test func aTapQueuedJustBeforeTurningOffIsDropped() {
        let rig = rig { $0.load("Song", duration: 240) }
        rig.tap("next")
        rig.host.disable("now-playing")
        rig.advance(0)
        #expect(rig.player.commands.isEmpty, "off means no commands either")
        #expect(rig.retained == 0)
    }

    @Test func aFailedOrEmptyReadDoesNotUndoDismiss() {
        let rig = rig { $0.load("Song", duration: 240) }
        rig.tap("dismiss")
        rig.advance(0)
        #expect(rig.lines.isEmpty)
        rig.player.failReads(.unavailable)
        rig.advance(NowPlayingModule.idlePollSeconds)
        rig.player.failReads(nil)
        rig.advance(NowPlayingModule.failureBackoffSeconds)
        #expect(rig.lines.isEmpty, "the same track is still the dismissed one")
    }

    @Test func theCurrentPlayerIsPreferredWhenTwoAreEquallyPaused() {
        let rig = rig { $0.load("Song", app: .spotify, duration: 240) }
        #expect(rig.player.preferred == [nil], "nothing shown yet, nothing to prefer")
        rig.advance(NowPlayingModule.activePollSeconds)
        #expect(rig.player.preferred.last == .spotify)
    }

    @Test func aClockSetBackDoesNotStallChecksOrTheFade() {
        let rig = rig { $0.load("Song", duration: 240, playing: false) }
        rig.clock.now -= 3600
        rig.module.clockChanged()
        #expect(rig.scheduler.jobs.count == 1)
        #expect(rig.scheduler.jobs.allSatisfy { $0 <= rig.clock.now + NowPlayingModule.activePollSeconds }, "\(rig.scheduler.jobs)")
        rig.advance(NowPlayingModule.pausedFadeSeconds)
        #expect(rig.lines.isEmpty, "the pause fades a minute after the clock change, not an hour later")
    }

    @Test func aDeniedOrFailingPlayerIsReportedOnceAndCheckedLessOften() {
        let clock = Clock(), scheduler = FakeScheduler(), player = FakePlayer(clock: clock), reports = Reports()
        player.failReads(.automationDenied)
        let module = NowPlayingModule(port: player, scheduler: scheduler, now: { clock.now })
        let runtime = module.makeRuntime(context: SaysoModuleContext(
            moduleID: "now-playing",
            publish: { reports.published.append($0) },
            reportFailure: { reports.failures += 1 },
            dismiss: { _ in reports.dismissed += 1 }
        ))
        func advance(_ seconds: TimeInterval) {
            clock.now += seconds
            scheduler.runDue(clock.now)
        }
        runtime.start()
        advance(0)
        #expect(reports.failures == 1)
        #expect(scheduler.jobs == [clock.now + NowPlayingModule.failureBackoffSeconds])
        for _ in 0..<5 { advance(NowPlayingModule.failureBackoffSeconds) }
        #expect(player.reads == 6)
        #expect(reports.failures == 1, "a lasting refusal is reported once, not on every check")
        #expect(reports.published.isEmpty)

        player.failReads(nil)
        player.load("Song", duration: 240)
        advance(NowPlayingModule.failureBackoffSeconds)
        #expect(reports.published.last?.title == "Song · Artist · Spotify")

        player.failReads(.unavailable)
        advance(NowPlayingModule.activePollSeconds)
        #expect(reports.failures == 2, "a new failure after a good read is reported again")
        #expect(reports.dismissed == 1, "a track that can no longer be read is not left showing")
        #expect(scheduler.jobs == [clock.now + NowPlayingModule.failureBackoffSeconds])
        runtime.stop()
    }

    @Test func aNonFiniteClockNeitherTrapsNorArms() {
        let rig = rig { $0.load("Song", duration: 240, at: 60) }
        rig.clock.now = Date(timeIntervalSince1970: .nan)
        rig.tap("dismiss")
        #expect(rig.scheduler.jobs.isEmpty)

        let clock = Clock()
        clock.now = Date(timeIntervalSince1970: .infinity)
        let scheduler = FakeScheduler()
        let module = NowPlayingModule(port: FakePlayer(clock: clock), scheduler: scheduler, now: { clock.now })
        SaysoModuleHost(modules: [module], now: { clock.now }).enable("now-playing")
        #expect(scheduler.jobs.isEmpty)
    }
}
