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
