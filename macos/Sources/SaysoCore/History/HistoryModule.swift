import Foundation

public final class HistoryModule: SaysoModule, @unchecked Sendable {
    public let descriptor = SaysoModuleDescriptor(
        id: "history", title: "History", surfaces: [.compact, .expanded, .detail, .settings]
    )
    private let port: HistoryPort
    private let lock = NSLock()
    private var runtime: Runtime?

    public init(port: HistoryPort) { self.port = port }

    public func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        let runtime = Runtime(port: port, context: context)
        lock.lock()
        self.runtime = runtime
        lock.unlock()
        return runtime
    }

    /// Suspends until every save started so far has finished.
    public func waitUntilIdle() async {
        let current = lock.withLock { runtime }
        await current?.waitUntilIdle()
    }

    /// Saves now and returns the outcome; nil when the module is disabled, quarantined or stopped, so callers must fall back.
    public func append(_ transcript: Transcript) async -> HistoryAppendResult? {
        guard let current = lock.withLock({ runtime }) else { return nil }
        return await current.append(transcript)
    }

    private final class Runtime: SaysoModuleRuntime, SaysoResourceAccounting, @unchecked Sendable {
        private static let recoveredNoticeSeconds: TimeInterval = 6

        let port: HistoryPort
        let context: SaysoModuleContext
        private let lock = NSLock()
        private var subscription: SaysoSubscription?
        private var tasks: [UUID: Task<Void, Never>] = [:]
        private var failed: [Transcript.ID: Transcript] = [:]
        private var stopped = false

        init(port: HistoryPort, context: SaysoModuleContext) {
            self.port = port
            self.context = context
        }

        var retainedResources: Int {
            lock.lock()
            defer { lock.unlock() }
            return tasks.count + (subscription == nil ? 0 : 1)
        }

        func start() {
            let subscription = context.subscribe(TranscriptCompleted.self) { [weak self] in
                self?.save($0.transcript)
            }
            lock.lock()
            self.subscription = subscription
            lock.unlock()
        }

        func stop() {
            lock.lock()
            stopped = true
            let pending = Array(tasks.values)
            tasks = [:]
            failed = [:]
            let subscription = self.subscription
            self.subscription = nil
            lock.unlock()
            subscription?.cancel()
            pending.forEach { $0.cancel() }
        }

        func handle(stackID: String, actionID: String) {
            guard actionID == "retry", stackID == "save-failed" else { return }
            lock.lock()
            let retries = Array(failed.values)
            lock.unlock()
            retries.forEach(save)
        }

        func append(_ transcript: Transcript) async -> HistoryAppendResult? {
            guard !lock.withLock({ stopped }) else { return nil }
            let result = await port.append(transcript)
            record(transcript: transcript, result: result, retryable: false)
            return result
        }

        func waitUntilIdle() async {
            while true {
                let pending = lock.withLock { Array(tasks.values) }
                if pending.isEmpty { return }
                for task in pending { await task.value }
            }
        }

        private func save(_ transcript: Transcript) {
            let key = UUID()
            lock.lock()
            if stopped { lock.unlock(); return }
            let task = Task { [weak self, port] in
                let result = await port.append(transcript)
                self?.record(transcript: transcript, result: result)
                self?.finish(key)
            }
            tasks[key] = task
            lock.unlock()
        }

        private func finish(_ key: UUID) {
            lock.lock()
            tasks[key] = nil
            lock.unlock()
        }

        private func record(transcript: Transcript, result: HistoryAppendResult, retryable: Bool = true) {
            lock.lock()
            let isStopped = stopped
            if !isStopped {
                if retryable { if result == .failed { failed[transcript.id] = transcript } else { failed[transcript.id] = nil } }
            }
            let outstanding = failed.count
            lock.unlock()
            guard !isStopped else { return }

            context.emit(HistoryAppended(transcriptID: transcript.id, result: result))
            switch result {
            case .failed where retryable:
                context.publish(
                    stackID: "save-failed", kind: .failure, title: "History could not save",
                    actions: [SaysoAction(id: "retry", title: "Retry")]
                )
            case .recovered:
                context.publish(
                    stackID: "recovered", kind: .completion,
                    title: "Recovered unreadable history to a local backup",
                    expiresAfter: Self.recoveredNoticeSeconds
                )
            case .saved, .failed:
                break
            }
            if outstanding == 0 { context.dismiss(stackID: "save-failed") }
        }
    }
}
