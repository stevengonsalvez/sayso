import Foundation
import Testing
@testable import SaysoCore

private final class FakePort: FileShelfPort, @unchecked Sendable {
    private let lock = NSLock()
    var files: [String: FileShelfFile] = [:]
    var held: Set<String> = []
    var opened: [URL] = []
    var revealed: [URL] = []
    var acquires = 0
    var refuseAccess: Set<String> = []

    func resolve(_ url: URL) -> FileShelfFile? { lock.withLock { files[url.path] } }
    func acquire(_ url: URL) -> FileShelfAccess? {
        lock.withLock {
            guard !refuseAccess.contains(url.path) else { return nil }
            acquires += 1
            held.insert(url.path)
        }
        return FileShelfAccess { [weak self] in self?.lock.withLock { self?.held.remove(url.path) } }
    }
    func open(_ url: URL) { lock.withLock { opened.append(url) } }
    func reveal(_ url: URL) { lock.withLock { revealed.append(url) } }
    func add(_ path: String, size: Int64 = 10, directory: Bool = false) {
        lock.withLock { files[path] = FileShelfFile(name: (path as NSString).lastPathComponent, byteCount: size, isDirectory: directory) }
    }
    func delete(_ path: String) { lock.withLock { files[path] = nil } }
}

private final class FakeScheduler: SaysoScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var nextID = 0
    var jobs: [(id: Int, at: Date, action: @Sendable () -> Void)] = []
    func schedule(at date: Date, _ action: @escaping @Sendable () -> Void) -> SaysoSubscription {
        let id = lock.withLock { () -> Int in nextID += 1; jobs.append((nextID, date, action)); return nextID }
        return SaysoSubscription { [weak self] in self?.lock.withLock { self?.jobs.removeAll { $0.id == id } } }
    }
    func fire() {
        let job = lock.withLock { jobs.isEmpty ? nil : jobs.removeFirst() }
        job?.action()
    }
}

private final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000) }

private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

private func setup(ttl: TimeInterval? = nil) -> (SaysoModuleHost, FileShelfModule, FakePort, FakeScheduler, Clock) {
    let port = FakePort(), scheduler = FakeScheduler(), clock = Clock()
    let module = FileShelfModule(port: port, scheduler: scheduler, now: { clock.now }, itemLifetime: ttl)
    let host = SaysoModuleHost(modules: [module], now: { clock.now })
    host.enable("file-shelf")
    return (host, module, port, scheduler, clock)
}

@Test func droppedFilesAreStagedNewestFirstAndMissingOnesAreSkipped() {
    let (host, module, port, _, _) = setup()
    port.add("/tmp/a.txt"); port.add("/tmp/b.png")

    let added = module.add([url("/tmp/a.txt"), url("/tmp/ghost.txt"), url("/tmp/b.png")])

    #expect(added == 2)
    #expect(module.items.map(\.name) == ["b.png", "a.txt"])
    #expect(host.engine.stack.first(where: { $0.stackID == "shelf" })?.title == "File shelf · 2 files")
    #expect(host.engine.stack.contains { $0.stackID == "added" && $0.title == "Added 2 files" && $0.expiresAfter != nil })
}

@Test func theSamePathReplacesItsItemAndMovesToTheFront() {
    let (_, module, port, _, clock) = setup()
    port.add("/tmp/a.txt"); port.add("/tmp/b.txt")
    module.add([url("/tmp/a.txt")])
    module.add([url("/tmp/b.txt")])
    clock.now += 60
    module.add([url("/tmp/a.txt")])

    #expect(module.items.map(\.name) == ["a.txt", "b.txt"])
    #expect(module.items.first?.addedAt == clock.now)
    #expect(port.acquires == 2)
    #expect(port.held == ["/tmp/a.txt", "/tmp/b.txt"])
}

@Test func theLimitDropsTheOldestItemsAndReleasesTheirAccess() {
    let (_, module, port, _, _) = setup()
    module.setLimit(10)
    for n in 0..<12 { port.add("/tmp/f\(n)"); module.add([url("/tmp/f\(n)")]) }

    #expect(module.items.count == 10)
    #expect(module.items.first?.name == "f11")
    #expect(module.items.last?.name == "f2")
    #expect(!port.held.contains("/tmp/f0") && !port.held.contains("/tmp/f1"))
    #expect(port.held.count == 10)

    module.setLimit(7)
    #expect(module.items.count == 10)
}

@Test func filesTheSystemWillNotGrantAccessToAreNotStaged() {
    let (_, module, port, _, _) = setup()
    port.add("/tmp/locked"); port.refuseAccess = ["/tmp/locked"]
    #expect(module.add([url("/tmp/locked")]) == 0)
    #expect(module.items.isEmpty)
}

@Test func openRevealRemoveAndClearActOnTheRightItemsAndReleaseAccess() {
    let (host, module, port, _, _) = setup()
    port.add("/tmp/a.txt"); port.add("/tmp/b.txt")
    module.add([url("/tmp/a.txt"), url("/tmp/b.txt")])
    let a = module.items.first { $0.name == "a.txt" }!

    #expect(module.open(id: a.id))
    #expect(module.reveal(id: a.id))
    #expect(port.opened == [url("/tmp/a.txt")])
    #expect(port.revealed == [url("/tmp/a.txt")])

    #expect(module.remove(id: a.id))
    #expect(module.items.map(\.name) == ["b.txt"])
    #expect(port.held == ["/tmp/b.txt"])
    #expect(!module.open(id: a.id))

    #expect(host.perform(actionID: "clear", stackID: "shelf", moduleID: "file-shelf"))
    #expect(module.items.isEmpty)
    #expect(port.held.isEmpty)
    #expect(!host.engine.stack.contains { $0.stackID == "shelf" })
}

@Test func missingFilesArePrunedOnTheNextCheckAndDragOutOnlyReturnsExistingFiles() {
    let (host, module, port, scheduler, _) = setup()
    port.add("/tmp/a.txt"); port.add("/tmp/b.txt")
    module.add([url("/tmp/a.txt"), url("/tmp/b.txt")])
    #expect(scheduler.jobs.count == 1)

    port.delete("/tmp/a.txt")
    let ids = module.items.map(\.id)
    #expect(module.urlsForDrag(ids: ids) == [url("/tmp/b.txt")])
    #expect(module.items.map(\.name) == ["b.txt"])

    port.delete("/tmp/b.txt")
    scheduler.fire()
    #expect(module.items.isEmpty)
    #expect(scheduler.jobs.isEmpty)
    #expect(!host.engine.stack.contains { $0.stackID == "shelf" })
}

@Test func itemsExpireAfterTheirLifetimeWhenOneIsConfigured() {
    let (_, module, port, scheduler, clock) = setup(ttl: 3600)
    port.add("/tmp/a.txt"); port.add("/tmp/b.txt")
    module.add([url("/tmp/a.txt")])
    clock.now += 1800
    module.add([url("/tmp/b.txt")])

    clock.now += 1800
    scheduler.fire()
    #expect(module.items.map(\.name) == ["b.txt"])
    #expect(port.held == ["/tmp/b.txt"])
}

@Test func disablingReleasesEveryFileCancelsTheCheckAndEmptiesTheShelf() {
    let (host, module, port, scheduler, _) = setup()
    port.add("/tmp/a.txt")
    module.add([url("/tmp/a.txt")])

    host.disable("file-shelf")
    #expect(port.held.isEmpty)
    #expect(scheduler.jobs.isEmpty)
    #expect(module.items.isEmpty)
    #expect(module.add([url("/tmp/a.txt")]) == 0)
}

@Test func fileShelfModulePassesTheGenericAcceptanceHarness() {
    #expect(SaysoModuleAcceptance.violations(for: FileShelfModule(port: FakePort(), scheduler: FakeScheduler())) == [])
}
