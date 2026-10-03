import Foundation

/// Production scheduler: one DispatchSourceTimer per job, none while idle.
public struct SaysoDispatchScheduler: SaysoScheduling {
    private let queue: DispatchQueue

    public init(queue: DispatchQueue = .main) { self.queue = queue }

    public func schedule(at date: Date, _ action: @escaping @Sendable () -> Void) -> SaysoSubscription {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + max(0, date.timeIntervalSinceNow), leeway: .milliseconds(10))
        timer.setEventHandler {
            action()
            timer.cancel()
        }
        timer.resume()
        return SaysoSubscription { timer.cancel() }
    }
}
