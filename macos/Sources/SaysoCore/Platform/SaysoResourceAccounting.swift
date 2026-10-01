import Foundation

/// Runtimes report live observers, timers, hooks and sockets so acceptance can prove `stop()` released them.
public protocol SaysoResourceAccounting {
    var retainedResources: Int { get }
}
