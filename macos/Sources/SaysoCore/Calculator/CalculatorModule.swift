import Foundation

/// One evaluated input, kept in history and copied as `text`.
public struct CalculatorResult: Equatable, Sendable, Identifiable {
    public let id: Int
    /// The input as typed, trimmed.
    public let expression: String
    /// The formatted result, for example "36" or "3.106855961 mi"; this is what Copy writes.
    public let text: String
    public let value: CalculatorValue
}

/// Evaluates arithmetic and unit conversions typed by the user. Pure logic: no permission, no network, and the
/// pasteboard port can only be written. Results live in memory, at most `historyLimit`, and are purged on disable.
public final class CalculatorModule: SaysoModule, @unchecked Sendable {
    public static let historyLimit = 10
    /// As long as the Timer and Caffeine completion notices.
    public static let resultNoticeSeconds: TimeInterval = 10
    /// The notch title keeps at most this many characters of the expression.
    public static let titleExpressionLimit = 40
    static let stackID = "calculator-result"

    public let descriptor = SaysoModuleDescriptor(
        id: "calculator", title: "Calculator", surfaces: [.compact, .expanded, .settings]
    )
    private let pasteboard: CalculatorPasteboardPort
    private let scheduler: SaysoScheduling
    private let formatter: CalculatorFormatter
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var runtime: Runtime?
    private var angle: CalculatorAngleUnit

    public init(
        pasteboard: CalculatorPasteboardPort,
        scheduler: SaysoScheduling,
        locale: Locale = .autoupdatingCurrent,
        angleUnit: CalculatorAngleUnit = .degrees,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.pasteboard = pasteboard
        self.scheduler = scheduler
        self.formatter = CalculatorFormatter(locale: locale)
        self.angle = angleUnit
        self.now = now
    }

    /// How sin, cos and tan read their argument; kept across disable since it is a preference, not a result.
    public var angleUnit: CalculatorAngleUnit {
        get { lock.withLock { angle } }
        set { lock.withLock { angle = newValue } }
    }

    /// Newest first; empty while disabled.
    public var history: [CalculatorResult] { current?.history ?? [] }

    /// Evaluates `input`, keeps a result in history and shows it briefly in the notch. Errors change nothing.
    public func evaluate(_ input: String) -> Result<CalculatorResult, CalculatorError> {
        guard let runtime = current else { return .failure(.off) }
        let expression = input.trimmingCharacters(in: .whitespacesAndNewlines)
        switch CalculatorEngine.evaluate(expression, angle: angleUnit) {
        case let .success(value):
            guard let result = runtime.record(expression: expression, value: value, text: formatter.string(for: value))
            else { return .failure(.off) }
            return .success(result)
        case let .failure(error):
            return .failure(error)
        }
    }

    /// Copies the result with this id from history; false when it is gone, the module is off or the write failed.
    @discardableResult
    public func copy(_ id: CalculatorResult.ID) -> Bool {
        guard let text = current?.history.first(where: { $0.id == id })?.text else { return false }
        return pasteboard.write(text)
    }

    public func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        let runtime = Runtime(module: self, context: context)
        lock.withLock { self.runtime = runtime }
        return runtime
    }

    private var current: Runtime? { lock.withLock { runtime } }

    /// Forgets a stopped runtime so later calls are refused instead of reaching a dead runtime.
    fileprivate func detach(_ stopped: Runtime) {
        lock.withLock { if runtime === stopped { runtime = nil } }
    }

    /// "12 × 3 = 36", with a long expression cut to `titleExpressionLimit` characters ending in an ellipsis.
    static func title(expression: String, text: String) -> String {
        let oneLine = expression.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let shown = oneLine.count <= titleExpressionLimit ? oneLine : oneLine.prefix(titleExpressionLimit - 1) + "…"
        return "\(shown) = \(text)"
    }

    fileprivate final class Runtime: SaysoModuleRuntime, SaysoResourceAccounting, @unchecked Sendable {
        unowned let module: CalculatorModule
        let context: SaysoModuleContext
        private let lock = NSLock()
        private var results: [CalculatorResult] = []
        private var nextID = 1
        private var job: SaysoSubscription?
        /// Bumped for every new notice, so a timer callback already under way for an older one changes nothing.
        private var notice = 0
        private var running = false

        init(module: CalculatorModule, context: SaysoModuleContext) {
            self.module = module
            self.context = context
        }

        /// History entries plus the notice's expiry job, so a purge that misses either is visible.
        var retainedResources: Int { lock.withLock { results.count + (job == nil ? 0 : 1) } }

        var history: [CalculatorResult] { lock.withLock { results } }

        func start() { lock.withLock { running = true } }

        func stop() {
            lock.withLock {
                running = false
                job?.cancel()
                job = nil
                results = []
            }
            module.detach(self)
        }

        func handle(stackID: String, actionID: String) {
            guard stackID == CalculatorModule.stackID else { return }
            switch actionID {
            case "copy":
                if let latest = history.first { module.copy(latest.id) }
            case "dismiss":
                let dismissed = lock.withLock { () -> Bool in
                    guard running else { return false }
                    job?.cancel()
                    job = nil
                    return true
                }
                if dismissed { context.dismiss(stackID: CalculatorModule.stackID) }
            default:
                break
            }
        }

        /// Nil once stopped. Publishes outside the lock: publishing takes the host lock, and the host calls into
        /// this runtime while holding that lock.
        func record(expression: String, value: CalculatorValue, text: String) -> CalculatorResult? {
            let result = lock.withLock { () -> CalculatorResult? in
                guard running else { return nil }
                let result = CalculatorResult(id: nextID, expression: expression, text: text, value: value)
                nextID += 1
                results = Array(([result] + results).prefix(CalculatorModule.historyLimit))
                job?.cancel()
                notice += 1
                let due = module.now().addingTimeInterval(CalculatorModule.resultNoticeSeconds)
                job = module.scheduler.schedule(at: due) { [weak self, notice] in self?.expire(notice) }
                return result
            }
            guard let result else { return nil }
            context.publish(
                stackID: CalculatorModule.stackID, kind: .completion,
                title: CalculatorModule.title(expression: expression, text: text),
                expiresAfter: CalculatorModule.resultNoticeSeconds,
                actions: [SaysoAction(id: "copy", title: "Copy"), SaysoAction(id: "dismiss", title: "Dismiss")]
            )
            return result
        }

        private func expire(_ expiring: Int) {
            let due = lock.withLock { () -> Bool in
                guard running, job != nil, notice == expiring else { return false }
                job = nil
                return true
            }
            if due { context.dismiss(stackID: CalculatorModule.stackID) }
        }
    }
}
