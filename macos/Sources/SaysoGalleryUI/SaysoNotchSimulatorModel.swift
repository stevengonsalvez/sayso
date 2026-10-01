import Combine
import Foundation
import SaysoCore

/// Synthetic situations the simulator can raise, each mapped to one activity on a demo module.
public enum SaysoSimScenario: CaseIterable, Sendable {
    /// Replaces the timer's running task for three seconds; expiry restores the task.
    case temporaryCompletion
    case failure
    case persistentTask
    case criticalConfirmation
    case ambient

    public var title: String {
        switch self {
        case .temporaryCompletion: "Temporary completion"
        case .failure: "Failure"
        case .persistentTask: "Persistent task"
        case .criticalConfirmation: "Critical confirmation"
        case .ambient: "Ambient"
        }
    }
}

public enum SaysoSimHover: Sendable { case entered, exited }

/// One line of the live arbitration list: rank order is the array order.
public struct SaysoSimArbitrationRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let moduleID: String
    public let stackID: String
    public let kind: SaysoActivityKind
    public let title: String
    public let isPrimary: Bool
    public let isPinned: Bool
}

// MARK: Synthetic modules

private final class SimClock: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: TimeInterval = 0
    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return Date(timeIntervalSinceReferenceDate: elapsed)
    }
    func advance(_ seconds: TimeInterval) {
        lock.lock()
        elapsed += seconds
        lock.unlock()
    }
}

private final class ContextStore: @unchecked Sendable {
    private let lock = NSLock()
    private var contexts: [String: SaysoModuleContext] = [:]
    func set(_ context: SaysoModuleContext) {
        lock.lock()
        contexts[context.moduleID] = context
        lock.unlock()
    }
    func context(for id: String) -> SaysoModuleContext? {
        lock.lock()
        defer { lock.unlock() }
        return contexts[id]
    }
}

/// Any action on a demo activity resolves it, which is enough to exercise routing and dismissal.
private final class SyntheticRuntime: SaysoModuleRuntime, @unchecked Sendable {
    private let context: SaysoModuleContext
    init(context: SaysoModuleContext) { self.context = context }
    func start() {}
    func stop() {}
    func handle(stackID: String, actionID: String) { context.dismiss(stackID: stackID) }
}

private struct SyntheticModule: SaysoModule {
    let descriptor: SaysoModuleDescriptor
    let store: ContextStore
    func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        store.set(context)
        return SyntheticRuntime(context: context)
    }
}

// MARK: Model

/// Pure simulator state: a module host, the surface machine and an injected clock.
/// Views only read derived state and call the plain methods below.
@MainActor
public final class SaysoNotchSimulatorModel: ObservableObject {
    /// Lifetime of a temporary alert.
    public static let alertLifetime: TimeInterval = 3

    @Published public private(set) var machine: NotchSurfaceMachine
    @Published public private(set) var activityStack: [SaysoActivity] = []
    @Published public private(set) var primary: SaysoActivity?
    @Published public private(set) var pinnedID: String?
    @Published public private(set) var nextExpiryIn: TimeInterval?

    public let tabs: [String]
    private let clock = SimClock()
    private let host: SaysoModuleHost
    private let store = ContextStore()
    private var pinned: (moduleID: String, stackID: String)?

    public var surface: NotchSurfaceMachine.Surface { machine.surface }
    public var selectedTab: String? { machine.selectedTab }
    public var now: Date { clock.now }

    public init(startsHidden: Bool = false) {
        let store = self.store
        let clock = self.clock
        let modules = [
            SaysoModuleDescriptor(id: "clip", title: "Clipboard"),
            SaysoModuleDescriptor(id: "timer", title: "Timer"),
            SaysoModuleDescriptor(id: "media", title: "Media"),
            SaysoModuleDescriptor(id: "control", title: "Control"),
        ].map { SyntheticModule(descriptor: $0, store: store) }
        host = SaysoModuleHost(modules: modules, now: { clock.now })
        tabs = modules.map(\.descriptor.id)
        machine = NotchSurfaceMachine(tabs: tabs, startsHidden: startsHidden)
        tabs.forEach(host.enable)
    }

    public func title(ofTab id: String) -> String {
        host.descriptors.first { $0.id == id }?.title ?? id
    }

    // MARK: Interaction

    public func hover(_ phase: SaysoSimHover, at time: Date? = nil) {
        machine.handle(phase == .entered ? .hoverEntered : .hoverExited, at: time ?? now)
    }
    public func click(_ region: NotchInteractionRegion) { machine.handle(.click(region), at: now) }
    public func swipe(_ direction: NotchSurfaceMachine.SwipeDirection) { machine.handle(.swipe(direction), at: now) }
    public func jump(_ number: Int) { machine.handle(.jump(number), at: now) }
    public func topEdgeHover() { machine.handle(.topEdgeHover, at: now) }

    // MARK: Activities

    public func inject(_ scenario: SaysoSimScenario) {
        switch scenario {
        case .temporaryCompletion:
            publish("timer", "task", .completion, "Timer finished", expiresAfter: Self.alertLifetime)
        case .failure:
            publish("media", "playback", .failure, "Playback failed",
                    actions: [SaysoAction(id: "retry", title: "Retry")])
        case .persistentTask:
            publish("timer", "task", .activeTask, "Timer running")
        case .criticalConfirmation:
            publish("control", "confirm", .confirmation, "Allow Sayso to quit Slack?",
                    actions: [SaysoAction(id: "approve", title: "Approve"), SaysoAction(id: "deny", title: "Deny")],
                    interruption: .critical)
        case .ambient:
            publish("clip", "ambient", .ambient, "Clipboard: 12 items")
        }
        refresh()
    }

    public func pin(moduleID: String, stackID: String) {
        guard activityStack.contains(where: { $0.moduleID == moduleID && $0.stackID == stackID }) else { return }
        pinned = (moduleID, stackID)
        host.pin(moduleID: moduleID, stackID: stackID)
        refresh()
    }

    public func pinPrimary() {
        guard let primary else { return }
        pin(moduleID: primary.moduleID, stackID: primary.stackID)
    }

    public func unpin() {
        pinned = nil
        host.unpin()
        refresh()
    }

    /// Routes `actionID` to the primary activity's module; false if it does not declare the action.
    @discardableResult
    public func performPrimaryAction(_ actionID: String) -> Bool {
        guard let primary else { return false }
        let handled = host.perform(actionID: actionID, stackID: primary.stackID, moduleID: primary.moduleID)
        refresh()
        return handled
    }

    /// Moves the injected clock, then lets expiry and the hover timer observe the new time.
    public func advance(_ seconds: TimeInterval) {
        clock.advance(seconds)
        host.tick()
        machine.tick(at: now)
        refresh()
    }

    public var arbitration: [SaysoSimArbitrationRow] {
        activityStack.map { activity in
            SaysoSimArbitrationRow(
                id: "\(activity.moduleID)/\(activity.stackID)",
                moduleID: activity.moduleID, stackID: activity.stackID,
                kind: activity.kind, title: activity.title,
                isPrimary: activity == primary,
                isPinned: "\(activity.moduleID)/\(activity.stackID)" == pinnedID
            )
        }
    }

    // MARK: Private

    private func publish(
        _ module: String, _ stack: String, _ kind: SaysoActivityKind, _ title: String,
        expiresAfter: TimeInterval? = nil, actions: [SaysoAction] = [],
        interruption: SaysoInterruptionPolicy = .normal
    ) {
        store.context(for: module)?.publish(
            stackID: stack, kind: kind, title: title,
            expiresAfter: expiresAfter, actions: actions, interruption: interruption
        )
    }

    /// Re-derives published state from the host; the engine drops a pin whose activity is gone, so mirror that.
    private func refresh() {
        let engine = host.engine
        activityStack = engine.stack
        primary = engine.primary
        if let pin = pinned, !activityStack.contains(where: { $0.moduleID == pin.moduleID && $0.stackID == pin.stackID }) {
            pinned = nil
        }
        pinnedID = pinned.map { "\($0.moduleID)/\($0.stackID)" }
        nextExpiryIn = engine.nextExpiry.map { max(0, $0.timeIntervalSince(now)) }
    }
}
