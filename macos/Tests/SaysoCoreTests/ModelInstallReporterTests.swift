import Foundation
import Testing
@testable import SaysoCore

private final class Seen: @unchecked Sendable {
    var progress: [ModelInstallProgress] = []
    var finished: [ModelInstallFinished] = []
}

private func setup() -> (ModelInstallReporter, Seen) {
    let bus = SaysoEventBus(), seen = Seen()
    _ = bus.subscribe(ModelInstallProgress.self) { seen.progress.append($0) }
    _ = bus.subscribe(ModelInstallFinished.self) { seen.finished.append($0) }
    return (ModelInstallReporter(bus: bus), seen)
}

@Test func installingReportsDistinctProgressOnly() {
    let (reporter, seen) = setup()
    reporter.observe(modelID: "m", displayName: "M", phase: .installing, fraction: 0.1)
    reporter.observe(modelID: "m", displayName: "M", phase: .installing, fraction: 0.1)
    reporter.observe(modelID: "m", displayName: "M", phase: .installing, fraction: 0.4)
    #expect(seen.progress.map(\.fraction) == [0.1, 0.4])
}

@Test func finishingReportsOnceAndOnlyAfterAnInstallWasObserved() {
    let (reporter, seen) = setup()
    reporter.observe(modelID: "m", displayName: "M", phase: .installed, fraction: 1)
    #expect(seen.finished.isEmpty)

    reporter.observe(modelID: "m", displayName: "M", phase: .installing, fraction: 0.5)
    reporter.observe(modelID: "m", displayName: "M", phase: .installed, fraction: 1)
    reporter.observe(modelID: "m", displayName: "M", phase: .installed, fraction: 1)
    #expect(seen.finished == [ModelInstallFinished(modelID: "m", displayName: "M", succeeded: true)])
}

@Test func failureAfterInstallingReportsFailedAndAFreshInstallStartsOver() {
    let (reporter, seen) = setup()
    reporter.observe(modelID: "m", displayName: "M", phase: .installing, fraction: 0.2)
    reporter.observe(modelID: "m", displayName: "M", phase: .failed, fraction: 0.2)
    #expect(seen.finished == [ModelInstallFinished(modelID: "m", displayName: "M", succeeded: false)])

    reporter.observe(modelID: "m", displayName: "M", phase: .installing, fraction: 0.2)
    #expect(seen.progress.map(\.fraction) == [0.2, 0.2])
}
