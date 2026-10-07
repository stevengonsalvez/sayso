import Foundation
import Testing
@testable import SaysoCore

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@Test func schedulerAcceptsDatesThatAreNotFiniteOrAreAbsurdlyFarAwayWithoutTrapping() {
    let scheduler = SaysoDispatchScheduler(queue: DispatchQueue(label: "test.scheduler.range"))
    let fired = Counter()
    for date in [Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity),
                 Date(timeIntervalSince1970: -.infinity), Date(timeIntervalSince1970: 1e30),
                 Date(timeIntervalSince1970: -1e30)] {
        let job = scheduler.schedule(at: date) { fired.bump() }
        job.cancel()
    }
    #expect(fired.count == 0)
}
