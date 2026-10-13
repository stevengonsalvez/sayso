import Foundation

/// Named text snippets the user keeps on this Mac. Placeholders are filled only when a snippet is copied: `{date}` and
/// `{time}` from the injected clock and locale, `{clipboard}` from the read port at that moment and never when a
/// snippet is saved or listed. Copy writes through a write-only port and shows a short notice with the snippet's name.
public final class SnippetsModule: SaysoModule, @unchecked Sendable {
    public static let maxSnippets = 50
    public static let nameLimit = 60
    public static let bodyLimit = 10_000
    /// As long as the Calculator, Colour picker and File tools notices.
    public static let noticeSeconds: TimeInterval = 10
    static let stackID = "snippets-copy"

    public let descriptor = SaysoModuleDescriptor(
        id: "snippets", title: "Snippets", capabilities: [.clipboard], surfaces: [.compact, .expanded, .settings]
    )
    fileprivate let store: SnippetsStore
    private let clipboard: SnippetsClipboardReading
    private let pasteboard: CalculatorPasteboardPort
    fileprivate let scheduler: SaysoScheduling
    private let expander: SnippetsExpander
    fileprivate let now: @Sendable () -> Date
    private let lock = NSLock()
    private var runtime: Runtime?

    public init(
        store: SnippetsStore,
        clipboard: SnippetsClipboardReading,
        pasteboard: CalculatorPasteboardPort,
        scheduler: SaysoScheduling,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.clipboard = clipboard
        self.pasteboard = pasteboard
        self.scheduler = scheduler
        self.expander = SnippetsExpander(locale: locale, timeZone: timeZone)
        self.now = now
    }

    /// In the order added; empty while off.
    public var snippets: [Snippet] { current?.list ?? [] }

    /// The last copy while its notice shows; nil otherwise and while off.
    public var lastCopy: SnippetCopy? { current?.copied }

    /// Saves a new snippet. Unknown placeholders are kept and returned as warnings.
    public func add(name: String, body: String) -> Result<[SnippetsWarning], SnippetsError> {
        mutate { list in
            let name = try Self.validName(name)
            let body = try Self.validBody(body)
            if let taken = list.first(where: { Self.same($0.name, name) }) { throw SnippetsError.duplicateName(taken.name) }
            guard list.count < Self.maxSnippets else { throw SnippetsError.full }
            list.append(Snippet(name: name, body: body))
            return SnippetsExpander.warnings(in: body)
        }
    }

    /// Gives a snippet a new name, keeping its text and place. Nil once done.
    public func rename(_ name: String, to newName: String) -> SnippetsError? {
        let result = mutate { list in
            let index = try Self.index(of: name, in: list)
            let newName = try Self.validName(newName)
            if let taken = list.indices.first(where: { $0 != index && Self.same(list[$0].name, newName) }) {
                throw SnippetsError.duplicateName(list[taken].name)
            }
            list[index] = Snippet(name: newName, body: list[index].body)
            return []
        }
        if case let .failure(error) = result { return error }
        return nil
    }

    /// Replaces a snippet's text. Unknown placeholders are kept and returned as warnings.
    public func edit(_ name: String, body: String) -> Result<[SnippetsWarning], SnippetsError> {
        mutate { list in
            let index = try Self.index(of: name, in: list)
            let body = try Self.validBody(body)
            list[index] = Snippet(name: list[index].name, body: body)
            return SnippetsExpander.warnings(in: body)
        }
    }

    /// Nil once done.
    public func delete(_ name: String) -> SnippetsError? {
        let result = mutate { list in
            list.remove(at: try Self.index(of: name, in: list))
            return []
        }
        if case let .failure(error) = result { return error }
        return nil
    }

    /// Expands the snippet now, writes the text to the clipboard and shows a notice with its name. The clipboard is
    /// read only here, and only when the snippet holds `{clipboard}`.
    public func copy(_ name: String) -> Result<SnippetCopy, SnippetsError> {
        guard let runtime = current else { return .failure(.off) }
        let snippet: Snippet
        switch runtime.snippet(named: name) {
        case let .success(found): snippet = found
        case let .failure(error): return .failure(error)
        }
        let expansion = expander.expand(snippet.body, at: now(), clipboard: { self.clipboard.readText() })
        guard pasteboard.write(expansion.text) else { return .failure(.writeFailed(snippet.name)) }
        let copy = SnippetCopy(name: snippet.name, text: expansion.text, warnings: expansion.warnings)
        runtime.show(copy)
        return .success(copy)
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

    private func mutate(_ change: (inout [Snippet]) throws -> [SnippetsWarning]) -> Result<[SnippetsWarning], SnippetsError> {
        guard let runtime = current else { return .failure(.off) }
        return runtime.mutate(change)
    }

    // MARK: Rules

    static func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }

    static func validName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SnippetsError.emptyName }
        guard name.rangeOfCharacter(from: .newlines) == nil else { throw SnippetsError.nameNotOneLine }
        guard name.count <= nameLimit else { throw SnippetsError.nameTooLong }
        return name
    }

    /// The body is kept exactly as typed; only its length and that it has some text are checked.
    static func validBody(_ body: String) throws -> String {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SnippetsError.emptyBody }
        guard body.count <= bodyLimit else { throw SnippetsError.bodyTooLong }
        return body
    }

    static func index(of raw: String, in list: [Snippet]) throws -> Int {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = list.firstIndex(where: { same($0.name, name) }) else { throw SnippetsError.notFound(name) }
        return index
    }

    /// Stored entries that break a rule are skipped and the rest kept in order, up to the limit. Nothing is saved
    /// here: what was stored stays as it was until the user's next edit.
    static func sanitized(_ stored: [Snippet]) -> [Snippet] {
        var kept: [Snippet] = []
        for entry in stored where kept.count < maxSnippets {
            guard let name = try? validName(entry.name), let body = try? validBody(entry.body),
                  !kept.contains(where: { same($0.name, name) }) else { continue }
            kept.append(Snippet(name: name, body: body))
        }
        return kept
    }

    // MARK: Runtime

    fileprivate final class Runtime: SaysoModuleRuntime, SaysoResourceAccounting, @unchecked Sendable {
        unowned let module: SnippetsModule
        let context: SaysoModuleContext
        private let lock = NSLock()
        private var running = false
        private var snippets: [Snippet] = []
        private var copy: SnippetCopy?
        private var job: SaysoSubscription?
        /// Bumped for every notice, so a timer callback already under way for an older one changes nothing.
        private var notice = 0

        init(module: SnippetsModule, context: SaysoModuleContext) {
            self.module = module
            self.context = context
        }

        /// The loaded snippets, the notice's timer and the kept expansion, so a purge that misses one is visible.
        var retainedResources: Int {
            lock.withLock { snippets.count + (job == nil ? 0 : 1) + (copy == nil ? 0 : 1) }
        }

        var list: [Snippet] { lock.withLock { snippets } }
        var copied: SnippetCopy? { lock.withLock { copy } }

        func start() {
            lock.withLock {
                running = true
                snippets = SnippetsModule.sanitized(module.store.load())
            }
        }

        func stop() {
            lock.withLock {
                running = false
                job?.cancel()
                job = nil
                copy = nil
                snippets = []
            }
            module.detach(self)
        }

        func handle(stackID: String, actionID: String) {
            guard stackID == SnippetsModule.stackID, actionID == "dismiss" else { return }
            let dismissed = lock.withLock { () -> Bool in
                guard running else { return false }
                job?.cancel()
                job = nil
                copy = nil
                return true
            }
            if dismissed { context.dismiss(stackID: SnippetsModule.stackID) }
        }

        /// Applies `change` to a copy of the list and saves it only when it succeeds, under the lock so saves keep
        /// the order of the edits.
        func mutate(_ change: (inout [Snippet]) throws -> [SnippetsWarning]) -> Result<[SnippetsWarning], SnippetsError> {
            lock.withLock {
                guard running else { return .failure(.off) }
                var edited = snippets
                do {
                    let warnings = try change(&edited)
                    snippets = edited
                    module.store.save(edited)
                    return .success(warnings)
                } catch let error as SnippetsError {
                    return .failure(error)
                } catch {
                    preconditionFailure("snippet edits throw only SnippetsError: \(error)")
                }
            }
        }

        func snippet(named name: String) -> Result<Snippet, SnippetsError> {
            lock.withLock {
                guard running else { return .failure(.off) }
                do { return .success(snippets[try SnippetsModule.index(of: name, in: snippets)]) }
                catch let error as SnippetsError { return .failure(error) }
                catch { preconditionFailure("snippet lookups throw only SnippetsError: \(error)") }
            }
        }

        /// Keeps the expansion and shows the notice until the module's own job ends it. Publishes outside the lock:
        /// publishing takes the host lock, and the host calls into this runtime while holding that lock.
        func show(_ copied: SnippetCopy) {
            let shown = lock.withLock { () -> Bool in
                guard running else { return false }
                copy = copied
                job?.cancel()
                notice += 1
                let due = module.now().addingTimeInterval(SnippetsModule.noticeSeconds)
                job = module.scheduler.schedule(at: due) { [weak self, notice] in self?.expire(notice) }
                return true
            }
            guard shown else { return }
            context.publish(
                stackID: SnippetsModule.stackID, kind: .completion, title: "Copied \(copied.name)",
                expiresAfter: SnippetsModule.noticeSeconds, actions: [SaysoAction(id: "dismiss", title: "Dismiss")]
            )
        }

        private func expire(_ expiring: Int) {
            let due = lock.withLock { () -> Bool in
                guard running, job != nil, notice == expiring else { return false }
                job = nil
                copy = nil
                return true
            }
            if due { context.dismiss(stackID: SnippetsModule.stackID) }
        }
    }
}
