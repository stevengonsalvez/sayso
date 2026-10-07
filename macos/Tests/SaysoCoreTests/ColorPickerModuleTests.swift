import AppKit
import Testing
@testable import SaysoCore

private func color(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> ColorPickerColor {
    ColorPickerColor(red: red, green: green, blue: blue)
}

@Suite struct ColorPickerConversionTests {
    @Test func hexIsHashAndSixUppercaseDigits() {
        #expect(color(0x33, 0x66, 0x99).hex == "#336699")
        #expect(color(10, 171, 205).hex == "#0AABCD", "leading zeros kept, letters upper case")
        #expect(color(0, 0, 0).hex == "#000000")
        #expect(color(255, 255, 255).hex == "#FFFFFF")
    }

    @Test func rgbListsTheThreeChannels() {
        #expect(color(51, 102, 153).rgb == "rgb(51, 102, 153)")
        #expect(color(0, 0, 0).rgb == "rgb(0, 0, 0)")
    }

    @Test func hslIsRoundedToWholeDegreesAndPercents() {
        #expect(color(51, 102, 153).hsl == ColorPickerHSL(hue: 210, saturation: 50, lightness: 40))
        #expect(color(51, 102, 153).hsl.text == "hsl(210, 50%, 40%)")
        #expect(color(255, 0, 0).hsl == ColorPickerHSL(hue: 0, saturation: 100, lightness: 50))
        #expect(color(0, 255, 0).hsl == ColorPickerHSL(hue: 120, saturation: 100, lightness: 50))
        #expect(color(0, 0, 255).hsl == ColorPickerHSL(hue: 240, saturation: 100, lightness: 50))
        #expect(color(255, 0, 4).hsl.hue == 359)
    }

    @Test func aHueThatRoundsUpTo360ReadsZero() {
        #expect(color(255, 0, 1).hsl.hue == 0, "359.76 degrees rounds to 360, which is 0")
    }

    @Test func greyHasHueZeroAndSaturationZero() {
        #expect(color(128, 128, 128).hsl == ColorPickerHSL(hue: 0, saturation: 0, lightness: 50))
        #expect(color(255, 255, 255).hsl == ColorPickerHSL(hue: 0, saturation: 0, lightness: 100))
        #expect(color(0, 0, 0).hsl == ColorPickerHSL(hue: 0, saturation: 0, lightness: 0))
    }

    @Test func everyColourGivesAHueBelow360AndPercentsWithin0To100() {
        for red in stride(from: 0, through: 255, by: 5) {
            for green in stride(from: 0, through: 255, by: 5) {
                for blue in stride(from: 0, through: 255, by: 5) {
                    let hsl = color(UInt8(red), UInt8(green), UInt8(blue)).hsl
                    guard (0...359).contains(hsl.hue), (0...100).contains(hsl.saturation), (0...100).contains(hsl.lightness)
                    else {
                        Issue.record("rgb(\(red), \(green), \(blue)) gave \(hsl.text)")
                        return
                    }
                }
            }
        }
    }

    @Test func eachFormatHasItsText() {
        let picked = color(51, 102, 153)
        #expect(ColorPickerFormat.allCases == [.hex, .rgb, .hsl])
        #expect(ColorPickerFormat.allCases.map { picked.text($0) } == ["#336699", "rgb(51, 102, 153)", "hsl(210, 50%, 40%)"])
    }

    @Test func srgbComponentsAreRoundedAndClampedAndNotANumberReadsZero() {
        #expect(ColorPickerColor(srgbRed: 0.2, green: 0.4, blue: 0.6) == color(51, 102, 153))
        #expect(ColorPickerColor(srgbRed: 1.2, green: -0.1, blue: .nan) == color(255, 0, 0))
        #expect(ColorPickerColor(srgbRed: .infinity, green: -.infinity, blue: 0.5) == color(255, 0, 128))
    }
}

@Suite struct ColorPickerParserTests {
    @Test func shortAndLongHexAreRead() {
        #expect(ColorPickerColor.parse("#abc") == color(0xAA, 0xBB, 0xCC))
        #expect(ColorPickerColor.parse("#aabbcc") == color(0xAA, 0xBB, 0xCC))
        #expect(ColorPickerColor.parse("#AbC") == color(0xAA, 0xBB, 0xCC), "either case")
        #expect(ColorPickerColor.parse("  #336699\n") == color(0x33, 0x66, 0x99), "surrounding space is trimmed")
    }

    @Test func rgbIsReadWithCommasOrSpaces() {
        #expect(ColorPickerColor.parse("rgb(1,2,3)") == color(1, 2, 3))
        #expect(ColorPickerColor.parse("rgb(1 2 3)") == color(1, 2, 3))
        #expect(ColorPickerColor.parse("RGB( 51 , 102 , 153 )") == color(51, 102, 153))
        #expect(ColorPickerColor.parse("rgb(1.4, 2.6, 254.5)") == color(1, 3, 255), "fractions round to the nearest")
        #expect(ColorPickerColor.parse("rgb(1,\n2,\t3)") == color(1, 2, 3), "a newline next to a comma is space too")
        #expect(ColorPickerColor.parse("rgb(1\n2\n3)") == color(1, 2, 3))
    }

    @Test func hslIsReadAndConvertedToRgb() {
        #expect(ColorPickerColor.parse("hsl(10 50% 50%)") == color(191, 85, 64))
        #expect(ColorPickerColor.parse("hsl(210, 50%, 40%)") == color(51, 102, 153))
        #expect(ColorPickerColor.parse("hsl(0 0% 100%)") == color(255, 255, 255))
        #expect(ColorPickerColor.parse("hsl(120 100 25)") == color(0, 128, 0), "the percent sign may be left out")
    }

    @Test func outOfRangeNumbersAreClampedAndHueWrapsAround() {
        #expect(ColorPickerColor.parse("rgb(300, -5, 10)") == color(255, 0, 10))
        #expect(ColorPickerColor.parse("hsl(-350 50% 50%)") == ColorPickerColor.parse("hsl(10 50% 50%)"))
        #expect(ColorPickerColor.parse("hsl(370 50% 50%)") == ColorPickerColor.parse("hsl(10 50% 50%)"))
        #expect(ColorPickerColor.parse("hsl(10 150% 50%)") == ColorPickerColor.parse("hsl(10 100% 50%)"))
        #expect(ColorPickerColor.parse("hsl(10 50% -10%)") == color(0, 0, 0))
    }

    @Test func malformedInputIsRejected() {
        let rejected = [
            "", "   ", "#", "#ab", "#abcd", "#aabbccdd", "#ggg", "336699", "red", "##abc",
            "rgb(1,2)", "rgb(1,2,3,4)", "rgb(1,2,x)", "rgb(1%,2,3)", "rgb(1,,2)", "rgb(1, 2 3)", "rgb 1 2 3", "rgb(1,2,3",
            "rgb(nan,1,2)", "rgb(inf,1,2)", "rgb(1e3,1,2)", "rgb(0x10,1,2)", "rgb(-,1,2)", "rgb(1.,2,3)", "rgb(.5.5,2,3)",
            "hsl(10 50% 50%", "hsl(10 50%% 50%)", "hsl(10% 50% 50%)", "hsl(10 50% 50%) x", "rgb(1,2,3)hsl(1,2,3)",
        ]
        for input in rejected {
            #expect(ColorPickerColor.parse(input) == nil, "\(input.debugDescription) is not a colour")
        }
    }

    @Test func inputLongerThanTheLimitIsRejectedBeforeParsing() {
        #expect(ColorPickerColor.maxInputLength == 64)
        let padded = String(repeating: " ", count: ColorPickerColor.maxInputLength) + "#abc"
        #expect(ColorPickerColor.parse(padded) == nil, "the limit counts the input as given, before trimming")
        let started = Date()
        #expect(ColorPickerColor.parse("rgb(" + String(repeating: "0", count: 100_000) + "1, 2, 3)") == nil)
        #expect(Date().timeIntervalSince(started) < 0.2)
        let atLimit = "rgb(" + String(repeating: " ", count: ColorPickerColor.maxInputLength - "rgb(1,2,3)".count) + "1,2,3)"
        #expect(atLimit.utf8.count == ColorPickerColor.maxInputLength)
        #expect(ColorPickerColor.parse(atLimit) == color(1, 2, 3), "exactly at the limit is still read")
    }

    @Test func everyFormattedColourParsesBackToItself() {
        for red in stride(from: 0, through: 255, by: 15) {
            for green in stride(from: 0, through: 255, by: 15) {
                for blue in stride(from: 0, through: 255, by: 15) {
                    let original = color(UInt8(red), UInt8(green), UInt8(blue))
                    #expect(ColorPickerColor.parse(original.hex) == original)
                    #expect(ColorPickerColor.parse(original.rgb) == original)
                }
            }
        }
    }
}

/// Answers each pick from a queue, or holds it until the test answers, so a pick can be left in flight.
private final class FakeSampler: ColorSamplingPort, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [ColorPickerColor?] = []
    private var held: [CheckedContinuation<ColorPickerColor?, Never>] = []
    private var asked = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// How many times the sampler was shown.
    var requests: Int { lock.withLock { asked } }

    /// The next pick returns this at once, replacing an earlier answer nobody asked for; nil is the user pressing
    /// Escape.
    func queue(_ color: ColorPickerColor?) { lock.withLock { queued = [color] } }

    /// Every held pick ends as a cancel if the test is cancelled, a backstop against a hung run.
    func pick() async -> ColorPickerColor? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                    asked += 1
                    if queued.isEmpty { held.append(continuation) } else { continuation.resume(returning: queued.removeFirst()) }
                    let due = waiters.filter { $0.count <= asked }
                    waiters.removeAll { $0.count <= asked }
                    return due.map(\.continuation)
                }
                ready.forEach { $0.resume() }
            }
        } onCancel: {
            let all = lock.withLock { () -> [CheckedContinuation<ColorPickerColor?, Never>] in
                defer { held = [] }
                return held
            }
            all.forEach { $0.resume(returning: nil) }
        }
    }

    /// Returns once the sampler has been shown `count` times in all.
    func waitForRequests(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let done = lock.withLock { () -> Bool in
                if asked >= count { return true }
                waiters.append((count, continuation))
                return false
            }
            if done { continuation.resume() }
        }
    }

    /// The oldest held pick returns `color`.
    func answer(_ color: ColorPickerColor?) {
        let continuation = lock.withLock { held.isEmpty ? nil : held.removeFirst() }
        continuation?.resume(returning: color)
    }
}

/// Records writes only: the port has no way to read the pasteboard, so the module cannot.
private final class ColorPasteboard: CalculatorPasteboardPort, @unchecked Sendable {
    private let lock = NSLock()
    private var writes: [String] = []
    private var refusing = false

    var written: [String] { lock.withLock { writes } }
    func refuse(_ on: Bool) { lock.withLock { refusing = on } }

    func write(_ text: String) -> Bool {
        lock.withLock {
            guard !refusing else { return false }
            writes.append(text)
            return true
        }
    }
}

private final class ColorScheduler: SaysoScheduling, @unchecked Sendable {
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

private final class ColorClock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000_000) }

private final class ColorRuntimes: @unchecked Sendable { var runtimes: [SaysoModuleRuntime] = [] }

private struct ColorPickerProbe: SaysoModule {
    let inner: ColorPickerModule
    let captured: ColorRuntimes
    var descriptor: SaysoModuleDescriptor { inner.descriptor }
    func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        let runtime = inner.makeRuntime(context: context)
        captured.runtimes.append(runtime)
        return runtime
    }
}

private struct ColorPickerRig {
    let host: SaysoModuleHost
    let module: ColorPickerModule
    let sampler: FakeSampler
    let pasteboard: ColorPasteboard
    let scheduler: ColorScheduler
    let clock: ColorClock
    let captured: ColorRuntimes

    init() {
        let sampler = FakeSampler(), pasteboard = ColorPasteboard(), scheduler = ColorScheduler()
        let clock = ColorClock(), captured = ColorRuntimes()
        module = ColorPickerModule(sampler: sampler, pasteboard: pasteboard, scheduler: scheduler, now: { clock.now })
        host = SaysoModuleHost(modules: [ColorPickerProbe(inner: module, captured: captured)], now: { clock.now })
        host.enable("color-picker")
        (self.sampler, self.pasteboard, self.scheduler, self.clock, self.captured) = (sampler, pasteboard, scheduler, clock, captured)
    }

    func advance(_ seconds: TimeInterval) {
        clock.now += seconds
        scheduler.runDue(clock.now)
    }

    /// A pick the user completes at once with `color`, or cancels with nil.
    func pick(_ color: ColorPickerColor?) async -> ColorPick? {
        sampler.queue(color)
        return await module.pick()
    }

    var titles: [String] { host.engine.stack.filter { $0.moduleID == "color-picker" }.map(\.title) }
    var retained: Int { (captured.runtimes.last as? SaysoResourceAccounting)?.retainedResources ?? -1 }
}

@Suite(.timeLimit(.minutes(1))) struct ColorPickerModuleTests {
    @Test func passesTheModuleAcceptanceContract() {
        let module = ColorPickerModule(sampler: FakeSampler(), pasteboard: ColorPasteboard(), scheduler: ColorScheduler())
        #expect(module.descriptor.id == "color-picker")
        #expect(module.descriptor.capabilities.isEmpty, "no capability is declared: the user drives the system sampler")
        #expect(SaysoModuleAcceptance.violations(for: module).isEmpty, "\(SaysoModuleAcceptance.violations(for: module))")
    }

    @Test func aPickIsKeptAndShownBrieflyAsACompletionThatExpiresOnTheScheduler() async throws {
        let rig = ColorPickerRig()
        let picked = try #require(await rig.pick(color(0x33, 0x66, 0x99)))
        #expect(picked.color.hex == "#336699")
        #expect(rig.module.history == [picked])

        let shown = try #require(rig.host.engine.stack.first { $0.moduleID == "color-picker" })
        #expect(shown.kind == .completion)
        #expect(shown.title == "Picked #336699")
        #expect(shown.expiresAfter == ColorPickerModule.noticeSeconds)
        #expect(shown.actions.map(\.id) == ["dismiss"])
        #expect(ColorPickerModule.noticeSeconds == 10, "as long as the calculator, timer and caffeine notices")
        #expect(rig.scheduler.jobs == [rig.clock.now + ColorPickerModule.noticeSeconds])

        rig.advance(ColorPickerModule.noticeSeconds - 1)
        #expect(rig.titles == ["Picked #336699"], "still shown just before it expires")
        rig.advance(1)
        #expect(rig.titles.isEmpty, "the scheduler job removes it without any engine tick")
        #expect(rig.scheduler.jobs.isEmpty)
        #expect(rig.module.history == [picked], "the pick outlives its notice")
    }

    @Test func historyKeepsTheLastTenNewestFirstAndSkipsARepeatOfTheLastPick() async throws {
        let rig = ColorPickerRig()
        for value in 1...12 { _ = await rig.pick(color(UInt8(value), 0, 0)) }
        #expect(ColorPickerModule.historyLimit == 10)
        #expect(rig.module.history.map(\.color.red) == (3...12).reversed().map { UInt8($0) })
        #expect(Set(rig.module.history.map(\.id)).count == 10, "ids are unique")

        let newest = try #require(rig.module.history.first)
        let again = try #require(await rig.pick(color(12, 0, 0)))
        #expect(again == newest, "picking the same colour again keeps the entry it already has")
        #expect(rig.module.history.count == 10)
        #expect(rig.titles == ["Picked #0C0000"], "the notice still confirms the pick")

        _ = await rig.pick(color(11, 0, 0))
        #expect(rig.module.history.prefix(3).map(\.color.red) == [11, 12, 11], "only a repeat of the last pick is skipped")
    }

    @Test func aCancelledPickChangesNothingAndShowsNothing() async throws {
        let empty = ColorPickerRig()
        #expect(await empty.pick(nil) == nil)
        #expect(empty.module.history.isEmpty)
        #expect(empty.titles.isEmpty)
        #expect(empty.scheduler.jobs.isEmpty)

        let rig = ColorPickerRig()
        let kept = try #require(await rig.pick(color(0x33, 0x66, 0x99)))
        rig.advance(3)
        let due = rig.scheduler.jobs
        #expect(await rig.pick(nil) == nil)
        #expect(rig.module.history == [kept])
        #expect(rig.titles == ["Picked #336699"])
        #expect(rig.scheduler.jobs == due, "the earlier notice keeps its own expiry")
    }

    @Test func onlyOnePickIsInFlightAndASecondRequestNeverShowsASecondSampler() async throws {
        let rig = ColorPickerRig()
        let first = Task { await rig.module.pick() }
        await rig.sampler.waitForRequests(1)
        #expect(rig.module.isPicking)
        // An answer is ready, so a module that wrongly shows a second sampler gets it at once and fails, never hangs.
        rig.sampler.queue(color(7, 7, 7))
        #expect(await rig.module.pick() == nil, "ignored while one is pending")
        #expect(rig.sampler.requests == 1)
        #expect(rig.retained == 1, "the pending pick is held")

        rig.sampler.answer(color(1, 2, 3))
        #expect(await first.value?.color == color(1, 2, 3))
        #expect(!rig.module.isPicking)
        #expect(await rig.pick(color(4, 5, 6))?.color == color(4, 5, 6), "the next pick shows the sampler again")
        #expect(rig.sampler.requests == 2)
    }

    @Test func aNewPickReplacesTheNoticeAndAnOlderTimerNeverEndsIt() async throws {
        let rig = ColorPickerRig()
        _ = await rig.pick(color(1, 1, 1))
        let stale = try #require(rig.scheduler.snatchEarliest())
        rig.advance(5)
        _ = await rig.pick(color(2, 2, 2))
        #expect(rig.titles == ["Picked #020202"])
        #expect(rig.scheduler.jobs == [rig.clock.now + ColorPickerModule.noticeSeconds], "one job, re-armed")

        stale()
        #expect(rig.titles == ["Picked #020202"], "the newer notice stays")
        #expect(rig.scheduler.jobs.count == 1)
        #expect(rig.retained == 3, "two picks and the newer notice's job")
        rig.advance(ColorPickerModule.noticeSeconds)
        #expect(rig.titles.isEmpty)
    }

    @Test func copyWritesOnlyTheChosenFormatThroughThePort() async throws {
        let rig = ColorPickerRig()
        let older = try #require(await rig.pick(color(0x33, 0x66, 0x99)))
        _ = await rig.pick(color(0, 0, 0))
        #expect(rig.module.copy(.hex, of: older.id))
        #expect(rig.module.copy(.rgb, of: older.id))
        #expect(rig.module.copy(.hsl, of: older.id))
        #expect(rig.pasteboard.written == ["#336699", "rgb(51, 102, 153)", "hsl(210, 50%, 40%)"])
        #expect(!rig.module.copy(.hex, of: 9_999), "an unknown id copies nothing")
        rig.pasteboard.refuse(true)
        #expect(!rig.module.copy(.hex, of: older.id), "a refused write is reported")
        #expect(rig.pasteboard.written.count == 3)
    }

    @Test func theNotchDismissEndsTheNoticeAndItsTimer() async throws {
        let rig = ColorPickerRig()
        _ = await rig.pick(color(0x33, 0x66, 0x99))
        #expect(rig.host.perform(actionID: "dismiss", stackID: "color-picker-pick", moduleID: "color-picker"))
        #expect(rig.titles.isEmpty)
        #expect(rig.scheduler.jobs.isEmpty, "dismiss cancels the expiry job")
        #expect(rig.module.history.count == 1)
    }

    @Test func offRefusesPicksWithoutShowingTheSamplerAndRefusesCopies() async throws {
        let rig = ColorPickerRig()
        let kept = try #require(await rig.pick(color(0x33, 0x66, 0x99)))
        rig.host.disable("color-picker")
        #expect(await rig.module.pick() == nil)
        #expect(rig.sampler.requests == 1, "no sampler while off")
        #expect(!rig.module.copy(.hex, of: kept.id))
        #expect(rig.pasteboard.written.isEmpty)
    }

    @Test func disablingIgnoresAPendingPickAndPurgesHistoryAndTheNotice() async throws {
        let rig = ColorPickerRig()
        _ = await rig.pick(color(0x33, 0x66, 0x99))
        let pending = Task { await rig.module.pick() }
        await rig.sampler.waitForRequests(2)
        #expect(rig.retained == 3, "one pick, its notice's job and the pending pick")

        rig.host.disable("color-picker")
        #expect(rig.retained == 0)
        #expect(rig.scheduler.jobs.isEmpty)
        #expect(rig.module.history.isEmpty)
        #expect(rig.titles.isEmpty)

        rig.sampler.answer(color(9, 9, 9))
        #expect(await pending.value == nil, "the pick that returns after disable is dropped")
        #expect(rig.module.history.isEmpty)
        #expect(rig.titles.isEmpty)
        #expect(rig.scheduler.jobs.isEmpty)
    }

    @Test func aPickStillOpenAcrossOffAndOnNeverLandsInTheNewSessionNorOpensASecondSampler() async throws {
        let rig = ColorPickerRig()
        let pending = Task { await rig.module.pick() }
        await rig.sampler.waitForRequests(1)
        rig.host.disable("color-picker")
        rig.host.enable("color-picker")

        rig.sampler.queue(color(7, 7, 7))
        #expect(await rig.module.pick() == nil, "the system sampler from before is still on screen")
        #expect(rig.sampler.requests == 1)
        rig.sampler.answer(color(9, 9, 9))
        #expect(await pending.value == nil)
        #expect(rig.module.history.isEmpty, "nothing from before lands in the new session")
        #expect(rig.titles.isEmpty)
        #expect(rig.retained == 0)

        #expect(await rig.pick(color(1, 2, 3))?.color == color(1, 2, 3))
        #expect(rig.sampler.requests == 2)
    }
}

/// The real adapter's colour conversion only. The system sampler itself waits for a human click, so no test ever
/// calls `SystemColorSamplingPort.pick()`.
@Suite struct SystemColorSamplingPortTests {
    @Test func aSampledColourIsReadInSRGB() {
        #expect(SystemColorSamplingPort.color(from: NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)) == color(51, 102, 153))
        let extended = NSColor(colorSpace: .extendedSRGB, components: [1.2, -0.1, 0.5, 1], count: 4)
        #expect(SystemColorSamplingPort.color(from: extended) == color(255, 0, 128))
    }

    @Test func aWideGamutColourIsConvertedToSRGBAndClamped() {
        let p3Red = NSColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1)
        #expect(SystemColorSamplingPort.color(from: p3Red) == color(255, 0, 0), "P3 red lies outside sRGB")
        let p3Mid = NSColor(displayP3Red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        #expect(SystemColorSamplingPort.color(from: p3Mid) == color(128, 128, 128), "a neutral grey is the same in both")
    }

    /// Red and grey above clamp or match with or without conversion; an in-gamut colour handed over in P3 does not.
    @Test func anInGamutColourGivenInDisplayP3ReadsAsItsSRGBValue() throws {
        let p3 = try #require(NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1).usingColorSpace(.displayP3))
        #expect(SystemColorSamplingPort.color(from: p3) == color(51, 102, 153))
    }

    @Test func aColourWithNoSRGBFormIsNoPick() {
        let pattern = NSColor(patternImage: NSImage(size: NSSize(width: 1, height: 1)))
        #expect(SystemColorSamplingPort.color(from: pattern) == nil)
    }
}

/// `--ui-test-color` swaps in a fake sampler only for a UI test launch, never for a real one.
@Suite struct ColorPickerUITestHookTests {
    @Test func theFakeSamplerIsUsedOnlyTogetherWithFreshSettings() async throws {
        #expect(ColorPickerUITestHook.sampler(arguments: ["SaysoNotch"]) == nil)
        #expect(
            ColorPickerUITestHook.sampler(arguments: ["SaysoNotch", "--ui-test-color", "336699"]) == nil,
            "without fresh settings the real sampler is used"
        )
        let fake = try #require(
            ColorPickerUITestHook.sampler(arguments: ["SaysoNotch", "--ui-test-fresh-settings", "--ui-test-color", "336699"])
        )
        #expect(await fake.pick() == color(0x33, 0x66, 0x99))
        #expect(await fake.pick() == color(0x33, 0x66, 0x99), "every pick returns the same colour")
        let hashed = try #require(
            ColorPickerUITestHook.sampler(arguments: ["--ui-test-color", "#abc", "--ui-test-fresh-settings"])
        )
        #expect(await hashed.pick() == color(0xAA, 0xBB, 0xCC))
    }

    @Test func anUnreadableTestColourCancelsAndNeverFallsBackToTheRealSampler() async throws {
        for arguments in [
            ["--ui-test-fresh-settings", "--ui-test-color", "zzz"],
            ["--ui-test-fresh-settings", "--ui-test-color"],
            ["--ui-test-fresh-settings", "--ui-test-color", "--ui-test-review"],
        ] {
            let fake = try #require(ColorPickerUITestHook.sampler(arguments: arguments), "\(arguments)")
            #expect(await fake.pick() == nil, "\(arguments)")
        }
    }
}
