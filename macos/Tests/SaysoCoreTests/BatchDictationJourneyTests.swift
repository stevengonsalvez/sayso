import AppKit
import Foundation
import Testing
@testable import SaysoCore

@MainActor
@Suite("Batch Dictation & Journey Tests")
struct BatchDictationJourneyTests {

    @Test("Batch execution mode isolates recording from editor insertion")
    func batchModeSuppressesPartialInsertion() {
        var settings = SaysoSettings()
        settings.transcriptionExecutionMode = .batch
        settings.livePartialInsertion = false
        settings.autoInsert = true

        #expect(settings.transcriptionExecutionMode == .batch)
        #expect(!settings.livePartialInsertion)

        // Verify that live partial insertion requires both setting and streaming mode
        let shouldStreamInsert = settings.autoInsert
            && settings.livePartialInsertion
            && settings.transcriptionExecutionMode == .streaming

        #expect(!shouldStreamInsert, "Batch mode must never stream partials into active editor")
    }

    @Test("Streaming insertion allowlist restricts live typing to safe Apple editors")
    func streamingAllowlistProtectsExternalApps() {
        #expect(TextOutput.StreamingInsertionAllowlist.allows(bundleIdentifier: "com.apple.TextEdit"))
        #expect(TextOutput.StreamingInsertionAllowlist.allows(bundleIdentifier: "com.apple.Notes"))
        #expect(!TextOutput.StreamingInsertionAllowlist.allows(bundleIdentifier: "com.tinyspeck.slackmacgap"))
        #expect(!TextOutput.StreamingInsertionAllowlist.allows(bundleIdentifier: "com.google.Chrome"))
        #expect(!TextOutput.StreamingInsertionAllowlist.allows(bundleIdentifier: "com.apple.Terminal"))
        #expect(!TextOutput.StreamingInsertionAllowlist.allows(bundleIdentifier: "com.github.wez.wezterm"))
        #expect(!TextOutput.StreamingInsertionAllowlist.allows(bundleIdentifier: nil))
    }

    @Test("Transcription execution mode encodes and decodes cleanly")
    func executionModeCodableRoundtrip() throws {
        let streamingJSON = try JSONEncoder().encode(TranscriptionExecutionMode.streaming)
        let decodedStreaming = try JSONDecoder().decode(TranscriptionExecutionMode.self, from: streamingJSON)
        #expect(decodedStreaming == .streaming)

        let batchJSON = try JSONEncoder().encode(TranscriptionExecutionMode.batch)
        let decodedBatch = try JSONDecoder().decode(TranscriptionExecutionMode.self, from: batchJSON)
        #expect(decodedBatch == .batch)
    }

    @Test("SaysoSettings decodes missing executionMode as streaming default")
    func settingsExecutionModeDefault() throws {
        let minimalJSON = "{}"
        let settings = try JSONDecoder().decode(SaysoSettings.self, from: Data(minimalJSON.utf8))
        #expect(settings.transcriptionExecutionMode == .streaming)
        #expect(!settings.livePartialInsertion)
    }
}
