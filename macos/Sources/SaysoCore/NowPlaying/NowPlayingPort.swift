import Foundation

/// The players Now Playing can read. Each is asked only while it is already running.
public enum NowPlayingApp: String, CaseIterable, Sendable {
    case music
    case spotify

    public var bundleID: String {
        switch self {
        case .music: "com.apple.Music"
        case .spotify: "com.spotify.client"
        }
    }

    public var displayName: String {
        switch self {
        case .music: "Music"
        case .spotify: "Spotify"
        }
    }
}

/// One read of a player.
public struct NowPlayingSnapshot: Equatable, Sendable {
    public let app: NowPlayingApp
    public let title: String
    public let artist: String
    public let isPlaying: Bool
    /// Seconds into the track at the moment of the read.
    public let elapsed: TimeInterval
    /// Nil for a stream with no known length.
    public let duration: TimeInterval?

    public init(app: NowPlayingApp, title: String, artist: String, isPlaying: Bool, elapsed: TimeInterval, duration: TimeInterval?) {
        self.app = app
        self.title = title
        self.artist = artist
        self.isPlaying = isPlaying
        self.elapsed = elapsed
        self.duration = duration
    }
}

public enum NowPlayingCommand: String, CaseIterable, Sendable {
    case playPause
    case next
    case previous
}

public enum NowPlayingPortError: Error, Equatable, Sendable {
    /// The user refused, or has not yet allowed, Automation for this player.
    case automationDenied
    /// The player did not answer in time or answered with an error.
    case unavailable
    /// The player quit or has nothing loaded: not a fault, there is just nothing to talk to.
    case playerGone
}

/// Boundary to the music players; the adapter owns AppleScript.
public protocol NowPlayingPort: Sendable {
    /// The track of a player that is already running, preferring one that is playing, then `preferring` when two are
    /// paused; nil when no supported player is running or none has a track. Must never launch a player.
    func current(preferring: NowPlayingApp?) throws(NowPlayingPortError) -> NowPlayingSnapshot?
    /// Must never launch the player.
    func send(_ command: NowPlayingCommand, to app: NowPlayingApp) throws(NowPlayingPortError)
}

public extension NowPlayingPort {
    func current() throws(NowPlayingPortError) -> NowPlayingSnapshot? { try current(preferring: nil) }
}
