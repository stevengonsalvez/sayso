import AppKit
import Foundation
import Testing
@testable import SaysoCore

/// 2026-10-10 14:05 in UTC.
private func tenPastTwo() throws -> Date { try #require(ISO8601DateFormatter().date(from: "2026-10-10T14:05:00Z")) }

private func expander(_ locale: String = "en_GB", zone: String = "UTC") throws -> SnippetsExpander {
    SnippetsExpander(locale: Locale(identifier: locale), timeZone: try #require(TimeZone(identifier: zone)))
}

/// Counts reads so a test can prove the clipboard was read only when, and as often as, it should be.
private final class CountingClipboard: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let text: String?
    init(_ text: String?) { self.text = text }
    var reads: Int { lock.withLock { count } }
    func read() -> String? { lock.withLock { count += 1 }; return text }
}

@Suite struct SnippetsExpanderTests {
    @Test func dateAndTimeComeFromTheInjectedClockInTheInjectedLocaleAndZone() throws {
        let now = try tenPastTwo()
        let none: () -> String? = { nil }
        #expect(try expander().expand("On {date} at {time}", at: now, clipboard: none).text == "On 10 Oct 2026 at 14:05")
        #expect(try expander("en_US").expand("{date}", at: now, clipboard: none).text == "Oct 10, 2026")
        #expect(try expander("de_DE").expand("{date} {time}", at: now, clipboard: none).text == "10.10.2026 14:05")
        #expect(try expander(zone: "Asia/Tokyo").expand("{date} {time}", at: now, clipboard: none).text == "10 Oct 2026 23:05")
        #expect(try expander().expand("{DATE} {Time}", at: now, clipboard: none).text == "10 Oct 2026 14:05", "names ignore case")
    }

    @Test func theClipboardIsReadOnceAndOnlyWhenTheBodyAsksForIt() throws {
        let now = try tenPastTwo()
        let plain = CountingClipboard("pasted")
        #expect(try expander().expand("No placeholder, {date}", at: now, clipboard: plain.read).text == "No placeholder, 10 Oct 2026")
        #expect(plain.reads == 0, "no {clipboard}, no read")

        let twice = CountingClipboard("pasted")
        let expansion = try expander().expand("{clipboard} and {clipboard}", at: now, clipboard: twice.read)
        #expect(expansion.text == "pasted and pasted")
        #expect(expansion.warnings.isEmpty)
        #expect(twice.reads == 1, "read once, however often it appears")
    }

    @Test func clipboardTextIsInsertedAsItIsAndNeverExpandedAgain() throws {
        let board = CountingClipboard("{date} and {foo}")
        let expansion = try expander().expand("Got: {clipboard}", at: try tenPastTwo(), clipboard: board.read)
        #expect(expansion.text == "Got: {date} and {foo}")
        #expect(expansion.warnings.isEmpty, "the clipboard's own braces are not the snippet's placeholders")
    }

    @Test func anUnknownPlaceholderIsLeftAsTypedAndWarnedOnceNotRefused() throws {
        let body = "Hi {foo}, {foo} and {Bar_2} on {date}"
        let expansion = try expander().expand(body, at: try tenPastTwo(), clipboard: { nil })
        #expect(expansion.text == "Hi {foo}, {foo} and {Bar_2} on 10 Oct 2026")
        #expect(expansion.warnings == [.unknownPlaceholder("{foo}"), .unknownPlaceholder("{Bar_2}")])
        #expect(SnippetsWarning.unknownPlaceholder("{foo}").message == "{foo} is not a placeholder, so it was left as typed.")
        #expect(SnippetsExpander.warnings(in: body) == expansion.warnings, "the same warnings without expanding anything")
    }

    @Test func bracesThatAreNotPlaceholderShapedAreLeftAloneWithoutAWarning() throws {
        let body = #"{} { date } {"a": 1} {0} {date"#
        let expansion = try expander().expand(body, at: try tenPastTwo(), clipboard: { nil })
        #expect(expansion.text == body)
        #expect(expansion.warnings.isEmpty)
    }

    @Test func theExpansionSaysWhetherClipboardTextWasInserted() throws {
        let now = try tenPastTwo()
        let board = CountingClipboard("pasted")
        #expect(try expander().expand("Got {clipboard}", at: now, clipboard: board.read).usedClipboard)
        #expect(try expander().expand("Plain {date}", at: now, clipboard: board.read).usedClipboard == false)
        #expect(try expander().expand("Got {clipboard}", at: now, clipboard: { nil }).usedClipboard == false, "nothing was inserted")
        #expect(try expander().expand("Got {clipboard}", at: now, clipboard: { "" }).usedClipboard == false, "nothing was inserted")
    }

    /// 900 `{clipboard}` fit in a 10,000 character body, so a big clipboard multiplies into a huge result.
    @Test func anExpansionOverTheLimitIsRefusedBeforeItIsBuilt() throws {
        let now = try tenPastTwo()
        let body = String(repeating: "{clipboard}", count: 900)
        let huge = CountingClipboard(String(repeating: "a", count: 1_000_000))
        #expect(throws: SnippetsError.expansionTooLong) {
            try expander().expand(body, at: now, clipboard: huge.read)
        }
        #expect(SnippetsModule.expansionLimit == ClipboardPrivacy.maximumRecordedBytes, "the most the Clipboard module records")
    }

    @Test func theLimitCountsUTF8BytesAndTheExactLimitStillPasses() throws {
        let now = try tenPastTwo()
        #expect(try expander().expand("ab{clipboard}", at: now, limit: 5, clipboard: { "cde" }).text == "abcde")
        #expect(throws: SnippetsError.expansionTooLong) {
            try expander().expand("ab{clipboard}", at: now, limit: 5, clipboard: { "cdef" })
        }
        #expect(throws: SnippetsError.expansionTooLong, "two bytes each, not one character each") {
            try expander().expand("{clipboard}", at: now, limit: 5, clipboard: { "ééé" })
        }
        #expect(throws: SnippetsError.expansionTooLong, "plain text counts too") {
            try expander().expand("abcdef", at: now, limit: 5, clipboard: { nil })
        }
    }

    @Test func aClipboardWithNoTextLeavesThePlaceholderEmptyAndWarns() throws {
        let expansion = try expander().expand("Thanks, {clipboard}!", at: try tenPastTwo(), clipboard: { nil })
        #expect(expansion.text == "Thanks, !")
        #expect(expansion.warnings == [.clipboardHasNoText])
        #expect(SnippetsWarning.clipboardHasNoText.message == "The clipboard had no text, so {clipboard} was left empty.")
        #expect(SnippetsExpander.warnings(in: "Thanks, {clipboard}!").isEmpty, "saving never looks at the clipboard")
    }
}

/// In memory, counting loads and saves so a test can prove listing never writes.
private final class FakeSnippetsStore: SnippetsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [Snippet]
    private var loadCount = 0
    private var saveCount = 0
    init(_ snippets: [Snippet] = []) { kept = snippets }
    var stored: [Snippet] { lock.withLock { kept } }
    var loads: Int { lock.withLock { loadCount } }
    var saves: Int { lock.withLock { saveCount } }
    func load() -> [Snippet] { lock.withLock { loadCount += 1; return kept } }
    func save(_ snippets: [Snippet]) { lock.withLock { saveCount += 1; kept = snippets } }
}

/// Read side of the clipboard: counts reads, never written.
private final class FakeClipboardReader: SnippetsClipboardReading, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var current: String?
    init(_ text: String?) { current = text }
    var reads: Int { lock.withLock { count } }
    func set(_ text: String?) { lock.withLock { current = text } }
    func readText() -> String? { lock.withLock { count += 1; return current } }
}

/// Write side: records writes and whether each was marked concealed.
private final class FakeSnippetsBoard: SnippetsPasteboardWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [(text: String, concealed: Bool)] = []
    private var refusing = false
    var written: [String] { lock.withLock { log.map(\.text) } }
    var concealedFlags: [Bool] { lock.withLock { log.map(\.concealed) } }
    func refuse(_ on: Bool) { lock.withLock { refusing = on } }
    func write(_ text: String, concealed: Bool) -> Bool {
        lock.withLock {
            guard !refusing else { return false }
            log.append((text, concealed))
            return true
        }
    }
}

private final class SnippetsScheduler: SaysoScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var nextID = 0
    private var pending: [(id: Int, at: Date, action: @Sendable () -> Void)] = []
    var jobs: [Date] { lock.withLock { pending.map(\.at) } }

    func schedule(at date: Date, _ action: @escaping @Sendable () -> Void) -> SaysoSubscription {
        let id = lock.withLock { () -> Int in nextID += 1; pending.append((nextID, date, action)); return nextID }
        return SaysoSubscription { [weak self] in self?.lock.withLock { self?.pending.removeAll { $0.id == id } } }
    }

    /// The earliest pending action, left pending: lets a test run a timer callback that was already firing when its
    /// job was cancelled.
    func snatchEarliest() -> (@Sendable () -> Void)? {
        lock.withLock { pending.min(by: { $0.at < $1.at })?.action }
    }

    func runDue(_ now: Date) {
        for _ in 0..<1000 {
            let job = lock.withLock { () -> (id: Int, at: Date, action: @Sendable () -> Void)? in
                guard let index = pending.indices.filter({ pending[$0].at <= now }).min(by: { pending[$0].at < pending[$1].at })
                else { return nil }
                return pending.remove(at: index)
            }
            guard let job else { return }
            job.action()
        }
        Issue.record("jobs kept re-arming at or before now")
    }
}

private final class SnippetsClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private final class SnippetsRuntimes: @unchecked Sendable { var runtimes: [SaysoModuleRuntime] = [] }

private struct SnippetsProbe: SaysoModule {
    let inner: SnippetsModule
    let captured: SnippetsRuntimes
    var descriptor: SaysoModuleDescriptor { inner.descriptor }
    func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        let runtime = inner.makeRuntime(context: context)
        captured.runtimes.append(runtime)
        return runtime
    }
}

private struct SnippetsRig {
    let host: SaysoModuleHost
    let module: SnippetsModule
    let store: FakeSnippetsStore
    let clipboard: FakeClipboardReader
    let board: FakeSnippetsBoard
    let scheduler: SnippetsScheduler
    let clock: SnippetsClock
    let captured: SnippetsRuntimes

    func advance(_ seconds: TimeInterval) {
        clock.now += seconds
        scheduler.runDue(clock.now)
    }

    var activities: [SaysoActivity] { host.engine.stack.filter { $0.moduleID == "snippets" } }
    var retained: Int { (captured.runtimes.last as? SaysoResourceAccounting)?.retainedResources ?? -1 }
    var names: [String] { module.snippets.map(\.name) }
}

private func snippetsRig(
    _ saved: [Snippet] = [], clipboard: String? = "from the test", enabled: Bool = true
) throws -> SnippetsRig {
    let store = FakeSnippetsStore(saved), reader = FakeClipboardReader(clipboard), board = FakeSnippetsBoard()
    let scheduler = SnippetsScheduler(), clock = SnippetsClock(try tenPastTwo()), captured = SnippetsRuntimes()
    let module = SnippetsModule(
        store: store, clipboard: reader, pasteboard: board, scheduler: scheduler,
        locale: Locale(identifier: "en_GB"), timeZone: try #require(TimeZone(identifier: "UTC")), now: { clock.now }
    )
    let host = SaysoModuleHost(modules: [SnippetsProbe(inner: module, captured: captured)], now: { clock.now })
    host.setEnabled(module.descriptor.id, enabled)
    return SnippetsRig(
        host: host, module: module, store: store, clipboard: reader, board: board, scheduler: scheduler, clock: clock,
        captured: captured
    )
}

@Suite struct SnippetsModuleTests {
    @Test func passesTheModuleAcceptanceContract() {
        let module = SnippetsModule(
            store: FakeSnippetsStore([Snippet(name: "Kept", body: "text")]), clipboard: FakeClipboardReader("x"),
            pasteboard: FakeSnippetsBoard(), scheduler: SnippetsScheduler()
        )
        #expect(module.descriptor.id == "snippets")
        #expect(module.descriptor.capabilities == [.clipboard], "it reads the clipboard, but only for {clipboard} on Copy")
        #expect(SaysoModuleAcceptance.violations(for: module).isEmpty, "\(SaysoModuleAcceptance.violations(for: module))")
    }

    @Test func addingListsAndSavesTheSnippetWithoutReadingTheClipboard() throws {
        let rig = try snippetsRig()
        #expect(try rig.module.add(name: "  Sign off ", body: "Thanks, {clipboard}, {date}").get().isEmpty)
        #expect(rig.module.snippets == [Snippet(name: "Sign off", body: "Thanks, {clipboard}, {date}")], "name trimmed, body as typed")
        #expect(rig.store.stored == rig.module.snippets)
        #expect(try rig.module.add(name: "Address", body: "1 Main St").get().isEmpty)
        #expect(rig.names == ["Sign off", "Address"], "in the order added")
        #expect(rig.clipboard.reads == 0, "saving and listing never read the clipboard")
        #expect(rig.board.written.isEmpty)
        #expect(rig.activities.isEmpty, "saving shows nothing in the notch")
    }

    @Test func namesAndTextAreValidatedWithClearMessagesAndNothingIsSavedOnARefusal() throws {
        let rig = try snippetsRig()
        let cases: [(name: String, body: String, error: SnippetsError, message: String)] = [
            ("  ", "text", .emptyName, "Give the snippet a name."),
            (String(repeating: "n", count: 61), "text", .nameTooLong, "A name can be at most 60 characters."),
            ("Two\nlines", "text", .nameNotOneLine, "A name must fit on one line."),
            ("Empty", " \n ", .emptyBody, "The snippet has no text."),
            ("Long", String(repeating: "b", count: 10_001), .bodyTooLong, "Snippet text can be at most 10,000 characters."),
        ]
        for refusal in cases {
            #expect(rig.module.add(name: refusal.name, body: refusal.body) == .failure(refusal.error), "\(refusal.error)")
            #expect(refusal.error.message == refusal.message)
        }
        #expect(rig.module.snippets.isEmpty)
        #expect(rig.store.saves == 0)

        #expect(try rig.module.add(name: String(repeating: "n", count: 60), body: String(repeating: "b", count: 10_000)).get().isEmpty)
        #expect(rig.module.snippets.count == 1, "exactly at the limits is fine")
    }

    @Test func duplicateNamesAreRefusedIgnoringCaseAndSpaces() throws {
        let rig = try snippetsRig()
        _ = try rig.module.add(name: "Sign off", body: "one").get()
        #expect(rig.module.add(name: " sign OFF", body: "two") == .failure(.duplicateName("Sign off")))
        #expect(SnippetsError.duplicateName("Sign off").message == "A snippet named Sign off already exists.")
        #expect(rig.module.snippets == [Snippet(name: "Sign off", body: "one")])
        #expect(rig.store.saves == 1)
    }

    @Test func atMostFiftySnippetsAreKept() throws {
        let rig = try snippetsRig()
        for index in 1...SnippetsModule.maxSnippets { _ = try rig.module.add(name: "S\(index)", body: "b").get() }
        #expect(SnippetsModule.maxSnippets == 50)
        #expect(rig.module.add(name: "One more", body: "b") == .failure(.full))
        #expect(SnippetsError.full.message == "You can keep at most 50 snippets. Delete one to add another.")
        #expect(rig.module.snippets.count == 50)
    }

    @Test func renameEditAndDeleteChangeOnlyTheNamedSnippetAndSave() throws {
        let rig = try snippetsRig()
        _ = try rig.module.add(name: "Sign off", body: "Thanks").get()
        _ = try rig.module.add(name: "Address", body: "1 Main St").get()

        #expect(rig.module.rename("sign off", to: "Regards") == nil)
        #expect(rig.module.snippets == [Snippet(name: "Regards", body: "Thanks"), Snippet(name: "Address", body: "1 Main St")])
        #expect(rig.module.rename("Regards", to: "ADDRESS") == .duplicateName("Address"))
        #expect(rig.module.rename("Regards", to: "REGARDS") == nil)
        #expect(rig.names == ["REGARDS", "Address"], "a snippet may change the case of its own name")
        #expect(rig.module.rename("Regards", to: "") == .emptyName)
        #expect(rig.module.rename("Missing", to: "Other") == .notFound("Missing"))
        #expect(SnippetsError.notFound("Missing").message == "There is no snippet named Missing.")

        #expect(try rig.module.edit("Address", body: "2 High St {foo}").get() == [.unknownPlaceholder("{foo}")])
        #expect(rig.module.snippets.last == Snippet(name: "Address", body: "2 High St {foo}"), "saved with the warning")
        #expect(rig.module.edit("Address", body: "") == .failure(.emptyBody))
        #expect(rig.module.edit("Missing", body: "x") == .failure(.notFound("Missing")))

        #expect(rig.module.delete("address") == nil)
        #expect(rig.names == ["REGARDS"])
        #expect(rig.module.delete("Address") == .notFound("Address"))
        #expect(rig.store.stored == rig.module.snippets)
        #expect(rig.clipboard.reads == 0, "no edit reads the clipboard")
    }

    @Test func addingWithAnUnknownPlaceholderSavesAndWarns() throws {
        let rig = try snippetsRig()
        #expect(try rig.module.add(name: "Odd", body: "Hi {foo}").get() == [.unknownPlaceholder("{foo}")])
        #expect(rig.names == ["Odd"])
    }

    @Test func copyWritesTheExpandedTextAndShowsANoticeWithTheNameThatExpires() throws {
        let rig = try snippetsRig()
        _ = try rig.module.add(name: "Sign off", body: "Thanks, {clipboard}, {date}").get()

        let copy = try rig.module.copy("Sign off").get()
        #expect(copy == SnippetCopy(name: "Sign off", preview: "", usedClipboard: true, warnings: []))
        #expect(rig.board.written == ["Thanks, from the test, 10 Oct 2026"])
        #expect(rig.clipboard.reads == 1, "read at the moment of copy")
        #expect(rig.module.lastCopy == copy)

        let shown = try #require(rig.activities.first)
        #expect(rig.activities.count == 1)
        #expect(shown.kind == .completion)
        #expect(shown.title == "Copied Sign off", "the name, never the copied text")
        #expect(shown.expiresAfter == SnippetsModule.noticeSeconds)
        #expect(shown.actions.map(\.id) == ["dismiss"])
        #expect(rig.scheduler.jobs == [rig.clock.now + SnippetsModule.noticeSeconds])

        rig.advance(SnippetsModule.noticeSeconds - 1)
        #expect(rig.activities.count == 1)
        rig.advance(1)
        #expect(rig.activities.isEmpty, "the module's own job ends the notice")
        #expect(rig.module.lastCopy == nil, "the expansion is forgotten with the notice")
        #expect(rig.scheduler.jobs.isEmpty)
        #expect(rig.retained == 1, "only the snippet itself is kept")
    }

    @Test func copyingReadsTheClipboardOnlyForASnippetThatAsksForIt() throws {
        let rig = try snippetsRig()
        _ = try rig.module.add(name: "Address", body: "1 Main St").get()
        #expect(try rig.module.copy("address").get().preview == "1 Main St")
        #expect(rig.clipboard.reads == 0)
        #expect(rig.module.copy("Missing") == .failure(.notFound("Missing")))
        #expect(rig.clipboard.reads == 0)
        #expect(rig.board.written == ["1 Main St"])
    }

    @Test func copyWithAnUnknownPlaceholderOrNoClipboardTextStillCopiesAndWarns() throws {
        let rig = try snippetsRig(clipboard: nil)
        _ = try rig.module.add(name: "Odd", body: "{foo} {clipboard}.").get()
        let copy = try rig.module.copy("Odd").get()
        #expect(copy.preview == "{foo} .")
        #expect(copy.warnings == [.unknownPlaceholder("{foo}"), .clipboardHasNoText])
        #expect(rig.board.written == ["{foo} ."])
        #expect(rig.activities.map(\.title) == ["Copied Odd"])
    }

    /// Some password managers set no marker on what they copy, so the reader cannot tell. A copy that took text from the
    /// clipboard is written marked concealed, so the Clipboard module (which would record Sayso as the source) skips it.
    @Test func aCopyThatFilledInClipboardTextIsWrittenConcealedAndNeverShownInThePane() throws {
        let rig = try snippetsRig(clipboard: "hunter2")
        _ = try rig.module.add(name: "Login", body: "Login: {clipboard}").get()
        let copy = try rig.module.copy("Login").get()
        #expect(rig.board.written == ["Login: hunter2"])
        #expect(rig.board.concealedFlags == [true], "marked concealed so clipboard history skips it")
        #expect(copy.usedClipboard)
        #expect(!copy.preview.contains("hunter2"), "the filled-in text is not kept for the pane")
        #expect(rig.module.lastCopy?.preview.contains("hunter2") == false)
        #expect(rig.activities.map(\.title) == ["Copied Login"])
    }

    @Test func aCopyWithNoClipboardTextIsWrittenPlainAndShown() throws {
        let rig = try snippetsRig()
        _ = try rig.module.add(name: "Address", body: "1 Main St, {date}").get()
        let copy = try rig.module.copy("Address").get()
        #expect(rig.board.concealedFlags == [false], "nothing came from the clipboard, so nothing is hidden")
        #expect(!copy.usedClipboard)
        #expect(copy.preview == "1 Main St, 10 Oct 2026")

        let empty = try snippetsRig(clipboard: nil)
        _ = try empty.module.add(name: "Thanks", body: "Thanks {clipboard}").get()
        let none = try empty.module.copy("Thanks").get()
        #expect(empty.board.concealedFlags == [false], "an empty clipboard put nothing in")
        #expect(!none.usedClipboard)
        #expect(none.preview == "Thanks ")
    }

    @Test func aCopyThatWouldExpandPastTheLimitIsRefusedAndWritesNothing() throws {
        let rig = try snippetsRig(clipboard: String(repeating: "a", count: 1_000_000))
        _ = try rig.module.add(name: "Bomb", body: String(repeating: "{clipboard}", count: 900)).get()
        #expect(rig.module.copy("Bomb") == .failure(.expansionTooLong))
        #expect(SnippetsError.expansionTooLong.message == "That snippet is more than 256 KB once filled in, so nothing was copied.")
        #expect(rig.board.written.isEmpty, "nothing reached the pasteboard")
        #expect(rig.activities.isEmpty)
        #expect(rig.module.lastCopy == nil)
        #expect(rig.scheduler.jobs.isEmpty)
    }

    @Test func aCopyJustUnderTheLimitStillWorks() throws {
        let rig = try snippetsRig(clipboard: String(repeating: "a", count: SnippetsModule.expansionLimit))
        _ = try rig.module.add(name: "Big", body: "{clipboard}").get()
        let copy = try rig.module.copy("Big").get()
        #expect(rig.board.written.map(\.utf8.count) == [SnippetsModule.expansionLimit])
        #expect(rig.board.concealedFlags == [true])
        #expect(copy.preview.isEmpty)
    }

    @Test func thePaneGetsOnlyAShortPrefixOfTheText() throws {
        let rig = try snippetsRig()
        let long = String(repeating: "x", count: 2_000)
        _ = try rig.module.add(name: "Long", body: long).get()
        let copy = try rig.module.copy("Long").get()
        #expect(rig.board.written == [long], "the whole text is still copied")
        #expect(SnippetsModule.previewLimit == 500)
        #expect(copy.preview == String(repeating: "x", count: 500))
        #expect(rig.module.lastCopy?.preview.count == 500, "what the module keeps is the prefix too")
    }

    @Test func aRefusedWriteIsAnErrorAndShowsNoNotice() throws {
        let rig = try snippetsRig()
        _ = try rig.module.add(name: "Sign off", body: "Thanks").get()
        rig.board.refuse(true)
        #expect(rig.module.copy("Sign off") == .failure(.writeFailed("Sign off")))
        #expect(SnippetsError.writeFailed("Sign off").message == "Could not copy Sign off to the clipboard.")
        #expect(rig.activities.isEmpty)
        #expect(rig.module.lastCopy == nil)
        #expect(rig.scheduler.jobs.isEmpty)
    }

    @Test func aNewerCopyReplacesTheNoticeAndAStaleTimerNeverEndsIt() throws {
        let rig = try snippetsRig()
        _ = try rig.module.add(name: "One", body: "1").get()
        _ = try rig.module.add(name: "Two", body: "2").get()
        _ = try rig.module.copy("One").get()
        let stale = try #require(rig.scheduler.snatchEarliest())
        rig.advance(5)
        _ = try rig.module.copy("Two").get()
        stale()
        #expect(rig.activities.map(\.title) == ["Copied Two"], "the newer notice stays")
        #expect(rig.module.lastCopy?.name == "Two")
        #expect(rig.scheduler.jobs == [rig.clock.now + SnippetsModule.noticeSeconds], "one job, re-armed")
        #expect(rig.retained == 4, "two snippets, the newer notice's job and its expansion")
    }

    @Test func dismissFromTheNotchEndsTheNoticeAndForgetsTheExpansion() throws {
        let rig = try snippetsRig()
        _ = try rig.module.add(name: "Sign off", body: "Thanks, {clipboard}").get()
        _ = try rig.module.copy("Sign off").get()
        #expect(rig.host.perform(actionID: "dismiss", stackID: "snippets-copy", moduleID: "snippets"))
        #expect(rig.activities.isEmpty)
        #expect(rig.module.lastCopy == nil)
        #expect(rig.scheduler.jobs.isEmpty)
    }

    @Test func savedSnippetsComeBackAfterTurningOffAndOnAndInANewModule() throws {
        let rig = try snippetsRig()
        _ = try rig.module.add(name: "Sign off", body: "Thanks").get()
        rig.host.disable("snippets")
        #expect(rig.module.snippets.isEmpty, "nothing is listed while off")
        rig.host.enable("snippets")
        #expect(rig.names == ["Sign off"])

        let relaunched = SnippetsModule(
            store: rig.store, clipboard: FakeClipboardReader(nil), pasteboard: FakeSnippetsBoard(), scheduler: SnippetsScheduler()
        )
        let host = SaysoModuleHost(modules: [relaunched])
        host.enable("snippets")
        #expect(relaunched.snippets.map(\.name) == ["Sign off"])
    }

    @Test func loadingKeepsOnlyValidEntriesUpToTheLimitAndNeverSaves() throws {
        let tooMany = (1...55).map { Snippet(name: "S\($0)", body: "b") }
        let saved = [
            Snippet(name: "Good", body: "text"),
            Snippet(name: "good", body: "duplicate"),
            Snippet(name: String(repeating: "n", count: 61), body: "long name"),
            Snippet(name: "No text", body: ""),
            Snippet(name: "Two\nlines", body: "x"),
        ] + tooMany
        let rig = try snippetsRig(saved)
        #expect(rig.names == ["Good"] + (1...49).map { "S\($0)" })
        #expect(rig.store.saves == 0, "what was stored is left as it was until the user edits")
        #expect(rig.clipboard.reads == 0)
    }

    @Test func disablingPurgesTheNoticeTheExpansionAndTheJobAndRefusesWork() throws {
        let rig = try snippetsRig()
        _ = try rig.module.add(name: "Sign off", body: "Thanks, {clipboard}").get()
        _ = try rig.module.copy("Sign off").get()
        #expect(rig.retained == 3, "the snippet, the notice's job and the expansion")
        let reads = rig.clipboard.reads, saves = rig.store.saves

        rig.host.disable("snippets")
        #expect(rig.retained == 0)
        #expect(rig.scheduler.jobs.isEmpty)
        #expect(rig.activities.isEmpty)
        #expect(rig.module.lastCopy == nil)
        #expect(rig.module.snippets.isEmpty)
        #expect(rig.module.add(name: "New", body: "x") == .failure(.off))
        #expect(rig.module.copy("Sign off") == .failure(.off))
        #expect(rig.module.rename("Sign off", to: "x") == .off)
        #expect(rig.module.edit("Sign off", body: "x") == .failure(.off))
        #expect(rig.module.delete("Sign off") == .off)
        #expect(SnippetsError.off.message == "Snippets are off. Turn them on in Settings.")
        #expect(rig.clipboard.reads == reads, "nothing is read while off")
        #expect(rig.store.saves == saves, "the saved snippets are kept, untouched")
        #expect(rig.store.stored == [Snippet(name: "Sign off", body: "Thanks, {clipboard}")])
        #expect(rig.board.written.count == 1)
    }

    @Test func theSettingGateKeepsSnippetsIdleWhileOffAndPurgesWhenTurnedOff() throws {
        let rig = try snippetsRig([Snippet(name: "Kept", body: "text")], enabled: false)
        #expect(rig.host.health(of: "snippets") == .disabled)
        #expect(rig.captured.runtimes.isEmpty, "off at launch starts nothing")
        #expect(rig.store.loads == 0, "and reads nothing")
        #expect(rig.module.snippets.isEmpty)

        rig.host.setEnabled("snippets", true)
        #expect(rig.names == ["Kept"])
        _ = try rig.module.copy("Kept").get()
        rig.host.setEnabled("snippets", false)
        #expect(rig.retained == 0)
        #expect(rig.scheduler.jobs.isEmpty)
        #expect(rig.activities.isEmpty)
        rig.host.setEnabled("snippets", false)
        #expect(rig.host.health(of: "snippets") == .disabled, "turning off twice is harmless")
    }
}

/// A throwaway defaults suite, removed when the test ends.
private func withSuite(_ body: (UserDefaults) throws -> Void) throws {
    let suite = "SnippetsStoreTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults)
}

@Suite struct UserDefaultsSnippetsStoreTests {
    @Test func savedSnippetsReadBackInOrder() throws {
        try withSuite { defaults in
            let snippets = [Snippet(name: "Sign off", body: "Thanks, {clipboard}"), Snippet(name: "Address", body: "1 Main St")]
            UserDefaultsSnippetsStore(defaults: defaults).save(snippets)
            #expect(UserDefaultsSnippetsStore(defaults: defaults).load() == snippets)
        }
    }

    @Test func missingWrongTypeOrCorruptDataReadsAsEmptyAndAnUnreadableEntryIsSkipped() throws {
        try withSuite { defaults in
            let store = UserDefaultsSnippetsStore(defaults: defaults)
            #expect(store.load().isEmpty, "nothing stored yet")
            defaults.set("not data", forKey: UserDefaultsSnippetsStore.key)
            #expect(store.load().isEmpty)
            defaults.set(Data([0xFF, 0x00, 0x7B]), forKey: UserDefaultsSnippetsStore.key)
            #expect(store.load().isEmpty)
            defaults.set(Data(#"{"name":"not a list"}"#.utf8), forKey: UserDefaultsSnippetsStore.key)
            #expect(store.load().isEmpty)
            defaults.set(Data(#"[{"name":"Kept","body":"text"},{"name":5},7,{"body":"no name"}]"#.utf8), forKey: UserDefaultsSnippetsStore.key)
            #expect(store.load() == [Snippet(name: "Kept", body: "text")])
        }
    }

    /// Corrupt data might still be recovered by hand, so turning snippets on, listing them, off and on again must
    /// leave the bytes alone; only the user's next edit replaces them.
    @Test func corruptDataIsNotOverwrittenUntilTheUserEdits() throws {
        try withSuite { defaults in
            let corrupt = Data("{ half written".utf8)
            defaults.set(corrupt, forKey: UserDefaultsSnippetsStore.key)
            let module = SnippetsModule(
                store: UserDefaultsSnippetsStore(defaults: defaults), clipboard: FakeClipboardReader(nil),
                pasteboard: FakeSnippetsBoard(), scheduler: SnippetsScheduler()
            )
            let host = SaysoModuleHost(modules: [module])
            host.enable("snippets")
            #expect(module.snippets.isEmpty)
            #expect(module.add(name: "", body: "refused") == .failure(.emptyName))
            host.disable("snippets")
            host.enable("snippets")
            #expect(defaults.data(forKey: UserDefaultsSnippetsStore.key) == corrupt)

            _ = try module.add(name: "Sign off", body: "Thanks").get()
            #expect(UserDefaultsSnippetsStore(defaults: defaults).load() == [Snippet(name: "Sign off", body: "Thanks")])
        }
    }
}

@Suite struct PasteboardSnippetsClipboardReaderTests {
    /// A uniquely named board, never the general one, so the test cannot read or change the user's clipboard.
    @Test func readsPlainTextOnlyAndNeverChangesTheBoard() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("SnippetsReaderTests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let reader = PasteboardSnippetsClipboardReader(pasteboard: board)

        board.clearContents()
        #expect(reader.readText() == nil, "an empty board has no text")
        board.setData(Data([1, 2, 3]), forType: .png)
        #expect(reader.readText() == nil, "an image is not text")

        board.clearContents()
        board.setString("from the board", forType: .string)
        let count = board.changeCount
        #expect(reader.readText() == "from the board")
        #expect(board.changeCount == count, "reading leaves the board as it was")
        #expect(board.string(forType: .string) == "from the board")
    }

    /// A password manager, or any app, marks a secret so clipboard tools skip it. Copying a snippet must not lift such
    /// text into a plain clipboard write (where history would keep it) or onto the screen: it reads as no text.
    @Test(arguments: [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "de.petermaurer.TransientPasteboardType",
        "com.agilebits.onepassword",
    ])
    func textMarkedAsASecretReadsAsNoText(marker: String) throws {
        let board = NSPasteboard(name: NSPasteboard.Name("SnippetsReaderTests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let reader = PasteboardSnippetsClipboardReader(pasteboard: board)

        board.clearContents()
        board.setString("hunter2", forType: .string)
        board.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
        #expect(reader.readText() == nil, "\(marker) marks the text as a secret")

        board.clearContents()
        board.setString("plain note", forType: .string)
        #expect(reader.readText() == "plain note", "an unmarked copy is still read")
    }
}

@Suite struct PasteboardSnippetsWriterTests {
    @Test func aConcealedWriteCarriesTheMarkerClipboardHistorySkipsAndAPlainWriteDoesNot() {
        let board = NSPasteboard(name: NSPasteboard.Name("SnippetsWriterTests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let writer = PasteboardSnippetsWriter(pasteboard: board)
        let types = { Set((board.types ?? []).map(\.rawValue)) }

        #expect(writer.write("Login: hunter2", concealed: true))
        #expect(board.string(forType: .string) == "Login: hunter2")
        #expect(types().contains("org.nspasteboard.ConcealedType"))
        #expect(ClipboardPrivacy.isSensitive(types: types(), sourceBundleID: nil), "the Clipboard module would skip it")

        #expect(writer.write("1 Main St", concealed: false))
        #expect(board.string(forType: .string) == "1 Main St")
        #expect(!ClipboardPrivacy.isSensitive(types: types(), sourceBundleID: nil), "a plain write leaves no marker, and replaced the old one")
    }
}

@Suite struct SnippetsUITestHookTests {
    @Test func theFakeBoardIsUsedOnlyWithFreshSettingsAndNeverFallsBackToTheRealOne() throws {
        #expect(SnippetsUITestHook.board(arguments: ["app"]) == nil)
        #expect(SnippetsUITestHook.board(arguments: ["app", "--ui-test-clipboard", "x"]) == nil, "a real launch uses the real clipboard")
        #expect(SnippetsUITestHook.board(arguments: ["app", "--ui-test-fresh-settings"]) == nil)

        let board = try #require(
            SnippetsUITestHook.board(arguments: ["app", "--ui-test-fresh-settings", "--ui-test-clipboard", "from the test"])
        )
        #expect(board.readText() == "from the test")
        #expect(board.write("Thanks, from the test", concealed: false))
        #expect(board.written == ["Thanks, from the test"])
        #expect(board.readText() == "Thanks, from the test", "like a real board, a write replaces the text")

        let missing = try #require(SnippetsUITestHook.board(arguments: ["app", "--ui-test-fresh-settings", "--ui-test-clipboard"]))
        #expect(missing.readText() == nil, "no value gives an empty fake board, never the real one")
    }
}

@Suite struct SnippetsSettingTests {
    /// Snippets read the clipboard only when the user copies one that asks for it, so they are on unless turned off:
    /// a missing or malformed stored value means on, like the calculator.
    @Test func snippetsAreOnForNewAndUpgradingUsers() throws {
        #expect(SaysoSettings().snippetsEnabled)
        let olderSettings = Data("{\"mode\":\"dictation\",\"calculatorEnabled\":false}".utf8)
        #expect(try JSONDecoder().decode(SaysoSettings.self, from: olderSettings).snippetsEnabled)
        let malformed = Data("{\"snippetsEnabled\":\"no\"}".utf8)
        #expect(try JSONDecoder().decode(SaysoSettings.self, from: malformed).snippetsEnabled)
    }

    @Test func turningSnippetsOffSurvivesARelaunch() throws {
        try withSuite { defaults in
            var settings = SaysoSettings()
            settings.snippetsEnabled = false
            UserDefaultsSettingsStore(defaults: defaults).save(settings)
            #expect(!UserDefaultsSettingsStore(defaults: defaults).load().snippetsEnabled)
        }
    }
}
