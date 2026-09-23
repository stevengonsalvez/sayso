import Foundation
import Testing
@testable import SaysoCore

@Test func recordingSessionRetainsDeliveryEvidence() async {
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = RecordingSessionStore(fileURL: fileURL)
    var session = RecordingSession(
        language: .english,
        route: .local,
        destination: .init(processIdentifier: 42, applicationName: "TextEdit", fieldRole: "AXTextArea", windowTitle: "Draft")
    )
    session.transition(to: .listening)
    session.complete(text: "hello", delivery: .directInsertion)
    await store.upsert(session)

    let saved = await store.all()
    #expect(saved == [session])
    #expect(saved.first?.phase == .delivered)
    #expect(saved.first?.destination?.applicationName == "TextEdit")
}

@Test func recordingSessionTracksClipboardFallback() {
    var session = RecordingSession(language: .english, route: .local, destination: nil)
    session.complete(text: "hello", delivery: .clipboard)
    #expect(session.phase == .copiedToClipboard)
}

@Test func recordingSessionTracksAppliedVoiceEdit() {
    var session = RecordingSession(language: .english, route: .local, destination: nil)
    session.completeVoiceEdit("rewritten text")

    #expect(session.phase == .edited)
    #expect(session.finalText == "rewritten text")
    #expect(session.delivery == nil)
}

@Test func recordingSessionTracksHandedOffControlCommand() {
    var session = RecordingSession(language: .english, route: .local, destination: nil)
    session.completeControlCommand("scroll down")

    #expect(session.phase == .handedToControl)
    #expect(session.finalText == "scroll down")
}

@Test func capturedSessionCompletionDoesNotOverwriteAnotherSession() async {
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = RecordingSessionStore(fileURL: fileURL)
    var captured = RecordingSession(language: .english, route: .local, destination: nil)
    var current = RecordingSession(language: .hindi, route: .local, destination: nil)
    captured.transition(to: .processing)
    current.transition(to: .listening)
    await store.upsert(captured)
    await store.upsert(current)

    captured.complete(text: "first transcript", delivery: .clipboard)
    await store.upsert(captured)

    let saved = await store.all()
    #expect(saved.first(where: { $0.id == captured.id })?.phase == .copiedToClipboard)
    #expect(saved.first(where: { $0.id == current.id })?.phase == .listening)
    #expect(saved.first(where: { $0.id == current.id })?.language == .hindi)
}

@Test func recordingSessionTracksCancelledCapture() {
    var session = RecordingSession(language: .english, route: .local, destination: nil)
    session.transition(to: .listening)
    session.transition(to: .cancelled)

    #expect(session.phase == .cancelled)
    #expect(session.finalText == nil)
    #expect(session.delivery == nil)
}
