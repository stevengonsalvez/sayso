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

    private static func wallTime(_ date: Date) -> DispatchWallTime {
        let seconds = date.timeIntervalSince1970
        let whole = seconds.rounded(.down)
        return DispatchWallTime(timespec: timespec(tv_sec: Int(whole), tv_nsec: Int((seconds - whole) * 1_000_000_000)))
    }
}
