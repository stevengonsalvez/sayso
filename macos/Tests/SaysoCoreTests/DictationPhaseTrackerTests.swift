import Testing
@testable import SaysoCore

private func events(_ phases: [SessionPhase]) -> [DictationLifecycleEvent] {
    var tracker = DictationPhaseTracker()
    return phases.flatMap { tracker.observe($0) }
}

@Test func aNormalSessionAnnouncesListeningProcessingAndFinished() {
    #expect(events([.idle, .requestingPermission, .listening, .processing, .idle]) == [
        .listening, .processing, .ended(.finished),
    ])
}

@Test func stoppingBeforeProcessingIsACancelNotAFinish() {
    #expect(events([.listening, .idle]) == [.listening, .ended(.cancelled)])
}

@Test func failureEndsTheSessionOnceAndLaterIdleIsSilent() {
    #expect(events([.listening, .processing, .failed, .idle]) == [.listening, .processing, .ended(.failed)])
    #expect(events([.requestingPermission, .failed, .idle]) == [.ended(.failed)])
}

@Test func repeatedPhasesDoNotRepeatEventsAndIdleAtRestIsSilent() {
    #expect(events([.idle, .idle, .listening, .listening, .processing, .processing, .idle, .idle]) == [
        .listening, .processing, .ended(.finished),
    ])
}

@Test func speakingIsIgnoredAndTheNextSessionStartsFresh() {
    #expect(events([.listening, .processing, .idle, .speaking, .idle, .listening, .idle]) == [
        .listening, .processing, .ended(.finished), .listening, .ended(.cancelled),
    ])
}
