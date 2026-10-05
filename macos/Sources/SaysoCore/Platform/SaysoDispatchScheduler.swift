import Foundation

/// Production scheduler: one DispatchSourceTimer per job, none while idle. Jobs are due at a wall-clock date.
public struct SaysoDispatchScheduler: SaysoScheduling {
    private let queue: DispatchQueue

    public init(queue: DispatchQueue = .main) { self.queue = queue }

    public func schedule(at date: Date, _ action: @escaping @Sendable () -> Void) -> SaysoSubscription {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Wall-clock deadline: a monotonic one stops counting while the Mac sleeps, so a job due during sleep would fire late.
        timer.schedule(wallDeadline: Self.wallTime(date), leeway: .milliseconds(10))
        timer.setEventHandler {
            action()
            timer.cancel()
        }
        timer.resume()
        return SaysoSubscription { timer.cancel() }
    }

    /// Dates outside a sane range (NaN, infinite, absurdly far) are clamped, so a bad date can never trap the app.
    private static func wallTime(_ date: Date) -> DispatchWallTime {
        let raw = date.timeIntervalSince1970
        let seconds = raw.isNaN ? Date().timeIntervalSince1970 : min(max(raw, 0), 4_102_444_800) // 2100-01-01
        let whole = seconds.rounded(.down)
        return DispatchWallTime(timespec: timespec(tv_sec: Int(whole), tv_nsec: Int((seconds - whole) * 1_000_000_000)))
    }
}
