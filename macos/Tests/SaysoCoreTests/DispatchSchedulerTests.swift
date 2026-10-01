import Foundation
import Testing
@testable import SaysoCore

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private func waitUntil(_ timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Test func dispatchSchedulerRunsOnceAtTheDateAndNeverWhenCancelled() async {
    let scheduler = SaysoDispatchScheduler()
    let fired = Counter(), cancelled = Counter()

    _ = scheduler.schedule(at: Date().addingTimeInterval(0.05)) { fired.bump() }
    let job = scheduler.schedule(at: Date().addingTimeInterval(0.05)) { cancelled.bump() }
    job.cancel()

    #expect(await waitUntil { fired.count == 1 })
    try? await Task.sleep(for: .milliseconds(150))
    #expect(fired.count == 1)
    #expect(cancelled.count == 0)
}

@Test func dispatchSchedulerRunsPastDatesPromptly() async {
    let fired = Counter()
    _ = SaysoDispatchScheduler().schedule(at: Date().addingTimeInterval(-5)) { fired.bump() }
    #expect(await waitUntil { fired.count == 1 })
}
