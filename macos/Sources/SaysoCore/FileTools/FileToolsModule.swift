import Foundation

/// Where file jobs run. The app's worker is one serial background queue, so jobs never touch the main thread and
/// never overlap, even when a cancelled job is still unwinding as the next one is queued.
public struct FileToolsWorker: Sendable {
    let submit: @Sendable (@escaping @Sendable () -> Void) -> Void

    public init(submit: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) { self.submit = submit }

    public static func serial(label: String = "ai.sayso.notch.file-tools") -> FileToolsWorker {
        let queue = DispatchQueue(label: label, qos: .userInitiated)
        return FileToolsWorker { queue.async(execute: $0) }
    }
}

public enum FileToolsStatus: Equatable, Sendable {
    case idle
    case running(String, progress: Double?)
    case cancelling
    case done(URL)
    case failed(FileToolsError)
    case cancelled
}

/// Zips, converts an image or merges PDFs that the user names, writing one new file beside the first input. Inputs
/// are only read. One job at a time, on the injected worker; the notch shows its progress and then a short notice.
public final class FileToolsModule: SaysoModule, @unchecked Sendable {
    public static let maxInputs = 200
    public static let maxTotalBytes: Int64 = 2_000_000_000
    /// A named folder is walked to size it and find links; past this many items it is refused rather than walked on.
    public static let maxFolderEntries = 100_000
    /// As long as the Calculator, Colour picker, Timer and Caffeine notices.
    public static let noticeSeconds: TimeInterval = 10
    public static let defaultQuality = 0.85
    public static let qualityRange = 0.1...1.0
    /// The host quarantines after three failures within this window, so a tool failure is reported at most once per
    /// window: repeated disk errors leave the module degraded, never switched off behind the user's back.
    public static let failureReportInterval: TimeInterval = 300
    static let stackID = "file-tools-job"

    public let descriptor = SaysoModuleDescriptor(
        id: "file-tools", title: "File tools", capabilities: [.files], surfaces: [.compact, .expanded, .settings]
    )
    private let port: FileToolsPort
    private let scheduler: SaysoScheduling
    private let worker: FileToolsWorker
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var runtime: Runtime?

    public init(
        port: FileToolsPort,
        scheduler: SaysoScheduling,
        worker: FileToolsWorker = .serial(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.port = port
        self.scheduler = scheduler
        self.worker = worker
        self.now = now
    }

    /// The current job or the last outcome; `.idle` while off.
    public var status: FileToolsStatus { current?.status ?? .idle }

    /// Starts `tool` on the paths in `text` (see `FileToolsPaths.parse`). Nil once started. A refusal is returned
    /// and, unless the module is off or busy, also shown as the status and once in the notch.
    @discardableResult
    public func run(_ tool: FileToolsTool, paths text: String) -> FileToolsError? {
        guard let runtime = current else { return .off }
        return runtime.run(tool, text)
    }

    /// Asks the running job to stop; the port removes anything it half wrote.
    public func cancel() { current?.cancel() }

    public func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        let runtime = Runtime(module: self, context: context)
        lock.withLock { self.runtime = runtime }
        return runtime
    }

    private var current: Runtime? { lock.withLock { runtime } }

    fileprivate func detach(_ stopped: Runtime) {
        lock.withLock { if runtime === stopped { runtime = nil } }
    }

    // MARK: Rules

    /// Refusals that need no file system access.
    static func precheck(_ tool: FileToolsTool, _ urls: [URL]) throws {
        guard !urls.isEmpty else { throw FileToolsError.noInputs }
        guard urls.count <= maxInputs else { throw FileToolsError.tooManyInputs(urls.count) }
        switch tool {
        case .zip: break
        case let .convertImage(_, quality):
            guard urls.count == 1 else { throw FileToolsError.oneImageAtATime }
            guard qualityRange.contains(quality) else { throw FileToolsError.qualityOutOfRange }
        case .mergePDFs:
            guard urls.count >= 2 else { throw FileToolsError.needsTwoPDFs }
        }
    }

    /// Refusals that need the inputs' facts, checked in the order named.
    static func validate(_ tool: FileToolsTool, _ inputs: [FileToolsInput]) throws {
        var total: Int64 = 0
        var names = Set<String>()
        for input in inputs {
            switch input.kind {
            case .missing: throw FileToolsError.missing(input.name)
            case .other: throw FileToolsError.notAFile(input.name)
            case .file, .directory: break
            }
            // A folder is the wrong kind of input for images and PDFs whatever it holds, so that is said first.
            if input.kind == .directory, tool != .zip { throw FileToolsError.isFolder(input.name) }
            if input.escapesFolder { throw FileToolsError.escapesFolder(input.name) }
            if input.kind == .file, input.byteCount == 0 { throw FileToolsError.empty(input.name) }
            switch tool {
            case .zip:
                // Case-insensitive, as on a default Mac volume, so unzipping can never put one over the other.
                guard names.insert(input.name.lowercased()).inserted else { throw FileToolsError.duplicateName(input.name) }
            case let .convertImage(target, _):
                guard let format = input.contentType.imageFormat else {
                    throw FileToolsError.wrongType(input.name, expected: "a PNG, JPEG or HEIC image")
                }
                guard format != target else { throw FileToolsError.alreadyFormat(input.name, format.displayName) }
            case .mergePDFs:
                guard input.contentType == .pdf else { throw FileToolsError.wrongType(input.name, expected: "a PDF") }
            }
            total += input.byteCount
        }
        guard total <= maxTotalBytes else { throw FileToolsError.tooLarge(total) }
    }

    static func outputName(_ tool: FileToolsTool, _ inputs: [FileToolsInput]) -> String {
        switch tool {
        case .zip: inputs.count == 1 ? "\(inputs[0].name).zip" : "Archive.zip"
        case let .convertImage(format, _): "\(inputs[0].url.deletingPathExtension().lastPathComponent).\(format.fileExtension)"
        case .mergePDFs: "Merged.pdf"
        }
    }

    static func title(_ tool: FileToolsTool, _ urls: [URL]) -> String {
        switch tool {
        case .zip: urls.count == 1 ? "Zipping \(urls[0].lastPathComponent)" : "Zipping \(urls.count) items"
        case let .convertImage(format, _): "Converting \(urls[0].lastPathComponent) to \(format.displayName)"
        case .mergePDFs: "Merging \(urls.count) PDFs"
        }
    }

    // MARK: Runtime

    fileprivate final class Runtime: SaysoModuleRuntime, SaysoResourceAccounting, @unchecked Sendable {
        private struct Job {
            let id: Int
            let tool: FileToolsTool
            let urls: [URL]
            let title: String
            let cancellation = FileToolsCancellation()
        }

        unowned let module: FileToolsModule
        let context: SaysoModuleContext
        private let lock = NSLock()
        private var running = false
        private var job: Job?
        private var jobCount = 0
        private var state = FileToolsStatus.idle
        private var publishedPercent: Int?
        private var noticeJob: SaysoSubscription?
        /// Bumped for every notice and every new job, so a timer callback already under way changes nothing newer.
        private var notice = 0
        private var lastReport: Date?

        init(module: FileToolsModule, context: SaysoModuleContext) {
            self.module = module
            self.context = context
        }

        /// The job, the notice's timer and the kept outcome, so a purge that misses one is visible.
        var retainedResources: Int {
            lock.withLock { (job == nil ? 0 : 1) + (noticeJob == nil ? 0 : 1) + (state == .idle ? 0 : 1) }
        }

        var status: FileToolsStatus { lock.withLock { state } }

        func start() { lock.withLock { running = true } }

        /// Cancels the job without waiting for it: the worker removes what it half wrote, and a result that lands
        /// after this is deleted (see `finish`).
        func stop() {
            let cancellation = lock.withLock { () -> FileToolsCancellation? in
                running = false
                defer { job = nil }
                noticeJob?.cancel()
                noticeJob = nil
                state = .idle
                return job?.cancellation
            }
            cancellation?.cancel()
            module.detach(self)
        }

        func handle(stackID: String, actionID: String) {
            guard stackID == FileToolsModule.stackID else { return }
            switch actionID {
            case "cancel": cancel()
            case "dismiss":
                let dismissed = lock.withLock { () -> Bool in
                    guard running, job == nil else { return false }
                    noticeJob?.cancel()
                    noticeJob = nil
                    return true
                }
                if dismissed { context.dismiss(stackID: FileToolsModule.stackID) }
            default: break
            }
        }

        func run(_ tool: FileToolsTool, _ text: String) -> FileToolsError? {
            let started = lock.withLock { () -> Result<Job, FileToolsError> in
                guard running else { return .failure(.off) }
                guard job == nil else { return .failure(.busy) }
                do {
                    let urls = try FileToolsPaths.parse(text)
                    try FileToolsModule.precheck(tool, urls)
                    jobCount += 1
                    let started = Job(id: jobCount, tool: tool, urls: urls, title: FileToolsModule.title(tool, urls))
                    job = started
                    state = .running(started.title, progress: nil)
                    publishedPercent = nil
                    noticeJob?.cancel()
                    noticeJob = nil
                    notice += 1
                    return .success(started)
                } catch {
                    return .failure(error as? FileToolsError ?? .toolFailed(error.localizedDescription))
                }
            }
            switch started {
            case let .failure(error):
                if error != .off, error != .busy { show(.failure(error)) }
                return error
            case let .success(job):
                // Published before the work is queued, so the worker's later publishes always come after it.
                publishRunning(job, progress: nil)
                module.worker.submit { [self] in work(job) }
                return nil
            }
        }

        func cancel() {
            let cancellation = lock.withLock { () -> FileToolsCancellation? in
                guard running, let job else { return nil }
                state = .cancelling
                return job.cancellation
            }
            cancellation?.cancel()
        }

        private func work(_ job: Job) {
            let outcome: Result<URL, FileToolsError>
            do {
                guard !job.cancellation.isCancelled else { throw FileToolsError.cancelled }
                var inputs: [FileToolsInput] = []
                for url in job.urls {
                    guard !job.cancellation.isCancelled else { throw FileToolsError.cancelled }
                    inputs.append(try module.port.inspect(url, cancellation: job.cancellation))
                }
                try FileToolsModule.validate(job.tool, inputs)
                let plan = FileToolsJob(
                    tool: job.tool, inputs: inputs, folder: inputs[0].url.deletingLastPathComponent(),
                    name: FileToolsModule.outputName(job.tool, inputs)
                )
                outcome = .success(try module.port.perform(plan, cancellation: job.cancellation) { [weak self] in
                    self?.progress($0, of: job)
                })
            } catch let error as FileToolsError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(.toolFailed(error.localizedDescription))
            }
            finish(job, outcome)
        }

        private func progress(_ fraction: Double, of job: Job) {
            guard !fraction.isNaN else { return }
            let clamped = min(max(fraction, 0), 1)
            let percent = Int(clamped * 100)
            let changed = lock.withLock { () -> Bool in
                guard running, self.job?.id == job.id, !job.cancellation.isCancelled, percent != publishedPercent
                else { return false }
                publishedPercent = percent
                state = .running(job.title, progress: clamped)
                return true
            }
            if changed { publishRunning(job, progress: clamped) }
        }

        private enum Ending { case shown(Result<URL, FileToolsError>), cancelled, stale }

        private func finish(_ finished: Job, _ outcome: Result<URL, FileToolsError>) {
            let ending = lock.withLock { () -> Ending in
                guard running, job?.id == finished.id else { return .stale }
                job = nil
                if finished.cancellation.isCancelled || outcome == .failure(.cancelled) {
                    state = .cancelled
                    return .cancelled
                }
                return .shown(outcome)
            }
            switch ending {
            case .stale, .cancelled:
                // A job that finished after a cancel or after off leaves nothing behind.
                if case let .success(url) = outcome { module.port.removeOutput(url) }
                if case .cancelled = ending { context.dismiss(stackID: FileToolsModule.stackID) }
            case let .shown(result):
                show(result)
            }
        }

        /// Keeps the outcome for the pane and shows it in the notch for `noticeSeconds`. A tool failure is also
        /// reported to the host, at most once per `failureReportInterval`.
        private func show(_ outcome: Result<URL, FileToolsError>) {
            let report = lock.withLock { () -> Bool? in
                guard running else { return nil }
                switch outcome {
                case let .success(url): state = .done(url)
                case let .failure(error): state = .failed(error)
                }
                noticeJob?.cancel()
                notice += 1
                let due = module.now().addingTimeInterval(FileToolsModule.noticeSeconds)
                noticeJob = module.scheduler.schedule(at: due) { [weak self, notice] in self?.expire(notice) }
                guard case .failure(.toolFailed) = outcome else { return false }
                let current = module.now()
                if let lastReport, current.timeIntervalSince(lastReport) < FileToolsModule.failureReportInterval {
                    return false
                }
                lastReport = current
                return true
            }
            guard let report else { return }
            let dismiss = [SaysoAction(id: "dismiss", title: "Dismiss")]
            switch outcome {
            case let .success(url):
                context.publish(
                    stackID: FileToolsModule.stackID, kind: .completion, title: "Saved \(url.lastPathComponent)",
                    expiresAfter: FileToolsModule.noticeSeconds, actions: dismiss
                )
            case let .failure(error):
                context.publish(
                    stackID: FileToolsModule.stackID, kind: .failure, title: error.message,
                    expiresAfter: FileToolsModule.noticeSeconds, actions: dismiss
                )
            }
            if report { context.reportFailure() }
        }

        private func publishRunning(_ job: Job, progress: Double?) {
            context.publish(
                stackID: FileToolsModule.stackID, kind: .activeTask, title: job.title,
                actions: [SaysoAction(id: "cancel", title: "Cancel")], progress: progress
            )
        }

        private func expire(_ expiring: Int) {
            let due = lock.withLock { () -> Bool in
                guard running, noticeJob != nil, notice == expiring else { return false }
                noticeJob = nil
                return true
            }
            if due { context.dismiss(stackID: FileToolsModule.stackID) }
        }
    }
}
