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
