import Foundation

public final class VocabularyModule: SaysoModule, @unchecked Sendable {
    public let descriptor = SaysoModuleDescriptor(
        id: "vocabulary", title: "Vocabulary", surfaces: [.compact, .expanded, .detail, .settings]
    )
    private let port: VocabularyPort
    private let lock = NSLock()
    private var runtime: Runtime?

    public init(port: VocabularyPort) { self.port = port }

    public func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        let runtime = Runtime(port: port, context: context)
        lock.withLock { self.runtime = runtime }
        return runtime
    }

    /// Suspends until every accept or dismiss started so far has finished.
    public func waitUntilIdle() async {
        await lock.withLock({ runtime })?.waitUntilIdle()
    }

    private final class Runtime: SaysoModuleRuntime, SaysoResourceAccounting, @unchecked Sendable {
        let port: VocabularyPort
        let context: SaysoModuleContext
        private let lock = NSLock()
        private var subscriptions: [SaysoSubscription] = []
        private var tasks: [UUID: Task<Void, Never>] = [:]
        private var pending: [UUID: CorrectionCandidateReady] = [:]
        private var stopped = false

        init(port: VocabularyPort, context: SaysoModuleContext) {
            self.port = port
            self.context = context
        }

        var retainedResources: Int { lock.withLock { tasks.count + subscriptions.count } }

        func start() {
            let made = context.subscribe(CorrectionCandidateReady.self) { [weak self] in self?.offer($0) }
            let resolved = context.subscribe(CorrectionCandidateResolved.self) { [weak self] in self?.clear($0.candidateID) }
            lock.withLock { subscriptions = [made, resolved].compactMap { $0 } }
        }

        func stop() {
            let (running, made) = lock.withLock { () -> ([Task<Void, Never>], [SaysoSubscription]) in
                stopped = true
                defer { tasks = [:]; pending = [:]; subscriptions = [] }
                return (Array(tasks.values), subscriptions)
            }
            made.forEach { $0.cancel() }
            running.forEach { $0.cancel() }
        }

        func handle(stackID: String, actionID: String) {
            guard stackID.hasPrefix("candidate-"),
                  let id = UUID(uuidString: String(stackID.dropFirst("candidate-".count))) else { return }
            switch actionID {
            case "accept": run(id) { try await $0.port.promote(candidateID: id) } onSuccess: { $0.announceChange(id) }
            case "dismiss": run(id) { try await $0.port.dismiss(candidateID: id) } onSuccess: { $0.clear(id) }
            default: break
            }
        }

        func waitUntilIdle() async {
            while true {
                let running = lock.withLock { Array(tasks.values) }
                if running.isEmpty { return }
                for task in running { await task.value }
            }
        }

        private func offer(_ candidate: CorrectionCandidateReady) {
            let accepted = lock.withLock { () -> Bool in
                guard !stopped else { return false }
                pending[candidate.candidateID] = candidate
                return true
            }
            guard accepted else { return }
            context.publish(
                stackID: "candidate-\(candidate.candidateID)", kind: .activeTask,
                title: "Remember “\(candidate.source)” as “\(candidate.replacement)”?",
                actions: [SaysoAction(id: "accept", title: "Remember"), SaysoAction(id: "dismiss", title: "Dismiss")]
            )
        }

        private func run(
            _ id: UUID,
            _ work: @escaping @Sendable (Runtime) async throws -> Void,
            onSuccess: @escaping @Sendable (Runtime) -> Void
        ) {
            let key = UUID()
            lock.lock()
            if stopped { lock.unlock(); return }
            tasks[key] = Task { [weak self] in
                guard let self else { return }
                do {
                    try await work(self)
                    onSuccess(self)
                } catch {
                    self.context.publish(
                        stackID: "save-failed-\(id)", kind: .failure, title: "Could not save correction",
                        actions: [SaysoAction(id: "accept", title: "Retry")]
                    )
                }
                self.lock.withLock { self.tasks[key] = nil }
            }
            lock.unlock()
        }

        private func announceChange(_ id: UUID) {
            clear(id)
            context.emit(VocabularyChanged())
        }

        private func clear(_ id: UUID) {
            lock.withLock { pending[id] = nil }
            context.dismiss(stackID: "candidate-\(id)")
            context.dismiss(stackID: "save-failed-\(id)")
        }
    }
}
