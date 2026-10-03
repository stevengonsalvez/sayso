import Foundation
import Testing
@testable import SaysoCore

private let t = Date(timeIntervalSince1970: 100)

@Test func newestFirstAndRecopyingMovesAnExistingEntryToTheFront() {
    var history = ClipboardHistory(limit: 40)
    history.add("a", at: t)
    history.add("b", at: t)
    history.add("a", at: t.addingTimeInterval(5))
    #expect(history.entries.map(\.text) == ["a", "b"])
    #expect(history.entries.first?.copiedAt == t.addingTimeInterval(5))
}

@Test func limitDropsTheOldestAndAcceptsOnlyTheSupportedSizes() {
    var history = ClipboardHistory(limit: 40)
    for n in 0..<45 { history.add("item \(n)", at: t) }
    #expect(history.entries.count == 40)
    #expect(history.entries.first?.text == "item 44")
    #expect(history.entries.last?.text == "item 5")

    history.setLimit(100)
    #expect(history.limit == 100)
    history.setLimit(7)
    #expect(history.limit == 100)

    history.setLimit(40)
    #expect(history.entries.count == 40)
    history.add("x", at: t)
    history.setLimit(40)
    #expect(history.entries.count == 40)
}

@Test func removeAndClearWorkAndShrinkingTheLimitTrims() {
    var history = ClipboardHistory(limit: 100)
    for n in 0..<60 { history.add("i\(n)", at: t) }
    history.setLimit(40)
    #expect(history.entries.count == 40)

    let id = history.entries[3].id
    history.remove(id: id)
    #expect(history.entries.count == 39)
    #expect(!history.entries.contains { $0.id == id })

    history.clear()
    #expect(history.entries.isEmpty)
}

@Test func blankTextIsIgnored() {
    var history = ClipboardHistory(limit: 40)
    history.add("   ", at: t)
    history.add("", at: t)
    #expect(history.entries.isEmpty)
}
