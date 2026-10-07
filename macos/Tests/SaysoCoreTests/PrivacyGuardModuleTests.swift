import Foundation
import Testing
@testable import SaysoCore

private final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000_000) }

private let builtInMic = PrivacyDevice(id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", kind: .microphone, isRunning: false)
private let builtInCamera = PrivacyDevice(id: "47B4B64B", name: "FaceTime HD Camera", kind: .camera, isRunning: false)
private let usbMic = PrivacyDevice(id: "AppleUSBAudioEngine:Blue:Yeti", name: "Yeti Stereo Microphone", kind: .microphone, isRunning: false)

private extension PrivacyDevice {
    var on: PrivacyDevice { with { $0.isRunning = true } }

    func with(_ change: (inout PrivacyDevice) -> Void) -> PrivacyDevice {
        var copy = self
        change(&copy)
        return copy
    }
}

/// Stands in for CoreAudio and CoreMediaIO: returns whatever device list the test set, counting reads.
private final class FakeDevices: PrivacyDevicePort, @unchecked Sendable {
    private let lock = NSLock()
    private var list: [PrivacyDevice]
    private var error: PrivacyDevicePortError?
    private var readCount = 0

    init(_ list: [PrivacyDevice]) { self.list = list }

    var reads: Int { lock.withLock { readCount } }

    func set(_ list: [PrivacyDevice]) { lock.withLock { self.list = list } }
    func fail(_ error: PrivacyDevicePortError?) { lock.withLock { self.error = error } }

    func devices() throws(PrivacyDevicePortError) -> [PrivacyDevice] {
        lock.lock()
        defer { lock.unlock() }
        readCount += 1
        if let error { throw error }
        return list
    }
}

private final class FakeScheduler: SaysoScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var nextID = 0
    private var pending: [(id: Int, at: Date, action: @Sendable () -> Void)] = []
    var jobs: [Date] { lock.withLock { pending.map(\.at) } }

    func schedule(at date: Date, _ action: @escaping @Sendable () -> Void) -> SaysoSubscription {
        let id = lock.withLock { () -> Int in nextID += 1; pending.append((nextID, date, action)); return nextID }
        return SaysoSubscription { [weak self] in self?.lock.withLock { self?.pending.removeAll { $0.id == id } } }
    }

    /// Fires every job due at `now`, earliest first, like a real timer firing late.
    func runDue(_ now: Date) {
        for _ in 0..<10_000 {
            let job = lock.withLock { () -> (id: Int, at: Date, action: @Sendable () -> Void)? in
                guard let index = pending.indices.filter({ pending[$0].at <= now }).min(by: { pending[$0].at < pending[$1].at })
                else { return nil }
                return pending.remove(at: index)
            }
            guard let job else { return }
            job.action()
        }
        Issue.record("jobs kept re-arming at or before now: a runaway loop")
    }
}

/// What the host would answer for "is Sayso itself listening right now".
private final class SaysoCapture: @unchecked Sendable { var capturing = false }

private final class Captured: @unchecked Sendable {
    var runtimes: [SaysoModuleRuntime] = []
}

private struct Probe: SaysoModule {
    let inner: PrivacyGuardModule
    let captured: Captured
    var descriptor: SaysoModuleDescriptor { inner.descriptor }
    func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        let runtime = inner.makeRuntime(context: context)
        captured.runtimes.append(runtime)
        return runtime
    }
}

/// Every change to the notch, as this module's line titles.
private final class Painted: @unchecked Sendable {
    var changes: [[String]] = []
}

/// Another module that publishes whatever a test asks, to check how the privacy line ranks against it.
private final class Neighbour: SaysoModule, SaysoModuleRuntime, @unchecked Sendable {
    let descriptor = SaysoModuleDescriptor(id: "neighbour", title: "Neighbour")
    var context: SaysoModuleContext?
    func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        self.context = context
        return self
    }
    func start() {}
    func stop() {}
    func publish(_ kind: SaysoActivityKind, _ title: String) {
        context?.publish(stackID: title, kind: kind, title: title)
    }
}

/// What the module reports through a bare context, so "reported once" can be counted exactly.
private final class Reports: @unchecked Sendable {
    var failures = 0
    var log: [String] = []
    var tapDuringNextPublish = false
}

private final class RuntimeBox: @unchecked Sendable {
    var runtime: SaysoModuleRuntime?
}

private struct Rig {
    let host: SaysoModuleHost
    let module: PrivacyGuardModule
    let devices: FakeDevices
    let scheduler: FakeScheduler
    let clock: Clock
    let capture: SaysoCapture
    let captured: Captured
    let painted: Painted
    let neighbour: Neighbour

    var lines: [SaysoActivity] { host.engine.stack.filter { $0.moduleID == "privacy-guard" } }
    var titles: [String] { lines.map(\.title) }

    @discardableResult
    func tap(_ actionID: String) -> Bool {
        host.perform(actionID: actionID, stackID: PrivacyGuardModule.stackID, moduleID: "privacy-guard")
    }

    /// Sets the device list and lets the next sample run.
    func sample(_ list: [PrivacyDevice]) {
        devices.set(list)
        advance(nextSampleIn)
    }

    /// Seconds until the one pending job.
    var nextSampleIn: TimeInterval { (scheduler.jobs.first ?? clock.now).timeIntervalSince(clock.now) }

    func advance(_ seconds: TimeInterval) {
        clock.now += seconds
        scheduler.runDue(clock.now)
    }

    var retained: Int { (captured.runtimes.last as? SaysoResourceAccounting)?.retainedResources ?? -1 }
}

/// Enables the module next to a neighbour module and lets the first sample run.
private func rig(_ list: [PrivacyDevice] = [builtInMic, builtInCamera]) -> Rig {
    let clock = Clock(), scheduler = FakeScheduler(), captured = Captured(), painted = Painted(), capture = SaysoCapture()
    let devices = FakeDevices(list)
    let module = PrivacyGuardModule(
        port: devices, scheduler: scheduler, now: { clock.now }, isSaysoCapturing: { capture.capturing }
    )
    let neighbour = Neighbour()
    let host = SaysoModuleHost(modules: [Probe(inner: module, captured: captured), neighbour], now: { clock.now })
    host.onActivitiesChanged = { [weak host] in
        painted.changes.append(host?.engine.stack.filter { $0.moduleID == "privacy-guard" }.map(\.title) ?? [])
    }
    host.enable("neighbour")
    host.enable("privacy-guard")
    let rig = Rig(
        host: host, module: module, devices: devices, scheduler: scheduler, clock: clock, capture: capture,
        captured: captured, painted: painted, neighbour: neighbour
    )
    rig.advance(0)
    return rig
}

/// A camera on and the microphone off; for test bodies whose own `rig` hides the free function.
private func cameraRig() -> Rig { rig([builtInMic, builtInCamera.on]) }

@Suite struct PrivacyGuardModuleTests {
    // MARK: Lines

    @Test func theFirstSampleIsAScheduledJobSoEnablingNeverReadsInline() {
        let clock = Clock(), scheduler = FakeScheduler(), devices = FakeDevices([builtInMic.on])
        let module = PrivacyGuardModule(port: devices, scheduler: scheduler, now: { clock.now })
        let host = SaysoModuleHost(modules: [module], now: { clock.now })
        host.enable("privacy-guard")
        #expect(devices.reads == 0)
        #expect(module.snapshot == nil)
        #expect(scheduler.jobs == [clock.now])
    }

    @Test func noRunningDeviceMeansNoLine() throws {
        let rig = rig()
        for _ in 0..<5 { rig.advance(PrivacyGuardModule.idleIntervalSeconds) }
        #expect(rig.devices.reads == 6)
        #expect(rig.lines.isEmpty)
        let neverPainted = rig.painted.changes.allSatisfy(\.isEmpty)
        #expect(neverPainted, "never painted a privacy line")
        let snapshot = try #require(rig.module.snapshot)
        #expect(snapshot.microphone == .notInUse)
        #expect(snapshot.camera == .notInUse)
        #expect(snapshot.microphone.text == "Not in use")
    }

    @Test func aMacWithNoCameraReadsNoneFoundForIt() throws {
        let rig = rig([builtInMic])
        let snapshot = try #require(rig.module.snapshot)
        #expect(snapshot.camera == .noneFound)
        #expect(snapshot.camera.text == "None found")
        #expect(snapshot.microphone == .notInUse)
        rig.sample([])
        #expect(rig.module.snapshot?.microphone == .noneFound)
    }

    @Test func aMicrophoneOnForTwoSamplesInARowShowsALineNamingIt() throws {
        let rig = rig([builtInMic.on, builtInCamera])
        #expect(rig.lines.isEmpty, "seen once: could be a brief probe")
        #expect(rig.module.snapshot?.microphone == .notInUse, "the row waits for the same debounce as the line")
        rig.advance(PrivacyGuardModule.idleIntervalSeconds)
        let line = try #require(rig.lines.first)
        #expect(rig.lines.count == 1)
        #expect(line.stackID == PrivacyGuardModule.stackID)
        #expect(line.title == "Microphone in use · MacBook Pro Microphone")
        #expect(line.kind == .activeTask)
        #expect(line.interruption == .normal)
        #expect(line.expiresAfter == nil)
        #expect(line.progress == nil)
        #expect(line.actions.map(\.id) == ["dismiss"])
        #expect(rig.module.snapshot?.microphone == .inUse)
        #expect(rig.module.snapshot?.microphone.text == "In use")
        #expect(rig.module.snapshot?.camera == .notInUse)
    }

    @Test func aCameraShowsCameraInUseAndBothShowOneLineWithoutAName() {
        let rig = rig([builtInMic, builtInCamera.on])
        rig.advance(PrivacyGuardModule.idleIntervalSeconds)
        #expect(rig.titles == ["Camera in use · FaceTime HD Camera"])
        rig.sample([builtInMic.on, builtInCamera.on])
        rig.sample([builtInMic.on, builtInCamera.on])
        #expect(rig.titles == ["Camera and microphone in use"], "two devices: no single name to give")
        #expect(rig.module.snapshot?.camera == .inUse)
        #expect(rig.module.snapshot?.microphone == .inUse)
    }

    @Test func twoMicrophonesOnAtOnceAreNotNamed() {
        let rig = rig([builtInMic.on, usbMic.on])
        rig.advance(PrivacyGuardModule.idleIntervalSeconds)
        #expect(rig.titles == ["Microphone in use"])
    }

    @Test func aBriefProbeSeenOnlyOnceNeverShows() {
        let rig = rig([builtInMic.on, builtInCamera])
        rig.sample([builtInMic, builtInCamera])
        rig.sample([builtInMic, builtInCamera.on])
        rig.sample([builtInMic, builtInCamera])
        #expect(rig.lines.isEmpty)
        let neverPainted = rig.painted.changes.allSatisfy(\.isEmpty)
        #expect(neverPainted, "never painted a privacy line")
        #expect(rig.module.snapshot?.microphone == .notInUse)
    }

    @Test func theLineClearsOnlyAfterTwoSamplesInARowReadOff() {
        let rig = rig([builtInMic.on])
        rig.advance(PrivacyGuardModule.idleIntervalSeconds)
        #expect(rig.titles == ["Microphone in use · MacBook Pro Microphone"])
        rig.sample([builtInMic])
        #expect(rig.titles == ["Microphone in use · MacBook Pro Microphone"], "off once: could be a gap between calls")
        #expect(rig.module.snapshot?.microphone == .inUse)
        rig.sample([builtInMic.on])
        rig.sample([builtInMic])
        #expect(rig.lines.count == 1, "off, on, off is never two offs in a row")
        rig.sample([builtInMic])
        #expect(rig.lines.isEmpty)
        #expect(rig.module.snapshot?.microphone == .notInUse)
    }

    @Test func saysoListeningIsNotHiddenButTheMicrophoneLineSaysSaysoMayBeTheOne() {
        let rig = rig([builtInMic.on, builtInCamera])
        rig.capture.capturing = true
        rig.advance(PrivacyGuardModule.idleIntervalSeconds)
        #expect(rig.titles == ["Microphone in use · MacBook Pro Microphone · Sayso may be the one using it"])

        rig.capture.capturing = false
        rig.sample([builtInMic.on, builtInCamera])
        #expect(rig.titles == ["Microphone in use · MacBook Pro Microphone"], "the note follows the host")

        let camera = cameraRig()
        camera.capture.capturing = true
        camera.advance(PrivacyGuardModule.idleIntervalSeconds)
        #expect(camera.titles == ["Camera in use · FaceTime HD Camera"], "Sayso never uses a camera")
    }

    @Test func blankOrLongDeviceNamesStayReadable() {
        let blank = rig([builtInMic.with { $0.name = "  \n " }.on])
        blank.advance(PrivacyGuardModule.idleIntervalSeconds)
        #expect(blank.titles == ["Microphone in use"])

        let long = rig([builtInMic.with { $0.name = "Studio\nMic " + String(repeating: "x", count: 200) }.on])
        long.advance(PrivacyGuardModule.idleIntervalSeconds)
        let title = long.titles.first ?? ""
        #expect(title.hasPrefix("Microphone in use · Studio Mic xxx"))
        #expect(!title.contains("\n"))
        #expect(title.count <= "Microphone in use · ".count + PrivacyGuardModule.nameLimit)
    }

    @Test func aLineIsRepublishedOnlyWhenItsTextChanges() {
        let rig = rig([builtInMic.on])
        rig.advance(PrivacyGuardModule.idleIntervalSeconds)
        let before = rig.painted.changes.count
        for _ in 0..<6 { rig.advance(rig.nextSampleIn) }
        #expect(rig.painted.changes.count == before, "same text, same line: no repaint")
    }

    // MARK: Rank

    /// Active task: a device left on is ongoing, like a running task. Above every ambient offer (clean link, file
    /// shelf, system stats lines), media and clocks, so none of those can hide it; below completion, failure and
    /// confirmation, so a finished timer, an error or an approval is never hidden behind it. A completion rank would
    /// tie with short notices and, published first, hide them for their whole life.
    @Test func itRanksAboveAmbientMediaAndClocksAndBelowCompletionFailureAndConfirmation() {
        let rig = rig([builtInMic.on])
        rig.neighbour.publish(.ambient, "Clean link")
        rig.neighbour.publish(.media, "Song · Artist")
        rig.neighbour.publish(.background, "Tokyo 09:00")
        rig.advance(PrivacyGuardModule.idleIntervalSeconds)
        #expect(rig.host.engine.primary?.moduleID == "privacy-guard", "lower lines published first cannot hide it")

        for kind in [SaysoActivityKind.completion, .failure, .confirmation] {
            rig.neighbour.publish(kind, "\(kind)")
            #expect(rig.host.engine.primary?.title == "\(kind)", "\(kind) outranks the privacy line")
            rig.host.dismiss(moduleID: "neighbour", stackID: "\(kind)")
            #expect(rig.host.engine.primary?.moduleID == "privacy-guard", "and the privacy line returns after it")
        }
        rig.neighbour.publish(.ambient, "Another offer")
        #expect(rig.host.engine.primary?.moduleID == "privacy-guard")
    }

    // MARK: Dismiss

    @Test func dismissHidesTheLineUntilTheDeviceIsOffAndReturnsWhenItIsOnAgain() {
        let rig = rig([builtInMic.on])
        rig.advance(PrivacyGuardModule.idleIntervalSeconds)
        #expect(rig.tap("dismiss"))
        #expect(rig.scheduler.jobs == [rig.clock.now], "the job applies the dismissal")
        let reads = rig.devices.reads
        rig.advance(0)
        #expect(rig.devices.reads == reads, "a repaint is not a sample")
        #expect(rig.lines.isEmpty)
        #expect(rig.module.snapshot?.microphone == .inUse, "the row still says what is true")

        rig.sample([builtInMic.on])
        rig.sample([builtInMic.on])
        #expect(rig.lines.isEmpty, "still on: stays hidden")
        rig.sample([builtInMic])
        rig.sample([builtInMic])
        #expect(rig.lines.isEmpty)
        rig.sample([builtInMic.on])
        rig.sample([builtInMic.on])
        #expect(rig.titles == ["Microphone in use · MacBook Pro Microphone"], "off, then on again: it returns")
    }

    @Test func aCameraSwitchedOnAfterTheMicrophoneWasDismissedShowsAgain() {
        let rig = rig([builtInMic.on, builtInCamera])
        rig.advance(PrivacyGuardModule.idleIntervalSeconds)
        rig.tap("dismiss")
        rig.advance(0)
        #expect(rig.lines.isEmpty)
        rig.sample([builtInMic.on, builtInCamera.on])
        rig.sample([builtInMic.on, builtInCamera.on])
        #expect(rig.titles == ["Camera and microphone in use"], "a camera coming on is new, so it is not hidden")
    }

    @Test func dismissWithNoLineShownChangesNothing() {
        let rig = rig([builtInMic])
        let jobs = rig.scheduler.jobs
        #expect(rig.tap("dismiss") == false, "no line, no declared action")
        rig.captured.runtimes.last?.handle(stackID: PrivacyGuardModule.stackID, actionID: "dismiss")
        #expect(rig.scheduler.jobs == jobs, "nothing to hide, so nothing is armed early")
    }

    @Test func aDismissLandingWhileALineIsPublishingNeverLeavesAGhostLine() {
        let clock = Clock(), scheduler = FakeScheduler(), reports = Reports()
        let devices = FakeDevices([builtInMic.on])
        let module = PrivacyGuardModule(port: devices, scheduler: scheduler, now: { clock.now })
        let box = RuntimeBox()
        let runtime = module.makeRuntime(context: SaysoModuleContext(
            moduleID: "privacy-guard",
            publish: { activity in
                // The user taps Dismiss on the old line between the sample deciding to repaint and the repaint.
                if reports.tapDuringNextPublish {
                    reports.tapDuringNextPublish = false
                    box.runtime?.handle(stackID: activity.stackID, actionID: "dismiss")
                }
                reports.log.append("show \(activity.title)")
            },
            dismiss: { reports.log.append("clear \($0)") }
        ))
        box.runtime = runtime
        func advance(_ seconds: TimeInterval) {
            clock.now += seconds
            scheduler.runDue(clock.now)
        }
        runtime.start()
        advance(0)
        advance(PrivacyGuardModule.idleIntervalSeconds)
        #expect(reports.log == ["show Microphone in use · MacBook Pro Microphone"])
        reports.tapDuringNextPublish = true
        devices.set([builtInMic.on, builtInCamera.on])
        advance(PrivacyGuardModule.watchedIntervalSeconds)
        advance(PrivacyGuardModule.watchedIntervalSeconds)
        advance(0)
        #expect(reports.log.last == "clear privacy-guard", "the dismissed line ends up cleared: \(reports.log)")
    }

    // MARK: Cadence

    @Test func unwatchedWithNoLineItSamplesEveryFiveSecondsWithOneJob() {
        let rig = rig()
        #expect(rig.devices.reads == 1)
        #expect(rig.scheduler.jobs == [rig.clock.now + PrivacyGuardModule.idleIntervalSeconds])
        rig.advance(PrivacyGuardModule.idleIntervalSeconds - 1)
        #expect(rig.devices.reads == 1)
        rig.advance(1)
        #expect(rig.devices.reads == 2)
        #expect(rig.scheduler.jobs.count == 1)
    }

    @Test func whileTheStudioPaneIsWatchedItSamplesEveryTwoSeconds() {
        let rig = rig()
        rig.module.setObserved(true)
        #expect(rig.scheduler.jobs == [rig.clock.now + PrivacyGuardModule.watchedIntervalSeconds])
        rig.advance(PrivacyGuardModule.watchedIntervalSeconds)
        #expect(rig.devices.reads == 2)
        rig.module.setObserved(false)
        #expect(rig.scheduler.jobs == [rig.clock.now + PrivacyGuardModule.idleIntervalSeconds])
        #expect(rig.scheduler.jobs.count == 1)
    }

    @Test func whileALineShowsItSamplesEveryTwoSecondsSoItClearsPromptly() {
        let rig = rig([builtInMic.on])
        #expect(rig.nextSampleIn == PrivacyGuardModule.idleIntervalSeconds, "seen once is not a line yet")
        rig.advance(PrivacyGuardModule.idleIntervalSeconds)
        #expect(rig.lines.count == 1)
        #expect(rig.scheduler.jobs == [rig.clock.now + PrivacyGuardModule.watchedIntervalSeconds])
        rig.sample([builtInMic])
        rig.sample([builtInMic])
        #expect(rig.lines.isEmpty)
        #expect(rig.scheduler.jobs == [rig.clock.now + PrivacyGuardModule.idleIntervalSeconds], "no line: back to 5 s")

        rig.sample([builtInMic.on])
        rig.sample([builtInMic.on])
        rig.tap("dismiss")
        rig.advance(0)
        #expect(rig.scheduler.jobs == [rig.clock.now + PrivacyGuardModule.idleIntervalSeconds], "a hidden line is not shown")
    }

    @Test func aWatchChangeNeverPushesAPendingDismissOrClockChangeLater() {
        let rig = rig([builtInMic.on])
        rig.advance(PrivacyGuardModule.idleIntervalSeconds)
        rig.tap("dismiss")
        rig.module.setObserved(true)
        rig.module.setObserved(false)
        #expect(rig.scheduler.jobs == [rig.clock.now], "the dismissal still lands at once")
        rig.advance(0)
        #expect(rig.lines.isEmpty)

        rig.advance(1)
        rig.module.clockChanged()
        rig.module.setObserved(true)
        #expect(rig.scheduler.jobs == [rig.clock.now], "the clock change still samples at once")
    }

    @Test func aClockSetBackSamplesAtOnceInsteadOfWaitingForTheOldTime() {
        let rig = rig()
        rig.clock.now -= 3_600
        rig.module.clockChanged()
        #expect(rig.scheduler.jobs == [rig.clock.now], "the pending job was set against the old time")
        rig.advance(0)
        #expect(rig.devices.reads == 2)
        #expect(rig.scheduler.jobs == [rig.clock.now + PrivacyGuardModule.idleIntervalSeconds])
    }

    // MARK: Device list changes

    @Test func aMicrophonePluggedInAndRemovedLeavesNoStaleEntry() {
        let rig = rig([builtInMic, builtInCamera])
        rig.sample([builtInMic, usbMic.on, builtInCamera])
        #expect(rig.lines.isEmpty, "a new device needs two samples like any other")
        rig.sample([builtInMic, usbMic.on, builtInCamera])
        #expect(rig.titles == ["Microphone in use · Yeti Stereo Microphone"])

        rig.sample([builtInMic, builtInCamera])
        #expect(rig.lines.isEmpty, "a device that is gone cannot be in use: no line waits on it")
        #expect(rig.module.snapshot?.microphone == .notInUse)

        rig.sample([builtInMic, usbMic.on, builtInCamera])
        #expect(rig.lines.isEmpty, "plugged in again it starts over")
        rig.sample([builtInMic, usbMic.on, builtInCamera])
        #expect(rig.titles == ["Microphone in use · Yeti Stereo Microphone"])
    }

    @Test func aRenamedDeviceKeepsItsStateAndShowsItsNewName() {
        let rig = rig([builtInMic.on])
        rig.advance(PrivacyGuardModule.idleIntervalSeconds)
        rig.sample([builtInMic.with { $0.name = "Desk Microphone" }.on])
        #expect(rig.titles == ["Microphone in use · Desk Microphone"])
    }

    @Test func aMicrophoneAndACameraSharingAnIdAreTwoDevices() {
        let mic = builtInMic.with { $0.id = "shared" }, camera = builtInCamera.with { $0.id = "shared" }
        let rig = rig([mic.on, camera])
        rig.advance(PrivacyGuardModule.idleIntervalSeconds)
        #expect(rig.module.snapshot?.microphone == .inUse)
        #expect(rig.module.snapshot?.camera == .notInUse)
    }

    // MARK: Failures

    @Test func aFailingReadIsReportedOnceBacksOffAndAStillRunningDeviceShowsAgainAfter() {
        let clock = Clock(), scheduler = FakeScheduler(), reports = Reports(), devices = FakeDevices([builtInMic.on])
        let module = PrivacyGuardModule(port: devices, scheduler: scheduler, now: { clock.now })
        let runtime = module.makeRuntime(context: SaysoModuleContext(
            moduleID: "privacy-guard",
            publish: { reports.log.append("show \($0.title)") },
            reportFailure: { reports.failures += 1 },
            dismiss: { reports.log.append("clear \($0)") }
        ))
        func advance(_ seconds: TimeInterval) {
            clock.now += seconds
            scheduler.runDue(clock.now)
        }
        module.setObserved(true)
        runtime.start()
        advance(0)
        advance(PrivacyGuardModule.watchedIntervalSeconds)
        #expect(reports.log == ["show Microphone in use · MacBook Pro Microphone"])

        devices.fail(.unavailable)
        advance(PrivacyGuardModule.watchedIntervalSeconds)
        #expect(reports.failures == 1)
        #expect(module.snapshot == nil, "a failed read cannot vouch for anything")
        #expect(reports.log.last == "clear privacy-guard", "nor for the old line")
        #expect(scheduler.jobs == [clock.now + PrivacyGuardModule.failureBackoffSeconds], "backs off even while watched")
        for _ in 0..<5 { advance(PrivacyGuardModule.failureBackoffSeconds) }
        #expect(devices.reads == 8)
        #expect(reports.failures == 1, "a lasting failure is reported once, not on every sample")

        devices.fail(nil)
        advance(PrivacyGuardModule.failureBackoffSeconds)
        #expect(module.snapshot?.microphone == .inUse, "seen on before the outage and on after it")
        #expect(reports.log.last == "show Microphone in use · MacBook Pro Microphone")
        #expect(scheduler.jobs == [clock.now + PrivacyGuardModule.watchedIntervalSeconds])
    }

    @Test func aLastingFailureLeavesTheModuleDegradedNeverQuarantined() {
        let rig = rig()
        rig.devices.fail(.unavailable)
        rig.advance(PrivacyGuardModule.idleIntervalSeconds)
        #expect(rig.host.health(of: "privacy-guard") == .degraded)
        for _ in 0..<40 { rig.advance(PrivacyGuardModule.failureBackoffSeconds) }
        #expect(rig.host.health(of: "privacy-guard") != .quarantined)
        for _ in 0..<5 {
            rig.devices.fail(nil)
            rig.advance(PrivacyGuardModule.failureBackoffSeconds)
            rig.devices.fail(.unavailable)
            rig.advance(PrivacyGuardModule.idleIntervalSeconds)
        }
        #expect(rig.host.health(of: "privacy-guard") != .quarantined, "flaky reads within five minutes report at most once")
    }

    @Test func aFailedReadBreaksAStreakSoTwoOnReadsMustBeConsecutive() {
        let rig = rig([builtInMic.on])
        rig.devices.fail(.unavailable)
        rig.advance(PrivacyGuardModule.idleIntervalSeconds)
        rig.devices.fail(nil)
        rig.advance(PrivacyGuardModule.failureBackoffSeconds)
        #expect(rig.lines.isEmpty, "on, failed, on is not two samples in a row")
        rig.advance(PrivacyGuardModule.idleIntervalSeconds)
        #expect(rig.lines.count == 1)
    }

    @Test func aFailedReadKeepsADismissal() {
        let rig = rig([builtInMic.on])
        rig.advance(PrivacyGuardModule.idleIntervalSeconds)
        rig.tap("dismiss")
        rig.advance(0)
        rig.devices.fail(.unavailable)
        rig.advance(rig.nextSampleIn)
        rig.devices.fail(nil)
        rig.advance(rig.nextSampleIn)
        rig.advance(rig.nextSampleIn)
        #expect(rig.lines.isEmpty, "dismissed and still on: an outage in between does not bring it back")
    }

    @Test func aFailureReportedBeforeTheClockWentBackDoesNotSilenceTheNextOne() {
        let clock = Clock(), scheduler = FakeScheduler(), reports = Reports(), devices = FakeDevices([builtInMic])
        let module = PrivacyGuardModule(port: devices, scheduler: scheduler, now: { clock.now })
        let runtime = module.makeRuntime(context: SaysoModuleContext(
            moduleID: "privacy-guard", publish: { _ in }, reportFailure: { reports.failures += 1 }
        ))
        func advance(_ seconds: TimeInterval) {
            clock.now += seconds
            scheduler.runDue(clock.now)
        }
        runtime.start()
        devices.fail(.unavailable)
        advance(0)
        #expect(reports.failures == 1)
        devices.fail(nil)
        clock.now -= 3_600
        module.clockChanged()
        advance(PrivacyGuardModule.failureReportWindowSeconds)
        devices.fail(.unavailable)
        advance(PrivacyGuardModule.idleIntervalSeconds)
        #expect(reports.failures == 2, "a new failure a full window after the last report is reported")
    }

    // MARK: Off

    @Test func disableCancelsTheJobPurgesEverythingAndAFreshStartDebouncesAgain() {
        let rig = rig([builtInMic.on])
        rig.advance(PrivacyGuardModule.idleIntervalSeconds)
        rig.module.setObserved(true)
        #expect(rig.retained == 1)
        rig.host.disable("privacy-guard")
        #expect(rig.retained == 0)
        #expect(rig.scheduler.jobs.isEmpty)
        #expect(rig.module.snapshot == nil)
        #expect(rig.lines.isEmpty)
        let reads = rig.devices.reads
        rig.module.setObserved(false)
        rig.module.clockChanged()
        rig.advance(PrivacyGuardModule.idleIntervalSeconds * 10)
        #expect(rig.scheduler.jobs.isEmpty, "a disabled module arms nothing")
        #expect(rig.devices.reads == reads, "and reads nothing")

        rig.host.enable("privacy-guard")
        rig.advance(0)
        #expect(rig.lines.isEmpty, "a fresh start remembers nothing, so it needs two samples again")
        rig.advance(PrivacyGuardModule.idleIntervalSeconds)
        #expect(rig.lines.count == 1)
    }

    /// The app applies `privacyGuardEnabled` through `setEnabled` at launch and on every settings save.
    @Test func theSettingGateKeepsTheGuardOffAtLaunchAndPurgesItWhenTurnedOff() {
        let clock = Clock(), scheduler = FakeScheduler(), captured = Captured(), devices = FakeDevices([builtInMic.on])
        let module = PrivacyGuardModule(port: devices, scheduler: scheduler, now: { clock.now })
        let host = SaysoModuleHost(modules: [Probe(inner: module, captured: captured)], now: { clock.now })
        let lines = { host.engine.stack.filter { $0.moduleID == "privacy-guard" } }

        host.setEnabled("privacy-guard", false)
        module.clockChanged()
        scheduler.runDue(clock.now)
        #expect(host.health(of: "privacy-guard") == .disabled)
        #expect(captured.runtimes.isEmpty, "off at launch never starts a runtime")
        #expect(scheduler.jobs.isEmpty)
        #expect(devices.reads == 0)

        host.setEnabled("privacy-guard", true)
        scheduler.runDue(clock.now)
        clock.now += PrivacyGuardModule.idleIntervalSeconds
        scheduler.runDue(clock.now)
        let runtime = captured.runtimes.last as? SaysoResourceAccounting
        #expect(lines().map(\.title) == ["Microphone in use · MacBook Pro Microphone"])
        #expect(runtime?.retainedResources == 1)

        host.setEnabled("privacy-guard", false)
        #expect(host.health(of: "privacy-guard") == .disabled)
        #expect(runtime?.retainedResources == 0)
        #expect(scheduler.jobs.isEmpty)
        #expect(module.snapshot == nil, "turning it off forgets what it read")
        #expect(lines().isEmpty, "turning it off clears its notch line")
    }

    @Test func passesTheModuleAcceptanceContract() {
        let module = PrivacyGuardModule(port: FakeDevices([]), scheduler: FakeScheduler())
        #expect(SaysoModuleAcceptance.violations(for: module) == [])
        #expect(module.descriptor.id == "privacy-guard")
        #expect(module.descriptor.capabilities.isEmpty, "reading whether a device is on needs no permission")
    }

    // MARK: UI test hook

    @Test func theUITestHookIsHonouredOnlyWithFreshSettings() throws {
        #expect(PrivacyGuardUITestHook.port(arguments: ["app", "--ui-test-privacy", "mic"]) == nil, "a real launch uses the real devices")
        #expect(PrivacyGuardUITestHook.port(arguments: ["app", "--ui-test-fresh-settings"]) == nil)

        func running(_ value: String?) throws -> [PrivacyDeviceKind] {
            let arguments = ["app", "--ui-test-fresh-settings", "--ui-test-privacy"] + (value.map { [$0] } ?? [])
            let port = try #require(PrivacyGuardUITestHook.port(arguments: arguments))
            let devices = try port.devices()
            #expect(Set(devices.map(\.kind)) == [.microphone, .camera], "one fake microphone and one fake camera")
            return devices.filter(\.isRunning).map(\.kind)
        }
        #expect(try running("mic") == [.microphone])
        #expect(try running("camera") == [.camera])
        #expect(Set(try running("both")) == [.microphone, .camera])
        #expect(try running("bogus") == [], "an unknown value is a fake with nothing on, never the real devices")
        #expect(try running(nil) == [])
    }
}
