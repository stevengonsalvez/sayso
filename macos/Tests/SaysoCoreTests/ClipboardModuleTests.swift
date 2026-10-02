import Foundation
import Testing
@testable import SaysoCore

private func rep(_ type: String, _ data: Data) -> ClipboardRepresentation { ClipboardRepresentation(type: type, data: data) }
private let plainType = "public.utf8-plain-text"

private final class FakePort: ClipboardPort, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var items: [[ClipboardRepresentation]] = []
    var writes: [(text: String, concealed: Bool)] = []
    var restores = 0
    var clears = 0
    var sourceBundleID = "com.apple.Safari"

    var changeCount: Int { lock.withLock { count } }
    var currentItems: [[ClipboardRepresentation]] { lock.withLock { items } }

    func snapshot() -> ClipboardSnapshot {
        lock.withLock {
            let types = Set(items.flatMap { $0.map(\.type) })
            let text = items.first?.first { $0.type == plainType }.flatMap { String(data: $0.data, encoding: .utf8) }
            return ClipboardSnapshot(changeCount: count, types: types, text: text, sourceApp: "Safari", sourceBundleID: sourceBundleID)
        }
    }
    func captureContents() -> ClipboardContents { lock.withLock { ClipboardContents(changeCount: count, items: items) } }
    func restore(_ contents: ClipboardContents) -> Bool {
        lock.withLock { count += 1; items = contents.items; restores += 1 }
        return true
    }
    func clear() { lock.withLock { count += 1; items = []; clears += 1 } }
    func write(text newText: String, concealed: Bool) -> Bool {
        lock.withLock {
            count += 1
            var item = [rep(plainType, Data(newText.utf8))]
            if concealed { item.append(rep("org.nspasteboard.ConcealedType", Data())) }
            items = [item]
            writes.append((newText, concealed))
        }
        return true
    }
    /// Another app copies text with extra marker types.
    func copy(_ newText: String, types newTypes: Set<String> = [plainType]) {
        lock.withLock {
            count += 1
            items = [newTypes.sorted().map { $0 == plainType ? rep($0, Data(newText.utf8)) : rep($0, Data()) }]
        }
    }
    /// Another app copies arbitrary items (images, files, rich text).
    func copyItems(_ newItems: [[ClipboardRepresentation]]) { lock.withLock { count += 1; items = newItems } }
}

private final class FakeScheduler: SaysoScheduling, @unchecked Sendable {
    struct Job { let id: Int; let at: Date; let action: @Sendable () -> Void }
    private let lock = NSLock()
    private var nextID = 0
    var jobs: [Job] = []
    func schedule(at date: Date, _ action: @escaping @Sendable () -> Void) -> SaysoSubscription {
        let id = lock.withLock { () -> Int in nextID += 1; jobs.append(Job(id: nextID, at: date, action: action)); return nextID }
        return SaysoSubscription { [weak self] in self?.lock.withLock { self?.jobs.removeAll { $0.id == id } } }
    }
    func firePending() {
        let job = lock.withLock { jobs.isEmpty ? nil : jobs.removeFirst() }
        job?.action()
    }
}

private final class Sink: @unchecked Sendable { var recorded: [ClipboardItemRecorded] = [] }

private func setup() -> (SaysoModuleHost, ClipboardModule, FakePort, FakeScheduler, SaysoEventBus, Sink) {
    let port = FakePort(), scheduler = FakeScheduler(), bus = SaysoEventBus(), sink = Sink()
    _ = bus.subscribe(ClipboardItemRecorded.self) { sink.recorded.append($0) }
    let module = ClipboardModule(port: port, scheduler: scheduler)
    let host = SaysoModuleHost(modules: [module], events: bus)
    host.enable("clipboard")
    return (host, module, port, scheduler, bus, sink)
}

@Test func pollingRecordsNewCopiesOnceAnnouncesThemAndSkipsUnchangedPolls() {
    let (_, module, port, scheduler, _, sink) = setup()
    #expect(scheduler.jobs.count == 1)

    port.copy("first")
    scheduler.firePending()
    scheduler.firePending()
    port.copy("second")
    scheduler.firePending()

    #expect(module.entries.map(\.text) == ["second", "first"])
    #expect(sink.recorded.map(\.text) == ["first", "second"])
    #expect(scheduler.jobs.count == 1)
}

@Test func concealedAndTransientCopiesNeverReachHistoryOrEvents() {
    let (_, module, port, scheduler, _, sink) = setup()
    port.copy("hunter2", types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"])
    scheduler.firePending()
    port.copy("token", types: ["public.utf8-plain-text", "org.nspasteboard.TransientType"])
    scheduler.firePending()

    #expect(module.entries.isEmpty)
    #expect(sink.recorded.isEmpty)
}

@Test func contentAlreadyOnTheClipboardWhenEnabledIsNotRecorded() {
    let port = FakePort(), scheduler = FakeScheduler()
    port.copy("old secret-ish thing")
    let module = ClipboardModule(port: port, scheduler: scheduler)
    let host = SaysoModuleHost(modules: [module])
    host.enable("clipboard")
    scheduler.firePending()
    #expect(module.entries.isEmpty)
}

@Test func copiedTrackingLinkOffersACleanActionThatWritesTheCleanedLink() {
    let (host, module, port, scheduler, _, _) = setup()
    port.copy("https://example.com/p?id=7&utm_source=news")
    scheduler.firePending()

    let offer = host.engine.stack.first
    #expect(offer?.title == "Clean link")
    #expect(offer?.actions.map(\.id) == ["clean"])
    #expect(offer?.expiresAfter != nil)

    #expect(host.perform(actionID: "clean", stackID: "clean-link", moduleID: "clipboard"))
    #expect(port.writes.last?.text == "https://example.com/p?id=7")
    #expect(port.writes.last?.concealed == false)
    #expect(module.entries.first?.text == "https://example.com/p?id=7")
    scheduler.firePending()
    #expect(module.entries.count == 2)
    #expect(host.engine.stack.isEmpty)
}

@Test func copyBackWritesPlainTextWithoutRecordingItAgain() {
    let (_, module, port, scheduler, _, _) = setup()
    port.copy("keep me")
    scheduler.firePending()
    port.copy("newer")
    scheduler.firePending()
    let id = module.entries.last!.id

    #expect(module.copyBack(id: id))
    #expect(port.writes.last?.text == "keep me")
    scheduler.firePending()
    #expect(module.entries.map(\.text) == ["keep me", "newer"])
    #expect(!module.copyBack(id: UUID()))
}

@Test func pastingTemporaryTextRestoresTheExactPreviousContentsOnlyAfterSuccessAndOnlyIfUntouched() {
    let (_, module, port, scheduler, _, _) = setup()
    port.copy("previous")
    scheduler.firePending()
    let before = port.currentItems

    var pasted: [String?] = []
    #expect(module.pasteTemporarily("dictated") { pasted.append(port.snapshot().text); return true })
    #expect(pasted == ["dictated"])
    #expect(port.currentItems == before)
    scheduler.firePending()
    #expect(module.entries.map(\.text) == ["previous"])

    #expect(!module.pasteTemporarily("dictated again") { false })
    #expect(port.snapshot().text == "dictated again")

    port.copy("previous")
    #expect(module.pasteTemporarily("x") { port.copy("user copied meanwhile"); return true })
    #expect(port.snapshot().text == "user copied meanwhile")
}

@Test func imagesFilesAndRichTextOnTheClipboardComeBackVerbatimAfterADictationPaste() {
    let (_, module, port, _, _, _) = setup()
    let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
    let rtf = Data("{\\rtf1 hi}".utf8)
    let mixed: [[ClipboardRepresentation]] = [
        [rep("public.png", png), rep("public.tiff", Data([9, 9]))],
        [rep("public.file-url", Data("file:///tmp/a.txt".utf8))],
        [rep("public.rtf", rtf), rep(plainType, Data("hi".utf8))],
    ]
    port.copyItems(mixed)

    #expect(module.pasteTemporarily("dictated") { true })
    #expect(port.currentItems == mixed)
    #expect(port.restores == 1)
}

@Test func anEmptyClipboardIsLeftEmptyAfterTheDictationPaste() {
    let (_, module, port, _, _, _) = setup()
    #expect(module.pasteTemporarily("dictated") { true })
    #expect(port.currentItems.isEmpty)
    #expect(port.snapshot().text == nil)
}

@Test func aSensitivePreviousItemIsClearedNotRestored() {
    for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword"] {
        let (_, module, port, _, _, _) = setup()
        port.copy("p4ss", types: [plainType, marker])
        #expect(module.pasteTemporarily("dictated") { true })
        #expect(port.currentItems.isEmpty)
        #expect(port.restores == 0)
        #expect(port.clears == 1)
    }
}

@Test func disablingStopsPollingAndClearingEmptiesHistory() {
    let (host, module, port, scheduler, _, _) = setup()
    port.copy("a")
    scheduler.firePending()
    module.clearHistory()
    #expect(module.entries.isEmpty)

    host.disable("clipboard")
    #expect(scheduler.jobs.isEmpty)
    port.copy("b")
    #expect(module.entries.isEmpty)
}

@Test func clipboardModulePassesTheGenericAcceptanceHarness() {
    #expect(SaysoModuleAcceptance.violations(for: ClipboardModule(port: FakePort(), scheduler: FakeScheduler())) == [])
}

@Test func afterDisableCopyBackAndTemporaryPasteDoNothingAndNeverTouchTheClipboard() {
    let (host, module, port, scheduler, _, _) = setup()
    port.copy("a")
    scheduler.firePending()
    let id = module.entries[0].id
    let writesBefore = port.writes.count

    host.disable("clipboard")
    #expect(!module.copyBack(id: id))
    var ran = false
    #expect(!module.pasteTemporarily("x") { ran = true; return true })
    #expect(!ran)
    #expect(port.writes.count == writesBefore)
}

@Test func theCleanOfferDiesWhenSomethingElseIsCopiedAndALateCleanNeverOverwritesIt() {
    let (host, _, port, scheduler, _, _) = setup()
    port.copy("https://example.com/p?utm_source=a")
    scheduler.firePending()
    #expect(host.engine.stack.contains { $0.stackID == "clean-link" })

    port.copy("foo")
    // Before the next poll runs the offer is still painted, but its action must already be refused.
    _ = host.perform(actionID: "clean", stackID: "clean-link", moduleID: "clipboard")
    #expect(port.writes.isEmpty)
    #expect(port.snapshot().text == "foo")

    scheduler.firePending()
    #expect(!host.engine.stack.contains { $0.stackID == "clean-link" })
}

@Test func enableDisableEnableKeepsOnePollChainAndRecordsCopies() {
    let (host, module, port, scheduler, _, _) = setup()
    host.disable("clipboard")
    host.enable("clipboard")
    #expect(scheduler.jobs.count == 1)

    port.copy("after cycle")
    scheduler.firePending()
    #expect(module.entries.map(\.text) == ["after cycle"])
    #expect(scheduler.jobs.count == 1)
}

@Test func aCopyMadeJustBeforeOurOwnWriteIsStillRecorded() {
    let (_, module, port, scheduler, _, _) = setup()
    port.copy("first")
    scheduler.firePending()
    port.copy("copied a moment ago")
    let id = module.entries[0].id

    #expect(module.copyBack(id: id))
    #expect(module.entries.map(\.text).contains("copied a moment ago"))
}

@Test func oversizedAndPasswordManagerCopiesAreNeverRecordedOrAnnounced() {
    let (_, module, port, scheduler, _, sink) = setup()
    port.copy(String(repeating: "a", count: ClipboardPrivacy.maximumRecordedBytes + 1))
    scheduler.firePending()
    port.sourceBundleID = "com.bitwarden.desktop"
    port.copy("hunter2")
    scheduler.firePending()
    #expect(module.entries.isEmpty)
    #expect(sink.recorded.isEmpty)
}
