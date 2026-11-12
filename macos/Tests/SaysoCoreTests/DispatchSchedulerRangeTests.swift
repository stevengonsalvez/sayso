import Foundation
import Testing
@testable import SaysoCore

private final class TestModuleContextHolder: @unchecked Sendable {
    var context: SaysoModuleContext?
}

private final class TestRuntime: SaysoModuleRuntime, @unchecked Sendable {
    func start() {}
    func stop() {}
}

private struct TestModule: SaysoModule {
    let holder: TestModuleContextHolder
    let descriptor = SaysoModuleDescriptor(id: "test", title: "Test")
    func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        holder.context = context
        return TestRuntime()
    }
}

@Test func pastAndNaNDispatchSchedulerDatesFirePromptly() async {
    let pastDates: [Double] = [.nan, -.infinity, -1e30, -0.0, 0, 1]
    for raw in pastDates {
        let scheduler = SaysoDispatchScheduler(queue: DispatchQueue(label: "test.scheduler.range.past"))
        let fired = Counter()
        let job = scheduler.schedule(at: Date(timeIntervalSince1970: raw)) { fired.bump() }
        #expect(await waitUntil(2) { fired.count == 1 })
        job.cancel()
    }
}

@Test func futureAndInfiniteDispatchSchedulerDatesDoNotFirePromptly() async {
    let futureDates: [Double] = [.infinity, 1e30, 4_102_444_800, 4_102_444_801]
    for raw in futureDates {
        let scheduler = SaysoDispatchScheduler(queue: DispatchQueue(label: "test.scheduler.range.future"))
        let fired = Counter()
        let job = scheduler.schedule(at: Date(timeIntervalSince1970: raw)) { fired.bump() }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(fired.count == 0)
        job.cancel()
    }
}

@Test func activityInitSanitizesNaNExpiresAfterToNil() {
    let activity = SaysoActivity(
        moduleID: "test",
        stackID: "test",
        kind: .completion,
        title: "Test",
        expiresAfter: .nan
    )
    #expect(activity.expiresAfter == nil)
}

@Test func tickerWithNegativeInfinityExpiresAfterStillAllowsNormalActivityToExpire() async {
    let holder = TestModuleContextHolder()
    let host = SaysoModuleHost(modules: [TestModule(holder: holder)])
    let scheduler = SaysoDispatchScheduler(queue: DispatchQueue(label: "test.scheduler.range.ticker"))
    let ticker = SaysoExpiryTicker(host: host, scheduler: scheduler)
    _ = ticker
    host.enable("test")

    guard let context = holder.context else {
        Issue.record("Context missing")
        return
    }

    context.publish(stackID: "inf", kind: .completion, title: "Negative Infinity", expiresAfter: -.infinity)
    context.publish(stackID: "normal", kind: .completion, title: "Normal", expiresAfter: 0.05)

    #expect(host.engine.stack.count == 2)
    #expect(await waitUntil(2) { host.engine.stack.isEmpty })
}
