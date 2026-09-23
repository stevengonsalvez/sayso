import Foundation
import Testing
@testable import SaysoCore

@Test func historySearchMatchesTranscriptTranslationLanguageAndRoute() async {
    let store = HistoryStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let localHindi = Transcript(text: "Meeting with Alice", translatedText: "ऐलिस से बैठक", language: .hindi, route: .local, isFinal: true)
    let appleEnglish = Transcript(text: "Buy groceries", language: .english, route: .appleSpeech, isFinal: true)
    await store.append(localHindi)
    await store.append(appleEnglish)

    #expect(await store.matching("ALICE").map(\.id) == [localHindi.id])
    #expect(await store.matching("ऐलिस").map(\.id) == [localHindi.id])
    #expect(await store.matching("Hindi").map(\.id) == [localHindi.id])
    #expect(await store.matching("Apple Speech").map(\.id) == [appleEnglish.id])
    #expect(await store.matching("   ").map(\.id) == [appleEnglish.id, localHindi.id])
}

@Test func historyRemovalDeletesOnlyTheRequestedEntryAndPersists() async {
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = HistoryStore(fileURL: fileURL)
    let first = Transcript(text: "First", language: .english, route: .local, isFinal: true)
    let second = Transcript(text: "Second", language: .hindi, route: .appleSpeech, isFinal: true)
    await store.append(first)
    await store.append(second)

    #expect(await store.remove(id: first.id))
    #expect(await store.all().map(\.id) == [second.id])
    #expect(await HistoryStore(fileURL: fileURL).all().map(\.id) == [second.id])
    #expect(!(await store.remove(id: first.id)))
}

@Test func historyScopesFilterRouteTranslationAndRecordings() {
    let onDeviceRecording = Transcript(
        text: "Local",
        language: .english,
        route: .local,
        isFinal: true,
        audioFileURL: URL(fileURLWithPath: "/tmp/Recording-a.m4a")
    )
    let translated = Transcript(
        text: "Original",
        translatedText: "अनुवाद",
        language: .hindi,
        route: .appleSpeech,
        isFinal: true
    )
    let provider = Transcript(text: "Provider", language: .english, route: .byok, isFinal: true)
    let emptyTranslation = Transcript(
        text: "Fallback",
        translatedText: "   ",
        language: .english,
        route: .local,
        isFinal: true
    )
    let entries = [onDeviceRecording, translated, provider, emptyTranslation]

    #expect(HistoryFilter.matching(entries, query: "", scope: .all).map(\.id) == entries.map(\.id))
    #expect(HistoryFilter.matching(entries, query: "", scope: .onDevice).map(\.id) == [onDeviceRecording.id, emptyTranslation.id])
    #expect(HistoryFilter.matching(entries, query: "", scope: .appleSpeech).map(\.id) == [translated.id])
    #expect(HistoryFilter.matching(entries, query: "", scope: .yourProvider).map(\.id) == [provider.id])
    #expect(HistoryFilter.matching(entries, query: "", scope: .translated).map(\.id) == [translated.id])
    #expect(HistoryFilter.matching(entries, query: "", scope: .recordings, availableRecordingIDs: [onDeviceRecording.id]).map(\.id) == [onDeviceRecording.id])
    #expect(HistoryFilter.matching(entries, query: "Local", scope: .appleSpeech).isEmpty)
    #expect(HistoryFilter.matching(entries, query: "अनुवाद", scope: .translated).map(\.id) == [translated.id])
    #expect(translated.displayText == "अनुवाद")
    #expect(!emptyTranslation.hasTranslation)
    #expect(emptyTranslation.displayText == "Fallback")
}

@Test func historyReplaysJournalAfterSnapshotWriteFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fileURL = root.appendingPathComponent("history.json")
    let saved = Transcript(text: "Saved", language: .english, route: .local, isFinal: true)
    let pending = Transcript(text: "Pending", language: .english, route: .local, isFinal: true)

    #expect(await HistoryStore(fileURL: fileURL).append(saved))
    let failingStore = HistoryStore(fileURL: fileURL, persistEntries: { _, _ in false })
    #expect(await failingStore.append(pending))
    #expect(FileManager.default.fileExists(atPath: fileURL.appendingPathExtension("wal").path))

    let recoveredStore = HistoryStore(fileURL: fileURL)
    #expect(await recoveredStore.all().map(\.id) == [pending.id, saved.id])
    #expect(!FileManager.default.fileExists(atPath: fileURL.appendingPathExtension("wal").path))
}

@Test func historyKeepsMoreThanFiveHundredEntriesWhenUnbounded() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fileURL = root.appendingPathComponent("history.json")
    let store = HistoryStore(fileURL: fileURL, maximumEntries: nil)

    for index in 0...500 {
        #expect(await store.append(.init(text: "Entry \(index)", language: .english, route: .local, isFinal: true)))
    }

    #expect(await store.all().count == 501)
}
