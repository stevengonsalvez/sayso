import Foundation
import Testing
@testable import SaysoCore

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.withLock { values.append(value) } }
    var all: [String] { lock.withLock { values } }
}

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func resolveDescribesFilesAndFoldersAndReturnsNilForMissingPaths() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appending(path: "note.txt")
    try Data("12345".utf8).write(to: file)
    let port = FileSystemShelfPort()

    #expect(port.resolve(file) == FileShelfFile(name: "note.txt", byteCount: 5, isDirectory: false))
    #expect(port.resolve(dir)?.isDirectory == true)
    #expect(port.resolve(dir.appending(path: "ghost.txt")) == nil)
}

@Test func acquireGrantsReadableFilesAndRefusesUnreadableOnes() throws {
    let dir = try makeTempDir()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir.appending(path: "locked.txt").path)
        try? FileManager.default.removeItem(at: dir)
    }
    let readable = dir.appending(path: "ok.txt"), locked = dir.appending(path: "locked.txt")
    try Data("x".utf8).write(to: readable)
    try Data("x".utf8).write(to: locked)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
    let port = FileSystemShelfPort()

    let access = port.acquire(readable)
    #expect(access != nil)
    access?.release()
    access?.release()
    if getuid() != 0 { #expect(port.acquire(locked) == nil) }
    #expect(port.acquire(dir.appending(path: "ghost")) == nil)
}

@Test func openAndRevealAreForwardedToTheInjectedHandlers() {
    let calls = Calls()
    let port = FileSystemShelfPort(open: { calls.add("open \($0.lastPathComponent)") }, reveal: { calls.add("reveal \($0.lastPathComponent)") })
    port.open(URL(fileURLWithPath: "/tmp/a.txt"))
    port.reveal(URL(fileURLWithPath: "/tmp/b.txt"))
    #expect(calls.all == ["open a.txt", "reveal b.txt"])
}
