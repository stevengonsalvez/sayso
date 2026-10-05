import Foundation

public enum WorldClocksError: Error, Equatable, Sendable {
    case disabled
    case unknownZone
    case duplicate
    case full
}

/// A short user-chosen list of places and the local time in each, read from the injected clock.
public final class WorldClocksModule: SaysoModule, @unchecked Sendable {
    public static let maxZones = 6
    public static let maxCityLength = 32

    public let descriptor = SaysoModuleDescriptor(
        id: "world-clocks", title: "World clocks", surfaces: [.compact, .peek, .expanded, .settings]
    )
    fileprivate let store: WorldClocksStore
    fileprivate let scheduler: SaysoScheduling
    fileprivate let hourCycle: WorldClockHourCycle
    fileprivate let now: @Sendable () -> Date
    fileprivate let localTimeZone: @Sendable () -> TimeZone
    private let resolveZone: @Sendable (String) -> TimeZone?
    private let lock = NSLock()
    private var runtime: Runtime?

    public init(
        store: WorldClocksStore,
        scheduler: SaysoScheduling,
        hourCycle: WorldClockHourCycle = .twentyFour,
        now: @escaping @Sendable () -> Date = { Date() },
        localTimeZone: @escaping @Sendable () -> TimeZone = { .autoupdatingCurrent },
        resolveZone: @escaping @Sendable (String) -> TimeZone? = { TimeZone(identifier: $0) }
    ) {
        self.store = store
        self.scheduler = scheduler
        self.hourCycle = hourCycle
        self.now = now
        self.localTimeZone = localTimeZone
        self.resolveZone = resolveZone
    }

    /// The chosen zones in display order; empty while the module is disabled.
    public var zones: [WorldClockZone] { current?.zones ?? [] }

    /// The time in each chosen zone now, in display order; empty while the module is disabled.
    public var readings: [WorldClockReading] { current?.readings ?? [] }

    /// Appends a zone. A blank city falls back to the identifier's last part, for example "New York".
    @discardableResult
    public func add(_ identifier: String, city: String? = nil) throws(WorldClocksError) -> WorldClockZone {
        guard let runtime = current else { throw .disabled }
        guard let timeZone = resolveZone(identifier) else { throw .unknownZone }
        let zone = WorldClockZone(identifier: identifier, city: Self.label(city, for: identifier))
        try runtime.mutate { entries in
            if entries.contains(where: { $0.zone.identifier == identifier }) { return .failure(.duplicate) }
            if entries.count >= Self.maxZones { return .failure(.full) }
            entries.append(Entry(zone: zone, timeZone: timeZone))
            return .success(())
        }.get()
        return zone
    }

    /// False when the zone is not in the list or the module is disabled.
    @discardableResult
    public func remove(_ identifier: String) -> Bool {
        guard let runtime = current else { return false }
        return runtime.mutate { entries in
            guard let index = entries.firstIndex(where: { $0.zone.identifier == identifier }) else { return .failure(.unknownZone) }
            entries.remove(at: index)
            return .success(())
        }.isSuccess
    }

    /// Moves a listed zone to `index` in the final order; false for an unknown zone or an index out of range.
    @discardableResult
    public func move(_ identifier: String, to index: Int) -> Bool {
        guard let runtime = current else { return false }
        return runtime.mutate { entries in
            guard let from = entries.firstIndex(where: { $0.zone.identifier == identifier }), entries.indices.contains(index)
            else { return .failure(.unknownZone) }
            entries.insert(entries.remove(at: from), at: index)
            return .success(())
        }.isSuccess
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

    /// Saved zones that still resolve, without duplicates and at most `maxZones`, labels re-checked.
    fileprivate func restored() -> [Entry] {
        var entries: [Entry] = []
        for saved in store.load() where entries.count < Self.maxZones {
            guard !entries.contains(where: { $0.zone.identifier == saved.identifier }),
                  let timeZone = resolveZone(saved.identifier) else { continue }
            let zone = WorldClockZone(identifier: saved.identifier, city: Self.label(saved.city, for: saved.identifier))
            entries.append(Entry(zone: zone, timeZone: timeZone))
        }
        return entries
    }

    fileprivate func reading(of entry: Entry, at now: Date, local: TimeZone) -> WorldClockReading {
        WorldClockTime.reading(for: entry.zone, in: entry.timeZone, local: local, at: now, hourCycle: hourCycle)
    }

    static func label(_ city: String?, for identifier: String) -> String {
        let trimmed = (city ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = (identifier.split(separator: "/").last.map(String.init) ?? identifier)
            .replacingOccurrences(of: "_", with: " ")
        return String((trimmed.isEmpty ? fallback : trimmed).prefix(maxCityLength))
    }

    fileprivate struct Entry {
        let zone: WorldClockZone
        let timeZone: TimeZone
    }

    /// The next whole minute strictly after `now`. Every current zone offset is a whole number of minutes,
    /// so every clock's label changes at this instant and at no other.
    static func nextMinute(after now: Date) -> Date {
        Date(timeIntervalSince1970: ((now.timeIntervalSince1970 / 60).rounded(.down) + 1) * 60)
    }

    fileprivate final class Runtime: SaysoModuleRuntime, SaysoResourceAccounting, @unchecked Sendable {
        private enum Line: Equatable {
            case show(String)
            case clear
        }

        static let stackID = "world-clocks"

        unowned let module: WorldClocksModule
        let context: SaysoModuleContext
        private let lock = NSLock()
        private var running = false
        private var entries: [Entry] = []
        private var job: SaysoSubscription?
        /// The line last published, so an unchanged label is never published again.
        private var shown: String?

        init(module: WorldClocksModule, context: SaysoModuleContext) {
            self.module = module
            self.context = context
        }

        var retainedResources: Int { lock.withLock { job == nil ? 0 : 1 } }

        var zones: [WorldClockZone] { lock.withLock { entries.map(\.zone) } }

        var readings: [WorldClockReading] {
            let (now, local) = (module.now(), module.localTimeZone())
            return lock.withLock { entries.map { module.reading(of: $0, at: now, local: local) } }
        }

        func start() {
            lock.withLock {
                running = true
                entries = module.restored()
            }
            refresh()
        }

        func stop() {
            lock.withLock {
                running = false
                entries = []
                job?.cancel()
                job = nil
                shown = nil
            }
            module.detach(self)
        }

        /// Applies `change` to a copy and saves it only when it succeeds, so a refused edit writes nothing.
        func mutate(_ change: (inout [Entry]) -> Result<Void, WorldClocksError>) -> Result<Void, WorldClocksError> {
            let result = lock.withLock { () -> Result<Void, WorldClocksError> in
                guard running else { return .failure(.disabled) }
                var edited = entries
                let result = change(&edited)
                guard case .success = result else { return result }
                entries = edited
                module.store.save(edited.map(\.zone))
                return result
            }
            if case .success = result { refresh() }
            return result
        }

        /// Re-arms the single tick and works out the first zone's line under the lock, then publishes outside it
        /// and only when the line changed: publishing takes the host lock, and the host calls into this runtime
        /// while holding that lock.
        private func refresh() {
            let line = lock.withLock { () -> Line? in
                guard running else { return nil }
                let now = module.now()
                rearm(at: now)
                let title = entries.first.map { module.reading(of: $0, at: now, local: module.localTimeZone()).title }
                guard title != shown else { return nil }
                shown = title
                return title.map(Line.show) ?? .clear
            }
            switch line {
            case let .show(title)?: context.publish(stackID: Self.stackID, kind: .ambient, title: title)
            case .clear?: context.dismiss(stackID: Self.stackID)
            case nil: break
            }
        }

        /// One job at the next minute boundary while any zone is listed; none for an empty list. Call with the lock held.
        private func rearm(at now: Date) {
            job?.cancel()
            job = nil
            guard !entries.isEmpty else { return }
            job = module.scheduler.schedule(at: WorldClocksModule.nextMinute(after: now)) { [weak self] in self?.refresh() }
        }
    }
}

private extension Result {
    var isSuccess: Bool { if case .success = self { true } else { false } }
}
