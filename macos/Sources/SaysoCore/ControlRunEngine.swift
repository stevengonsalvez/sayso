import Foundation

/// The Control run loop: plan, guard, dispatch, verify, audit, complete.
/// Everything nondeterministic (Accessibility, the Jev model, the clock) enters through `Boundary`.
@MainActor
public final class ControlRunEngine<Target: Sendable> {
    public struct Boundary {
        public var isEnabled: () -> Bool
        public var bundleIdentifier: (Target) -> String?
        public var installedApplications: () async -> [InstalledDesktopApplication]
        public var capture: (Target) throws -> DesktopSnapshot
        public var execute: (ControlPlanStep, Bool, Target) async throws -> ControlAuditEntry
        public var decide: (JevCycleOffer) async throws -> JevDecision
        public var record: (ControlAuditEntry) async -> Void
        public var retarget: (ControlAuditEntry, ControlPlanStep, Target) -> Target
        public var pause: (Duration) async throws -> Void
        public var didCapture: (DesktopSnapshot) -> Void

        public init(
            isEnabled: @escaping () -> Bool,
            bundleIdentifier: @escaping (Target) -> String?,
            installedApplications: @escaping () async -> [InstalledDesktopApplication],
            capture: @escaping (Target) throws -> DesktopSnapshot,
            execute: @escaping (ControlPlanStep, Bool, Target) async throws -> ControlAuditEntry,
            decide: @escaping (JevCycleOffer) async throws -> JevDecision,
            record: @escaping (ControlAuditEntry) async -> Void,
            retarget: @escaping (ControlAuditEntry, ControlPlanStep, Target) -> Target,
            pause: @escaping (Duration) async throws -> Void,
            didCapture: @escaping (DesktopSnapshot) -> Void = { _ in }
        ) {
            self.isEnabled = isEnabled
            self.bundleIdentifier = bundleIdentifier
            self.installedApplications = installedApplications
            self.capture = capture
            self.execute = execute
            self.decide = decide
            self.record = record
            self.retarget = retarget
            self.pause = pause
            self.didCapture = didCapture
        }
    }

    private final class Run {
        var cycle: JevControlRunState
        var target: Target
        let installedApplications: [InstalledDesktopApplication]
        let isTryNow: Bool
        let calculatorTask: CalculatorControlTask?
        var hasStarted = false
        var waitCount = 0
        var previous: String?
        var clarification: (choices: [String], askedAt: Date)?
        var calculatorWasCleared = false
        var nextCalculatorCommandIndex = 1

        init(
            cycle: JevControlRunState, target: Target, installedApplications: [InstalledDesktopApplication],
            isTryNow: Bool, calculatorTask: CalculatorControlTask?
        ) {
            self.cycle = cycle
            self.target = target
            self.installedApplications = installedApplications
            self.isTryNow = isTryNow
            self.calculatorTask = calculatorTask
        }
    }

    private let boundary: Boundary
    private let session: ControlSession
    private let now: () -> Date
    private var run: Run?
    private var executionTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var preparationID: UUID?
    private var cancellationTask: Task<Void, Never>?
    private var pendingFinishes = false

    public private(set) var status = ""
    public private(set) var pendingStep: ControlPlanStep?
    public var onChange: () -> Void = {}

    public init(boundary: Boundary, session: ControlSession = ControlSession(), now: @escaping () -> Date = Date.init) {
        self.boundary = boundary
        self.session = session
        self.now = now
    }

    public func sessionState() async -> ControlSessionState { await session.currentState() }

    /// True while a command is being prepared, executing, or waiting on a clarification or approval.
    public var isActive: Bool { run != nil || preparationTask != nil }

    public func waitUntilIdle() async {
        await preparationTask?.value
        await executionTask?.value
        await cancellationTask?.value
    }

    private func setStatus(_ value: String) {
        status = value
        onChange()
    }

    public func submit(_ command: String, target: Target, isTryNow: Bool = false) {
        guard boundary.isEnabled() else {
            setStatus("Enable desktop control in Settings before acting.")
            return
        }
        guard !isTryNow || ControlTryNowPolicy.acceptsTranscript(command) else {
            setStatus("Try now expected Open Calculator.")
            return
        }
        if let current = run, let pending = current.clarification, executionTask == nil {
            if ControlClarification.isAnswer(command, to: pending.choices, askedAt: pending.askedAt, now: now()) {
                do {
                    current.cycle = try JevControlRunState(
                        goal: "\(current.cycle.goal). User clarification: \(command.trimmingCharacters(in: .whitespacesAndNewlines))",
                        recentActions: current.cycle.recentActions
                    )
                    current.clarification = nil
                    setStatus("Applying clarification")
                    execute(current)
                } catch {
                    setStatus(error.localizedDescription)
                }
                return
            }
            // A late or unrelated reply is a new command. beginCommand() resets the session budget.
            run = nil
        }
        guard run == nil, preparationTask == nil else {
            setStatus("Control command already active.")
            return
        }
        do {
            let cycle = try JevControlRunState(goal: command)
            let calculatorTask = ControlPlanner.calculatorTask(from: command)
            // Open + Clear + each key must fit inside the session action budget, or Equals is never checked.
            if let calculatorTask, calculatorTask.commands.count + 1 >= ControlSessionLimits().maxActions {
                throw SaysoError.invalidAction("Calculator control supports shorter numbers. Nothing executed.")
            }
            let id = UUID()
            preparationID = id
            setStatus("Preparing control command")
            preparationTask = Task { [weak self] in
                guard let self else { return }
                let available = await boundary.installedApplications()
                let applications = isTryNow ? ControlTryNowPolicy.candidateApplications(from: available) : available
                guard !Task.isCancelled, preparationID == id else { return }
                preparationTask = nil
                preparationID = nil
                guard run == nil else { return }
                let created = Run(
                    cycle: cycle, target: target, installedApplications: applications,
                    isTryNow: isTryNow, calculatorTask: calculatorTask
                )
                run = created
                execute(created)
            }
        } catch {
            setStatus(error.localizedDescription)
        }
    }

    public func approvePending() {
        guard boundary.isEnabled() else {
            pendingStep = nil
            if let run { requestCancellation(run, status: "Desktop control disabled.") }
            return
        }
        guard let step = pendingStep, let run else { return }
        pendingStep = nil
        let finishes = pendingFinishes
        pendingFinishes = false
        execute(run, approvedStep: step, approvedFinishes: finishes)
    }

    public func discardPending() {
        pendingStep = nil
        pendingFinishes = false
        guard let run else {
            setStatus("Action discarded")
            return
        }
        requestCancellation(run, status: "Action discarded")
    }

    public func cancel(reason: String? = nil) {
        pendingStep = nil
        pendingFinishes = false
        if preparationTask != nil {
            preparationTask?.cancel()
            preparationTask = nil
            preparationID = nil
            setStatus(reason ?? "Control command cancelled.")
            return
        }
        guard let run else {
            setStatus("No active control task")
            return
        }
        requestCancellation(run, status: reason ?? "Cancellation requested. Current macOS action may still finish.")
    }

    private static func clearButton(in snapshot: DesktopSnapshot) -> DesktopElement? {
        snapshot.elements.first { ["All Clear", "Clear"].contains($0.title) && $0.supportsPress }
    }

    private func plan(snapshot: DesktopSnapshot, run: Run) async throws -> (plan: JevCyclePlan, alternatives: [String]) {
        setStatus("Consulting Jev model...")
        let offer = JevControlBridge.makeCycleOffer(
            goal: run.cycle.goal, snapshot: snapshot, recentActions: run.cycle.recentActions,
            installedApplications: run.installedApplications, previous: run.previous
        )
        let decision = try await boundary.decide(offer)
        return (
            try JevControlBridge.planCycleStep(from: decision, offer: offer),
            JevControlBridge.cycleAlternatives(from: decision, offer: offer)
        )
    }

    private func execute(_ run: Run, approvedStep: ControlPlanStep? = nil, approvedFinishes: Bool = false) {
        guard self.run === run, executionTask == nil else { return }
        guard boundary.isEnabled() else {
            requestCancellation(run, status: "Desktop control disabled.")
            return
        }
        executionTask = Task { [weak self] in
            guard let self else { return }
            var actionWasDispatched = false
            do {
                if !run.hasStarted {
                    _ = await session.beginCommand()
                    run.hasStarted = true
                }
                var carriedStep = approvedStep.map { ($0, approvedFinishes) }
                while true {
                    try Task.checkCancellation()
                    let step: ControlPlanStep
                    let finishes: Bool
                    var isApprovedStep = false
                    if let approved = carriedStep {
                        step = approved.0
                        finishes = approved.1
                        carriedStep = nil
                        isApprovedStep = true
                    } else {
                        var snapshot = try boundary.capture(run.target)
                        boundary.didCapture(snapshot)
                        if !run.calculatorWasCleared, run.calculatorTask != nil,
                           boundary.bundleIdentifier(run.target) == ControlTryNowPolicy.calculatorBundleIdentifier {
                            // A freshly launched app can expose no controls for its first moments.
                            var settleAttempts = 0
                            while Self.clearButton(in: snapshot) == nil, settleAttempts < 5 {
                                settleAttempts += 1
                                try await boundary.pause(.milliseconds(400))
                                snapshot = try boundary.capture(run.target)
                                boundary.didCapture(snapshot)
                            }
                        }
                        if let task = run.calculatorTask, boundary.bundleIdentifier(run.target) == ControlTryNowPolicy.calculatorBundleIdentifier {
                            if run.nextCalculatorCommandIndex >= task.commands.count {
                                guard task.resultIsVisible(in: snapshot.observations) else {
                                    throw SaysoError.invalidAction("Calculator did not show the expected result \(task.expectedResult).")
                                }
                                await complete("Control completed: \(task.expectedResult)")
                                return
                            }
                            let command: String
                            if !run.calculatorWasCleared {
                                guard let clear = Self.clearButton(in: snapshot) else {
                                    throw SaysoError.invalidAction("Calculator Clear control is unavailable.")
                                }
                                command = "click \(clear.title)"
                                run.calculatorWasCleared = true
                            } else {
                                command = task.commands[run.nextCalculatorCommandIndex]
                                run.nextCalculatorCommandIndex += 1
                            }
                            step = try ControlPlanner.plan(
                                command: command, snapshot: snapshot, installedApplications: run.installedApplications
                            )
                            finishes = false
                            isApprovedStep = true
                            setStatus("Planned: verified Calculator step")
                        } else {
                            let planned = try await plan(snapshot: snapshot, run: run)
                            switch planned.plan {
                            case .done:
                                await complete("Control completed")
                                return
                            case .blocked:
                                _ = await session.fail()
                                setStatus("Jev could not find a safe next action.")
                                finish()
                                return
                            case .wait:
                                run.waitCount += 1
                                guard run.waitCount <= 2 else {
                                    throw SaysoError.unavailable("The required control did not appear.")
                                }
                                run.cycle.record(action: "WAIT", result: "waited 0.4 seconds", screenChanged: false)
                                try await boundary.pause(.milliseconds(400))
                                continue
                            case let .execute(candidate, completesGoal):
                                step = candidate
                                finishes = completesGoal && run.calculatorTask == nil
                            }
                            setStatus("Planned: \(step.reason)")
                            if step.confidence < ControlPolicy.minimumConfidence {
                                let choices = planned.alternatives
                                guard !choices.isEmpty else {
                                    throw SaysoError.invalidAction("Jev was not confident enough to act.")
                                }
                                let question = "Which one: \(choices.joined(separator: ", "))?"
                                run.previous = question
                                run.clarification = (choices, now())
                                setStatus(question)
                                executionTask = nil
                                return
                            }
                            if run.isTryNow, !ControlTryNowPolicy.canApprove(step) {
                                throw SaysoError.invalidAction("Try now refused an unexpected Jev action.")
                            }
                            if ControlPolicy.requiresConfirmation(step) {
                                if run.isTryNow {
                                    isApprovedStep = true
                                } else {
                                    pendingStep = step
                                    pendingFinishes = finishes
                                    setStatus("Review required: \(step.reason)")
                                    executionTask = nil
                                    return
                                }
                            }
                        }
                    }
                    try Task.checkCancellation()
                    actionWasDispatched = true
                    let entry = try await boundary.execute(step, isApprovedStep, run.target)
                    await boundary.record(entry)
                    guard !Task.isCancelled, self.run === run else { return }
                    run.target = boundary.retarget(entry, step, run.target)
                    run.cycle.record(action: step.reason, result: entry.result, screenChanged: entry.effect == .observed)
                    run.waitCount = 0
                    let updated = await session.record(.init(entry.effect))
                    actionWasDispatched = false
                    guard updated.canRunAction else {
                        setStatus("\(entry.result), \(updated.result?.rawValue ?? "stopped")")
                        finish()
                        return
                    }
                    setStatus(entry.result)
                    if ControlCycleCompletion.shouldComplete(after: step.action, effect: entry.effect, goal: run.cycle.goal)
                        || finishes && (entry.effect == .observed || entry.effect == .alreadySatisfied) {
                        await complete("Control completed")
                        return
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.run === run else { return }
                if actionWasDispatched { _ = await session.record(.actionFailed) }
                _ = await session.fail()
                setStatus(error.localizedDescription)
                finish()
            }
        }
    }

    private func complete(_ message: String) async {
        let completed = await session.complete()
        setStatus(completed.result == .completed ? message : "Control stopped")
        finish()
    }

    private func finish() {
        pendingStep = nil
        pendingFinishes = false
        run = nil
        executionTask = nil
        onChange()
    }

    private func requestCancellation(_ run: Run, status message: String) {
        executionTask?.cancel()
        setStatus(message)
        cancellationTask = Task { [weak self] in
            guard let self else { return }
            _ = await session.cancel()
            guard self.run === run else { return }
            self.run = nil
            executionTask = nil
            onChange()
        }
    }
}
