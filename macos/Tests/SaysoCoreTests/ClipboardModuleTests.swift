import Foundation
import Testing
@testable import SaysoCore

private final class FakePort: ClipboardPort, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var types: Set<String> = []
    private var text: String?
    var writes: [(text: String, concealed: Bool)] = []

    var changeCount: Int { lock.withLock { count } }
    func snapshot() -> ClipboardSnapshot {
        lock.withLock { ClipboardSnapshot(changeCount: count, types: types, text: text, sourceApp: "Safari") }
    }
    func write(text newText: String, concealed: Bool) -> Bool {
        lock.withLock {
            count += 1
            text = newText
            types = concealed ? ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"] : ["public.utf8-plain-text"]
            writes.append((newText, concealed))
        }
        return true
    }
    /// Another app copies something.
    func copy(_ newText: String, types newTypes: Set<String> = ["public.utf8-plain-text"]) {
        lock.withLock { count += 1; text = newText; types = newTypes }
    }
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

@Test func pastingTemporaryTextRestoresThePreviousClipboardOnlyAfterSuccessAndOnlyIfUntouched() {
    let (_, module, port, scheduler, _, _) = setup()
    port.copy("previous")
    scheduler.firePending()

    var pasted: [String?] = []
    #expect(module.pasteTemporarily("dictated") { pasted.append(port.snapshot().text); return true })
    #expect(pasted == ["dictated"])
    #expect(port.snapshot().text == "previous")
    scheduler.firePending()
    #expect(module.entries.map(\.text) == ["previous"])

    #expect(!module.pasteTemporarily("dictated again") { false })
    #expect(port.snapshot().text == "dictated again")

    port.copy("previous")
    #expect(module.pasteTemporarily("x") { port.copy("user copied meanwhile"); return true })
    #expect(port.snapshot().text == "user copied meanwhile")
}

@Test func restoringAConcealedPreviousItemKeepsItConcealed() {
    let (_, module, port, scheduler, _, _) = setup()
    port.copy("p4ss", types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"])
    scheduler.firePending()
    #expect(module.pasteTemporarily("dictated") { true })
    #expect(port.writes.last?.text == "p4ss")
    #expect(port.writes.last?.concealed == true)
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
