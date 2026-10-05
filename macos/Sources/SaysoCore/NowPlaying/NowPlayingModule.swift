import Foundation

/// Shows the track an already running player is playing, with its progress, and passes transport commands back.
/// The player is read only at check times; between checks the position is worked out from the injected clock.
///
/// Every player call and every publish happens inside the one scheduled job, so with a serial scheduler queue a
/// slow player never holds the caller, the host lock or the main thread, and publishes never overtake each other.
public final class NowPlayingModule: SaysoModule, @unchecked Sendable {
    /// Between checks while nothing is shown.
    public static let idlePollSeconds: TimeInterval = 5
    /// Between checks while a track is shown, so a pause, skip or seek made in the player shows up soon.
    public static let activePollSeconds: TimeInterval = 3
    /// While a track with a known length plays, the shown percent can change this often.
    public static let labelTickSeconds: TimeInterval = 1
    /// A paused track stays shown this long after the pause was first seen.
    public static let pausedFadeSeconds: TimeInterval = 60
    /// After a command, the player is checked again this soon so the line follows it.
    public static let commandSettleSeconds: TimeInterval = 0.5
    /// After a refused or failed read, the player is left alone this long.
    public static let failureBackoffSeconds: TimeInterval = 60
    /// At most one failure is reported in this window, the host's quarantine window, so a player that fails now and
    /// then, or a run of refused taps, marks the module degraded without ever quarantining it.
    public static let failureReportWindowSeconds: TimeInterval = 300
    /// Taps beyond this many waiting commands are dropped.
    static let maxPendingCommands = 5
    static let stackID = "now-playing"

    public let descriptor = SaysoModuleDescriptor(
        id: "now-playing", title: "Now Playing", capabilities: [.automation], surfaces: [.compact, .peek, .expanded, .settings]
    )
    fileprivate let port: NowPlayingPort
    fileprivate let scheduler: SaysoScheduling
    fileprivate let now: @Sendable () -> Date
    private let lock = NSLock()
    private var runtime: Runtime?

    public init(port: NowPlayingPort, scheduler: SaysoScheduling, now: @escaping @Sendable () -> Date = { Date() }) {
        self.port = port
        self.scheduler = scheduler
        self.now = now
    }

    public func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        let runtime = Runtime(module: self, context: context)
        lock.withLock { self.runtime = runtime }
        return runtime
    }

    /// Call after the system clock changes: pending check and fade times were set against the old time.
    public func clockChanged() { current?.clockChanged() }

    private var current: Runtime? { lock.withLock { runtime } }

    /// Forgets a stopped runtime so later calls are refused instead of reaching a dead runtime.
    fileprivate func detach(_ stopped: Runtime) {
        lock.withLock { if runtime === stopped { runtime = nil } }
    }

    /// "Song · Artist · Spotify", or "Paused · Song · Artist · Spotify"; a blank artist is left out.
    static func title(of track: NowPlayingSnapshot) -> String {
        let name = track.title.isEmpty ? "Unknown track" : track.title
        let line = [name, track.artist, track.app.displayName].filter { !$0.isEmpty }.joined(separator: " · ")
        return track.isPlaying ? line : "Paused · \(line)"
    }

    /// Non-finite or negative readings become safe values, and the position never passes the end.
    static func sanitized(_ track: NowPlayingSnapshot) -> NowPlayingSnapshot {
        let duration = track.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        var elapsed = track.elapsed.isFinite ? max(track.elapsed, 0) : 0
        if let duration { elapsed = min(elapsed, duration) }
        return NowPlayingSnapshot(
            app: track.app, title: track.title, artist: track.artist,
            isPlaying: track.isPlaying, elapsed: elapsed, duration: duration
        )
    }

    fileprivate final class Runtime: SaysoModuleRuntime, SaysoResourceAccounting, @unchecked Sendable {
        /// What makes a track the same track; a change of any part is a new track.
        private struct TrackKey: Equatable {
            let app: NowPlayingApp
            let title: String
            let artist: String
            let duration: TimeInterval?

            init(_ track: NowPlayingSnapshot) {
                (app, title, artist, duration) = (track.app, track.title, track.artist, track.duration)
            }
        }

        /// The line as the notch paints it: text and whole percent. Equal lines are never published twice.
        private struct Line: Equatable {
            let title: String
            let percent: Int?
            let progress: Double?
            let isPlaying: Bool

            static func == (lhs: Line, rhs: Line) -> Bool {
                (lhs.title, lhs.percent, lhs.isPlaying) == (rhs.title, rhs.percent, rhs.isPlaying)
            }
        }

        private enum Effect {
            case show(Line)
            case clear
        }

        /// What the job did with the player before taking the lock again.
        private struct Outcome {
            var read: Result<NowPlayingSnapshot?, NowPlayingPortError>?
            var commandsRan = false
            var commandFailed = false
        }

        unowned let module: NowPlayingModule
        let context: SaysoModuleContext
        private let lock = NSLock()
        private var running = false
        private var job: SaysoSubscription?
        private var track: NowPlayingSnapshot?
        /// Clock time of the read that produced `track`.
        private var readAt = Date.distantPast
        /// When the current track was first seen paused; nil while it plays.
        private var pausedSince: Date?
        /// Dismissed from the notch; stays hidden until a different track is read.
        private var hidden: TrackKey?
        private var pollDue = Date.distantPast
        private var shown: Line?
        /// Taps waiting for the job, oldest first.
        private var pending: [NowPlayingCommand] = []
        /// The last read failed, so the next read waits for the backoff.
        private var failing = false
        private var lastReport: Date?

        init(module: NowPlayingModule, context: SaysoModuleContext) {
            self.module = module
            self.context = context
        }

        var retainedResources: Int { lock.withLock { job == nil ? 0 : 1 } }

        /// The first check is a scheduled job, so turning the module on never waits on a player.
        func start() {
            lock.withLock {
                running = true
                pollDue = module.now()
                rearm(at: pollDue, soon: true)
            }
        }

        func stop() {
            lock.withLock {
                running = false
                job?.cancel()
                job = nil
                track = nil
                pausedSince = nil
                hidden = nil
                shown = nil
                pending = []
                failing = false
                lastReport = nil
            }
            module.detach(self)
        }

        /// Only records the tap and asks for the job now: the host calls this holding its lock, often on the main
        /// thread, and a player can take seconds to answer.
        func handle(stackID: String, actionID: String) {
            guard stackID == NowPlayingModule.stackID else { return }
            let command: NowPlayingCommand? = switch actionID {
            case "play-pause": .playPause
            case "next": .next
            case "previous": .previous
            default: nil
            }
            lock.withLock {
                guard running else { return }
                if let command {
                    guard pending.count < NowPlayingModule.maxPendingCommands else { return }
                    pending.append(command)
                } else if actionID == "dismiss" {
                    hidden = track.map(TrackKey.init)
                } else {
                    return
                }
                rearm(at: module.now(), soon: true)
            }
        }

        func clockChanged() {
            lock.withLock {
                guard running else { return }
                let now = module.now()
                pollDue = min(pollDue, now)
                pausedSince = pausedSince.map { min($0, now) }
                lastReport = lastReport.map { min($0, now) }
                readAt = min(readAt, now)
                rearm(at: now, soon: true)
            }
        }

        /// Sends waiting commands and reads the player when a check is due, both outside the lock, then folds the
        /// outcome in.
        private func tick() {
            guard let (commands, app, readDue) = lock.withLock({ () -> ([NowPlayingCommand], NowPlayingApp?, Bool)? in
                guard running else { return nil }
                defer { pending = [] }
                return (pending, track?.app, !(module.now() < pollDue))
            }) else { return }
            var outcome = Outcome()
            if let app {
                for command in commands {
                    outcome.commandsRan = true
                    do {
                        try module.port.send(command, to: app)
                    } catch {
                        // A player that quit is not a fault; the re-read after the command clears its line.
                        if error != .playerGone { outcome.commandFailed = true }
                    }
                }
            }
            if readDue, !outcome.commandsRan {
                do {
                    outcome.read = .success(try module.port.current(preferring: app))
                } catch {
                    outcome.read = .failure(error)
                }
            }
            refresh(outcome)
        }

        /// Takes in one read. A failed read forgets the track, since it can no longer be vouched for. Call with the
        /// lock held.
        private func apply(_ read: Result<NowPlayingSnapshot?, NowPlayingPortError>, at now: Date) {
            let snapshot = (try? read.get())?.map(NowPlayingModule.sanitized)
            let key = snapshot.map(TrackKey.init)
            if let snapshot {
                if snapshot.isPlaying {
                    pausedSince = nil
                } else if key != track.map(TrackKey.init) || pausedSince == nil {
                    pausedSince = now
                }
            } else {
                pausedSince = nil
            }
            // Only a different track undoes Dismiss; a failed or empty read in between does not.
            if let key, hidden != nil, hidden != key { hidden = nil }
            track = snapshot
            readAt = now
            if case .failure = read { failing = true } else { failing = false }
        }

        /// At most one report per window. Call with the lock held.
        private func shouldReport(at now: Date) -> Bool {
            if let lastReport, now.timeIntervalSince(lastReport) < NowPlayingModule.failureReportWindowSeconds { return false }
            lastReport = now
            return true
        }

        /// Folds in what the job did, works out the line and re-arms the single job under the lock, then reports and
        /// publishes outside it, and only when the line changed: publishing takes the host lock, and the host calls
        /// into this runtime while holding that lock.
        private func refresh(_ outcome: Outcome) {
            let (effect, report) = lock.withLock { () -> (Effect?, Bool) in
                guard running else { return (nil, false) }
                let now = module.now()
                let wasFailing = failing
                if let read = outcome.read { apply(read, at: now) }
                // A run of failed reads is one failure: a lasting refusal is reported once, not on every check.
                let newlyFailing = failing && !wasFailing
                let report = (newlyFailing || outcome.commandFailed) && shouldReport(at: now)
                let line = line(at: now)
                if outcome.commandsRan {
                    pollDue = now.addingTimeInterval(NowPlayingModule.commandSettleSeconds)
                } else if outcome.read != nil || (line == nil) != (shown == nil) {
                    let wait = failing ? NowPlayingModule.failureBackoffSeconds
                        : line == nil ? NowPlayingModule.idlePollSeconds : NowPlayingModule.activePollSeconds
                    pollDue = now.addingTimeInterval(wait)
                }
                rearm(at: now, showing: line)
                guard line != shown else { return (nil, report) }
                shown = line
                return (line.map(Effect.show) ?? .clear, report)
            }
            if report { context.reportFailure() }
            switch effect {
            case let .show(line)?:
                context.publish(
                    stackID: NowPlayingModule.stackID, kind: .media, title: line.title,
                    actions: [
                        SaysoAction(id: "previous", title: "Previous"),
                        SaysoAction(id: "play-pause", title: line.isPlaying ? "Pause" : "Play"),
                        SaysoAction(id: "next", title: "Next"),
                        SaysoAction(id: "dismiss", title: "Dismiss"),
                    ],
                    progress: line.progress
                )
            case .clear?: context.dismiss(stackID: NowPlayingModule.stackID)
            case nil: break
            }
        }

        /// Nil when nothing is shown: no track, dismissed, or paused for longer than the fade. Call with the lock held.
        private func line(at now: Date) -> Line? {
            guard let track, hidden != TrackKey(track), !faded(at: now) else { return nil }
            let played = track.isPlaying ? max(now.timeIntervalSince(readAt), 0) : 0
            let progress = track.duration.map { min(track.elapsed + played, $0) / $0 }.flatMap { $0.isFinite ? $0 : nil }
            return Line(
                title: NowPlayingModule.title(of: track),
                percent: progress.map { Int(($0 * 100).rounded()) },
                progress: progress,
                isPlaying: track.isPlaying
            )
        }

        private func faded(at now: Date) -> Bool {
            pausedSince.map { now >= $0.addingTimeInterval(NowPlayingModule.pausedFadeSeconds) } ?? false
        }

        /// One job: due now when there is work waiting (`soon`), otherwise the next check, or sooner the next label
        /// tick while a track with a length plays, or the fade of a shown paused track. None for a non-finite clock,
        /// which a real timer would fire at once. Call with the lock held.
        private func rearm(at now: Date, showing line: Line? = nil, soon: Bool = false) {
            job?.cancel()
            job = nil
            guard running, now.timeIntervalSince1970.isFinite else { return }
            var due = soon ? now : pollDue
            if let line, line.isPlaying, line.percent != nil {
                due = min(due, now.addingTimeInterval(NowPlayingModule.labelTickSeconds))
            }
            if line != nil, let pausedSince {
                due = min(due, pausedSince.addingTimeInterval(NowPlayingModule.pausedFadeSeconds))
            }
            job = module.scheduler.schedule(at: due) { [weak self] in self?.tick() }
        }
    }
}
