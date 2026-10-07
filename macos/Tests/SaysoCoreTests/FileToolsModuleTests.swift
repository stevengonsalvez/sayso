import Foundation
import Testing
@testable import SaysoCore

// MARK: Paths and names

@Suite struct FileToolsPathsTests {
    @Test func pathsAreOnePerLineOrCommaSeparated() throws {
        #expect(try FileToolsPaths.parse("/in/a.txt\n/other/b.txt").map(\.path) == ["/in/a.txt", "/other/b.txt"])
        #expect(try FileToolsPaths.parse("/in/a.txt, /other/b.txt").map(\.path) == ["/in/a.txt", "/other/b.txt"])
        #expect(try FileToolsPaths.parse("  /in/a.txt  \r\n\n\n/in/b.txt,/in/c.txt\n").map(\.path) == ["/in/a.txt", "/in/b.txt", "/in/c.txt"])
    }

    @Test func aCommaInsideAFileNameKeepsTheLineWhole() throws {
        #expect(try FileToolsPaths.parse("/in/Invoice, March.pdf").map(\.path) == ["/in/Invoice, March.pdf"])
    }

    @Test func aHomePathIsExpandedAndARelativePathIsRefused() throws {
        let home = try FileToolsPaths.parse("~/notes.txt")
        #expect(home.map(\.path) == [NSHomeDirectory() + "/notes.txt"])
        #expect(throws: FileToolsError.relativePath("docs/a.png")) { try FileToolsPaths.parse("/in/b.png\ndocs/a.png") }
        #expect(try FileToolsPaths.parse("  \n ").isEmpty)
    }

    @Test func outputNamesCountUpFromTwoBeforeTheExtension() {
        #expect(Array(FileToolsPaths.outputNames(for: "Archive.zip").prefix(3)) == ["Archive.zip", "Archive 2.zip", "Archive 3.zip"])
        #expect(Array(FileToolsPaths.outputNames(for: "notes.txt.zip").prefix(2)) == ["notes.txt.zip", "notes.txt 2.zip"])
        #expect(Array(FileToolsPaths.outputNames(for: "README").prefix(2)) == ["README", "README 2"])
        #expect(Array(FileToolsPaths.outputNames(for: ".profile").prefix(2)) == [".profile", ".profile 2"])
        #expect(FileToolsPaths.outputNames(for: "Archive.zip").count == FileToolsPaths.maxOutputNames)
    }
}

// MARK: Module

@Suite struct FileToolsModuleTests {
    @Test func passesTheModuleAcceptanceContract() {
        let module = FileToolsModule(port: FakeFileTools(), scheduler: FileToolsScheduler(), worker: ManualWorker().worker)
        #expect(SaysoModuleAcceptance.violations(for: module) == [])
    }

    @Test func refusesEverythingWhileOff() {
        let rig = FileToolsRig(enabled: false)
        rig.port.add(file("/in/a.txt"))
        #expect(rig.module.run(.zip, paths: "/in/a.txt") == .off)
        #expect(rig.worker.pending == 0)
        #expect(rig.module.status == .idle)
    }

    @Test func aZipOfTwoFilesIsNamedArchiveAndWrittenBesideTheFirst() throws {
        let rig = FileToolsRig()
        rig.port.add(file("/in/a.txt", bytes: 10), file("/other/b.txt", bytes: 20))
        #expect(rig.module.run(.zip, paths: "/in/a.txt\n/other/b.txt") == nil)
        #expect(rig.module.status == .running("Zipping 2 items", progress: nil))
        #expect(rig.shown?.kind == .activeTask)
        #expect(rig.shown?.title == "Zipping 2 items")
        #expect(rig.shown?.actions.map(\.id) == ["cancel"])

        rig.worker.runAll()

        let job = try #require(rig.port.jobs.first)
        #expect(job.tool == .zip)
        #expect(job.inputs.map(\.url.path) == ["/in/a.txt", "/other/b.txt"])
        #expect(job.folder.path == "/in")
        #expect(job.name == "Archive.zip")
        #expect(rig.module.status == .done(URL(fileURLWithPath: "/in/Archive.zip")))
        #expect(rig.shown?.kind == .completion)
        #expect(rig.shown?.title == "Saved Archive.zip")
        #expect(rig.shown?.expiresAfter == FileToolsModule.noticeSeconds)
        #expect(rig.shown?.actions.map(\.id) == ["dismiss"])
    }

    @Test func aSingleItemZipIsNamedAfterIt() throws {
        let rig = FileToolsRig()
        rig.port.add(file("/in/notes.txt"), folder("/in/Photos", bytes: 500))
        rig.module.run(.zip, paths: "/in/notes.txt")
        rig.worker.runAll()
        rig.module.run(.zip, paths: "/in/Photos")
        rig.worker.runAll()
        #expect(rig.port.jobs.map(\.name) == ["notes.txt.zip", "Photos.zip"])
        #expect(rig.port.jobs.last?.inputs.first?.kind == .directory)
        #expect(rig.module.status == .done(URL(fileURLWithPath: "/in/Photos.zip")))
    }

    @Test func imageConversionIsNamedAfterTheImageWithTheNewExtension() throws {
        let rig = FileToolsRig()
        rig.port.add(file("/in/holiday.final.png", type: .png), file("/in/shot.heic", type: .heic))
        rig.module.run(.convertImage(.jpeg, quality: 0.8), paths: "/in/holiday.final.png")
        #expect(rig.module.status == .running("Converting holiday.final.png to JPEG", progress: nil))
        rig.worker.runAll()
        rig.module.run(.convertImage(.png, quality: FileToolsModule.defaultQuality), paths: "/in/shot.heic")
        rig.worker.runAll()
        #expect(rig.port.jobs.map(\.name) == ["holiday.final.jpg", "shot.png"])
        #expect(rig.port.jobs.first?.tool == .convertImage(.jpeg, quality: 0.8))
        rig.module.run(.convertImage(.heic, quality: 0.5), paths: "/in/holiday.final.png")
        rig.worker.runAll()
        #expect(rig.port.jobs.last?.name == "holiday.final.heic")
    }

    @Test func aPdfMergeKeepsTheGivenOrder() throws {
        let rig = FileToolsRig()
        rig.port.add(file("/in/c.pdf", type: .pdf), file("/in/a.pdf", type: .pdf), file("/elsewhere/b.pdf", type: .pdf))
        rig.module.run(.mergePDFs, paths: "/in/c.pdf, /in/a.pdf, /elsewhere/b.pdf")
        #expect(rig.module.status == .running("Merging 3 PDFs", progress: nil))
        rig.worker.runAll()
        let job = try #require(rig.port.jobs.first)
        #expect(job.inputs.map(\.url.lastPathComponent) == ["c.pdf", "a.pdf", "b.pdf"])
        #expect(job.name == "Merged.pdf")
        #expect(job.folder.path == "/in")
    }

    @Test(arguments: FileToolsRefusal.all)
    func refusalsNameTheReasonOnceAndNeverReachThePort(_ refusal: FileToolsRefusal) {
        let rig = FileToolsRig()
        rig.port.add(
            file("/in/a.txt"), file("/in/b.txt"), file("/in/photo.png", type: .png), file("/in/one.pdf", type: .pdf),
            file("/in/two.pdf", type: .pdf), file("/in/empty.txt", bytes: 0), folder("/in/Photos", bytes: 10),
            file("/in/link.png", type: .png, escapes: true), folder("/in/Linked", bytes: 10, escapes: true),
            file("/in/big1.bin", bytes: 1_500_000_000), file("/in/big2.bin", bytes: 600_000_000),
            file("/in/huge1.bin", bytes: Int64.max), file("/in/huge2.bin", bytes: Int64.max),
            file("/other/a.txt"), file("/in/A.TXT"), FileToolsInput(url: URL(fileURLWithPath: "/in/pipe"), kind: .other)
        )
        let returned = rig.module.run(refusal.tool, paths: refusal.paths)
        rig.worker.runAll()

        #expect(rig.port.jobs.isEmpty, "the port never runs a refused job")
        #expect(rig.module.status == .failed(refusal.error))
        #expect(refusal.error.message == refusal.message)
        let failures = rig.log.published.filter { $0.kind == .failure }
        #expect(failures.map(\.title) == [refusal.message], "one failure notice with the reason")
        #expect(failures.first?.expiresAfter == FileToolsModule.noticeSeconds)
        #expect(rig.log.reports == 0, "a refused input is the user's to fix, not a module failure")
        if refusal.checkedBeforeWork { #expect(returned == refusal.error) } else { #expect(returned == nil) }
    }

    @Test func onlyOneJobRunsAtATimeAndABusyPressChangesNothing() {
        let rig = FileToolsRig()
        rig.port.add(file("/in/a.txt"), file("/in/b.txt"))
        #expect(rig.module.run(.zip, paths: "/in/a.txt") == nil)
        #expect(rig.module.run(.zip, paths: "/in/b.txt") == .busy)
        #expect(rig.module.run(.zip, paths: "relative") == .busy, "busy is checked before the paths")
        #expect(rig.module.status == .running("Zipping a.txt", progress: nil))
        #expect(rig.worker.pending == 1)
        rig.worker.runAll()
        #expect(rig.port.jobs.map(\.name) == ["a.txt.zip"])
        #expect(rig.module.run(.zip, paths: "/in/b.txt") == nil, "free again once the job is done")
    }

    @Test func cancelStopsTheJobLeavesNoNoticeAndRemovesAnOutputThatLandedAnyway() throws {
        let rig = FileToolsRig()
        rig.port.add(file("/in/a.txt"))
        rig.port.during = { rig.module.cancel() }
        rig.module.run(.zip, paths: "/in/a.txt")
        rig.worker.runAll()

        #expect(rig.port.cancellations.first?.isCancelled == true)
        #expect(rig.port.removed.map(\.path) == ["/in/a.txt.zip"], "the port finished anyway, so its output goes")
        #expect(rig.module.status == .cancelled)
        #expect(rig.shown == nil)
        #expect(rig.log.reports == 0)
        #expect(rig.scheduler.jobs.isEmpty)
    }

    @Test func aCancelBeforeTheWorkerStartsNeverTouchesThePort() {
        let rig = FileToolsRig()
        rig.port.add(file("/in/a.txt"))
        rig.module.run(.zip, paths: "/in/a.txt")
        rig.module.cancel()
        #expect(rig.module.status == .cancelling)
        rig.worker.runAll()
        #expect(rig.port.inspected.isEmpty)
        #expect(rig.port.jobs.isEmpty)
        #expect(rig.module.status == .cancelled)
    }

    @Test func theNotchCancelActionCancelsTheJob() {
        let rig = FileToolsRig()
        rig.port.add(file("/in/a.txt"))
        rig.module.run(.zip, paths: "/in/a.txt")
        #expect(rig.host.perform(actionID: "cancel", stackID: FileToolsModule.stackID, moduleID: "file-tools"))
        rig.worker.runAll()
        #expect(rig.port.jobs.isEmpty)
        #expect(rig.module.status == .cancelled)
    }

    @Test func progressIsPublishedOncePerWholePercent() {
        let rig = FileToolsRig()
        rig.port.add(file("/in/a.pdf", type: .pdf), file("/in/b.pdf", type: .pdf))
        rig.port.progressSteps = [0.1, 0.104, 0.109, 0.5, 0.5, 1.2, .nan]
        rig.module.run(.mergePDFs, paths: "/in/a.pdf\n/in/b.pdf")
        rig.worker.runAll()
        let running = rig.log.published.filter { $0.kind == .activeTask }
        #expect(running.map(\.progress) == [nil, 0.1, 0.5, 1.0])
        #expect(running.allSatisfy { $0.title == "Merging 2 PDFs" && $0.actions.map(\.id) == ["cancel"] })
    }

    @Test func theNoticeEndsAfterTenSecondsAndAnOlderTimerNeverEndsANewerNotice() {
        let rig = FileToolsRig()
        rig.port.add(file("/in/a.txt"), file("/in/b.txt"))
        rig.module.run(.zip, paths: "/in/a.txt")
        rig.worker.runAll()
        #expect(rig.scheduler.jobs == [rig.clock.now.addingTimeInterval(FileToolsModule.noticeSeconds)])
        let olderTimer = rig.scheduler.snatchEarliest()

        rig.clock.now += 3
        rig.module.run(.zip, paths: "/in/b.txt")
        #expect(rig.scheduler.jobs.isEmpty, "a new job ends the old notice's timer")
        rig.worker.runAll()
        olderTimer?()
        #expect(rig.shown?.title == "Saved b.txt.zip", "a timer already under way for the old notice changed nothing")

        rig.clock.now += FileToolsModule.noticeSeconds
        rig.scheduler.runDue(rig.clock.now)
        #expect(rig.shown == nil)
        #expect(rig.module.status == .done(URL(fileURLWithPath: "/in/b.txt.zip")), "the pane keeps the outcome")
    }

    @Test func dismissEndsTheNoticeAndItsTimer() {
        let rig = FileToolsRig()
        rig.port.add(file("/in/a.txt"))
        rig.module.run(.zip, paths: "/in/a.txt")
        rig.worker.runAll()
        #expect(rig.host.perform(actionID: "dismiss", stackID: FileToolsModule.stackID, moduleID: "file-tools"))
        #expect(rig.shown == nil)
        #expect(rig.scheduler.jobs.isEmpty)
    }

    @Test func aToolFailureIsShownOnceAndReportedAtMostOncePerQuarantineWindow() {
        let rig = FileToolsRig()
        rig.port.add(file("/in/a.txt"))
        rig.port.failure = .toolFailed("ditto stopped with status 1")
        for _ in 0..<3 {
            rig.module.run(.zip, paths: "/in/a.txt")
            rig.worker.runAll()
            rig.clock.now += 60
        }
        let message = "Could not finish: ditto stopped with status 1"
        #expect(rig.module.status == .failed(.toolFailed("ditto stopped with status 1")))
        #expect(rig.log.published.filter { $0.kind == .failure }.map(\.title) == [message, message, message])
        #expect(rig.log.reports == 1)
        #expect(rig.host.health(of: "file-tools") == .degraded, "never quarantined by repeated failures")

        rig.clock.now += FileToolsModule.failureReportInterval
        rig.module.run(.zip, paths: "/in/a.txt")
        rig.worker.runAll()
        #expect(rig.log.reports == 2)
    }

    @Test func anUnexpectedErrorFromThePortIsShownWithItsDescription() {
        let rig = FileToolsRig()
        rig.port.add(file("/in/a.txt"))
        rig.port.unexpected = CocoaError(.fileWriteOutOfSpace)
        rig.module.run(.zip, paths: "/in/a.txt")
        rig.worker.runAll()
        guard case let .failed(.toolFailed(reason)) = rig.module.status else {
            Issue.record("expected a tool failure, got \(rig.module.status)")
            return
        }
        #expect(!reason.isEmpty)
        #expect(rig.log.reports == 1)
    }

    @Test func disablingCancelsTheJobRemovesItsOutputAndClearsEverything() throws {
        let rig = FileToolsRig()
        rig.port.add(file("/in/a.txt"))
        rig.port.during = { rig.host.setEnabled("file-tools", false) }
        rig.module.run(.zip, paths: "/in/a.txt")
        rig.worker.runAll()

        let runtime = try #require(rig.runtimes.runtimes.first as? SaysoResourceAccounting)
        #expect(runtime.retainedResources == 0)
        #expect(rig.port.cancellations.first?.isCancelled == true)
        #expect(rig.port.removed.map(\.path) == ["/in/a.txt.zip"], "a job that finished after off leaves nothing behind")
        #expect(rig.shown == nil)
        #expect(rig.scheduler.jobs.isEmpty)
        #expect(rig.module.status == .idle)
        #expect(rig.module.run(.zip, paths: "/in/a.txt") == .off)
    }

    @Test func disablingAfterADoneJobClearsTheNoticeAndTheOutcome() throws {
        let rig = FileToolsRig()
        rig.port.add(file("/in/a.txt"))
        rig.module.run(.zip, paths: "/in/a.txt")
        rig.worker.runAll()
        let runtime = try #require(rig.runtimes.runtimes.first as? SaysoResourceAccounting)
        #expect(runtime.retainedResources == 2, "the notice timer and the outcome")

        rig.host.setEnabled("file-tools", false)
        #expect(runtime.retainedResources == 0)
        #expect(rig.scheduler.jobs.isEmpty)
        #expect(rig.shown == nil)
        #expect(rig.module.status == .idle)
        #expect(rig.port.removed.isEmpty, "a finished output is the user's file")
    }

    @Test func aJobFromBeforeOffAndOnChangesNothingInTheNewSession() {
        let rig = FileToolsRig()
        rig.port.add(file("/in/a.txt"), file("/in/b.txt"))
        rig.module.run(.zip, paths: "/in/a.txt")
        rig.host.setEnabled("file-tools", false)
        rig.host.setEnabled("file-tools", true)
        #expect(rig.module.status == .idle)
        rig.worker.runAll()
        #expect(rig.port.jobs.isEmpty, "the old job was cancelled before it reached the port")
        #expect(rig.module.status == .idle)
        #expect(rig.shown == nil)
        #expect(rig.module.run(.zip, paths: "/in/b.txt") == nil, "the new session is not busy with the old job")
    }

    @MainActor
    @Test func theRealWorkerRunsJobsOffTheMainThreadOneAtATime() async throws {
        let port = FakeFileTools()
        port.add(file("/in/a.txt"))
        let module = FileToolsModule(port: port, scheduler: FileToolsScheduler(), worker: .serial(label: "file-tools-test"))
        let host = SaysoModuleHost(modules: [module])
        host.enable("file-tools")
        #expect(module.run(.zip, paths: "/in/a.txt") == nil)
        for _ in 0..<200 where !module.status.isFinished { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(module.status == .done(URL(fileURLWithPath: "/in/a.txt.zip")))
        #expect(port.performedOnMainThread == [false])
    }
}

// MARK: Refusals

struct FileToolsRefusal: CustomTestStringConvertible, Sendable {
    let name: String
    let tool: FileToolsTool
    let paths: String
    let error: FileToolsError
    let message: String
    /// Refused from the paths alone, before the worker looks at a file.
    let checkedBeforeWork: Bool
    var testDescription: String { name }

    static let jpeg = FileToolsTool.convertImage(.jpeg, quality: 0.8)
    static let all: [FileToolsRefusal] = [
        .init(name: "no paths", tool: .zip, paths: " \n ", error: .noInputs,
              message: "Name at least one file: one full path per line, or separated by commas.", checkedBeforeWork: true),
        .init(name: "relative path", tool: .zip, paths: "docs/a.txt", error: .relativePath("docs/a.txt"),
              message: "docs/a.txt is not a full path. Start it with / or ~/.", checkedBeforeWork: true),
        .init(name: "too many", tool: .zip, paths: (0...200).map { "/in/f\($0).txt" }.joined(separator: "\n"),
              error: .tooManyInputs(201), message: "201 items named; file tools take up to 200 at a time.", checkedBeforeWork: true),
        .init(name: "two images", tool: jpeg, paths: "/in/photo.png\n/in/photo.png", error: .oneImageAtATime,
              message: "Convert one image at a time.", checkedBeforeWork: true),
        .init(name: "quality too low", tool: .convertImage(.jpeg, quality: 0.05), paths: "/in/photo.png",
              error: .qualityOutOfRange, message: "Quality must be between 0.1 and 1.", checkedBeforeWork: true),
        .init(name: "quality not a number", tool: .convertImage(.heic, quality: .nan), paths: "/in/photo.png",
              error: .qualityOutOfRange, message: "Quality must be between 0.1 and 1.", checkedBeforeWork: true),
        .init(name: "one pdf", tool: .mergePDFs, paths: "/in/one.pdf", error: .needsTwoPDFs,
              message: "Name at least two PDFs to merge.", checkedBeforeWork: true),
        .init(name: "missing", tool: .zip, paths: "/in/a.txt\n/in/gone.txt", error: .missing("gone.txt"),
              message: "gone.txt does not exist.", checkedBeforeWork: false),
        .init(name: "not a file", tool: .zip, paths: "/in/pipe", error: .notAFile("pipe"),
              message: "pipe is not a file or a folder.", checkedBeforeWork: false),
        .init(name: "folder for image", tool: jpeg, paths: "/in/Photos", error: .isFolder("Photos"),
              message: "Photos is a folder. Image conversion and PDF merge take files.", checkedBeforeWork: false),
        .init(name: "folder for pdf", tool: .mergePDFs, paths: "/in/one.pdf\n/in/Photos", error: .isFolder("Photos"),
              message: "Photos is a folder. Image conversion and PDF merge take files.", checkedBeforeWork: false),
        .init(name: "folder with an escaping link for image", tool: jpeg, paths: "/in/Linked", error: .isFolder("Linked"),
              message: "Linked is a folder. Image conversion and PDF merge take files.", checkedBeforeWork: false),
        .init(name: "text as image", tool: jpeg, paths: "/in/a.txt", error: .wrongType("a.txt", expected: "a PNG, JPEG or HEIC image"),
              message: "a.txt is not a PNG, JPEG or HEIC image.", checkedBeforeWork: false),
        .init(name: "image as pdf", tool: .mergePDFs, paths: "/in/one.pdf\n/in/photo.png", error: .wrongType("photo.png", expected: "a PDF"),
              message: "photo.png is not a PDF.", checkedBeforeWork: false),
        .init(name: "already that format", tool: .convertImage(.png, quality: 1), paths: "/in/photo.png",
              error: .alreadyFormat("photo.png", "PNG"), message: "photo.png is already a PNG.", checkedBeforeWork: false),
        .init(name: "zero bytes", tool: .zip, paths: "/in/a.txt\n/in/empty.txt", error: .empty("empty.txt"),
              message: "empty.txt is empty (0 bytes).", checkedBeforeWork: false),
        .init(name: "escaping link", tool: jpeg, paths: "/in/link.png", error: .escapesFolder("link.png"),
              message: "link.png links outside its folder, so it was not read.", checkedBeforeWork: false),
        .init(name: "folder with an escaping link", tool: .zip, paths: "/in/Linked", error: .escapesFolder("Linked"),
              message: "Linked links outside its folder, so it was not read.", checkedBeforeWork: false),
        .init(name: "over 2 GB", tool: .zip, paths: "/in/big1.bin, /in/big2.bin", error: .tooLarge(2_100_000_000),
              message: "The items add up to 2.1 GB; file tools take up to 2 GB at a time.", checkedBeforeWork: false),
        .init(name: "sizes that would overflow the total", tool: .zip, paths: "/in/huge1.bin, /in/huge2.bin",
              error: .tooLarge(Int64.max), message: "The items add up to 9223372036.9 GB; file tools take up to 2 GB at a time.",
              checkedBeforeWork: false),
        .init(name: "same name twice", tool: .zip, paths: "/in/a.txt\n/other/a.txt", error: .duplicateName("a.txt"),
              message: "Two items are named a.txt, and a zip cannot hold both.", checkedBeforeWork: false),
        .init(name: "same name in another case", tool: .zip, paths: "/in/a.txt\n/in/A.TXT", error: .duplicateName("A.TXT"),
              message: "Two items are named A.TXT, and a zip cannot hold both.", checkedBeforeWork: false),
    ]
}

// MARK: Fakes

private func file(
    _ path: String, bytes: Int64 = 100, type: FileToolsContentType = .other, escapes: Bool = false
) -> FileToolsInput {
    FileToolsInput(url: URL(fileURLWithPath: path), kind: .file, byteCount: bytes, contentType: type, escapesFolder: escapes)
}

private func folder(_ path: String, bytes: Int64, escapes: Bool = false) -> FileToolsInput {
    FileToolsInput(url: URL(fileURLWithPath: path), kind: .directory, byteCount: bytes, escapesFolder: escapes)
}

/// Answers from a table of inputs; `perform` returns folder/name unless told to fail, and runs `during` first so a
/// test can cancel or disable in the middle of a job without threads.
private final class FakeFileTools: FileToolsPort, @unchecked Sendable {
    private let lock = NSLock()
    private var inputs: [String: FileToolsInput] = [:]
    private(set) var inspected: [URL] = []
    private(set) var jobs: [FileToolsJob] = []
    private(set) var cancellations: [FileToolsCancellation] = []
    private(set) var removed: [URL] = []
    private(set) var performedOnMainThread: [Bool] = []
    var progressSteps: [Double] = []
    var failure: FileToolsError?
    var unexpected: Error?
    var during: (() -> Void)?

    func add(_ items: FileToolsInput...) {
        lock.withLock { for item in items { inputs[item.url.path] = item } }
    }

    func inspect(_ url: URL, cancellation: FileToolsCancellation) throws -> FileToolsInput {
        lock.withLock {
            inspected.append(url)
            return inputs[url.path] ?? FileToolsInput(url: url, kind: .missing)
        }
    }

    func perform(
        _ job: FileToolsJob, cancellation: FileToolsCancellation, progress: @escaping @Sendable (Double) -> Void
    ) throws -> URL {
        lock.withLock {
            jobs.append(job)
            cancellations.append(cancellation)
            performedOnMainThread.append(Thread.isMainThread)
        }
        progressSteps.forEach(progress)
        during?()
        if let failure { throw failure }
        if let unexpected { throw unexpected }
        return job.folder.appendingPathComponent(job.name)
    }

    func removeOutput(_ url: URL) { lock.withLock { removed.append(url) } }
}

/// Holds submitted work until the test runs it, so a job is "running" for as long as the test needs.
private final class ManualWorker: @unchecked Sendable {
    private let lock = NSLock()
    private var blocks: [@Sendable () -> Void] = []
    var pending: Int { lock.withLock { blocks.count } }
    var worker: FileToolsWorker { FileToolsWorker { [self] block in lock.withLock { blocks.append(block) } } }

    func runAll() {
        while let block = lock.withLock({ blocks.isEmpty ? nil : blocks.removeFirst() }) { block() }
    }
}

private final class FileToolsScheduler: SaysoScheduling, @unchecked Sendable {
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

private final class FileToolsClock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000_000) }

/// Every publish and failure report the module makes, seen on their way to the real host.
private final class FileToolsLog: @unchecked Sendable {
    private let lock = NSLock()
    private var activities: [SaysoActivity] = []
    private var reportCount = 0
    var published: [SaysoActivity] { lock.withLock { activities } }
    var reports: Int { lock.withLock { reportCount } }
    func record(_ activity: SaysoActivity) { lock.withLock { activities.append(activity) } }
    func report() { lock.withLock { reportCount += 1 } }
}

private final class FileToolsRuntimes: @unchecked Sendable { var runtimes: [SaysoModuleRuntime] = [] }

/// Hands the module a context that records what passes through it and forwards everything to the host's context.
private struct FileToolsProbe: SaysoModule {
    let inner: FileToolsModule
    let log: FileToolsLog
    let captured: FileToolsRuntimes
    var descriptor: SaysoModuleDescriptor { inner.descriptor }
    func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        let log = log
        let recording = SaysoModuleContext(
            moduleID: context.moduleID,
            publish: { activity in
                log.record(activity)
                context.publish(
                    stackID: activity.stackID, kind: activity.kind, title: activity.title,
                    expiresAfter: activity.expiresAfter, actions: activity.actions,
                    interruption: activity.interruption, progress: activity.progress
                )
            },
            reportFailure: {
                log.report()
                context.reportFailure()
            },
            dismiss: { context.dismiss(stackID: $0) }
        )
        let runtime = inner.makeRuntime(context: recording)
        captured.runtimes.append(runtime)
        return runtime
    }
}

private struct FileToolsRig {
    let host: SaysoModuleHost
    let module: FileToolsModule
    let port = FakeFileTools()
    let worker = ManualWorker()
    let scheduler = FileToolsScheduler()
    let clock = FileToolsClock()
    let log = FileToolsLog()
    let runtimes = FileToolsRuntimes()

    init(enabled: Bool = true) {
        let clock = clock
        module = FileToolsModule(port: port, scheduler: scheduler, worker: worker.worker, now: { clock.now })
        host = SaysoModuleHost(
            modules: [FileToolsProbe(inner: module, log: log, captured: runtimes)], now: { clock.now }
        )
        if enabled { host.enable("file-tools") }
    }

    /// The module's activity in the engine, if any.
    var shown: SaysoActivity? { host.engine.stack.first { $0.moduleID == "file-tools" } }
}

private extension FileToolsStatus {
    var isFinished: Bool {
        switch self {
        case .done, .failed, .cancelled: true
        case .idle, .running, .cancelling: false
        }
    }
}
