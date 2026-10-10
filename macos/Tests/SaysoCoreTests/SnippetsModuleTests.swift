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

    @Test func aClipboardWithNoTextLeavesThePlaceholderEmptyAndWarns() throws {
        let expansion = try expander().expand("Thanks, {clipboard}!", at: try tenPastTwo(), clipboard: { nil })
        #expect(expansion.text == "Thanks, !")
        #expect(expansion.warnings == [.clipboardHasNoText])
        #expect(SnippetsWarning.clipboardHasNoText.message == "The clipboard had no text, so {clipboard} was left empty.")
        #expect(SnippetsExpander.warnings(in: "Thanks, {clipboard}!").isEmpty, "saving never looks at the clipboard")
    }
}
