import Darwin
import Foundation
import Testing
@testable import SaysoCore

private func tempSocketPath() -> String { "/tmp/sayso-t-\(UUID().uuidString.prefix(8))/s.sock" }

private func connectClient(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
            for index in bytes.indices { dest[index] = CChar(bitPattern: bytes[index]) }
            dest[bytes.count] = 0
        }
    }
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if result != 0 { close(fd); return nil }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    return fd
}

private func writeAll(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { buffer in
        var sent = 0
        while sent < data.count {
            let n = write(fd, buffer.baseAddress!.advanced(by: sent), data.count - sent)
            if n <= 0 { return }
            sent += n
        }
    }
}

private func readAll(_ fd: Int32, _ count: Int) -> Data? {
    var bytes = [UInt8](repeating: 0, count: count)
    var received = 0
    while received < count {
        let n = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: received), count - received) }
        if n <= 0 { return nil }
        received += n
    }
    return Data(bytes)
}

private func frame(_ payload: Data) -> Data {
    var length = UInt32(payload.count).bigEndian
    return withUnsafeBytes(of: &length) { Data($0) } + payload
}

private func roundTrip(_ path: String, _ payload: Data) -> Data? {
    guard let fd = connectClient(path) else { return nil }
    defer { close(fd) }
    writeAll(fd, frame(payload))
    guard let prefix = readAll(fd, 4) else { return nil }
    let length = Int(prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
    return readAll(fd, length)
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data] = []
    func add(_ d: Data) { lock.withLock { values.append(d) } }
    var all: [Data] { lock.withLock { values } }
}

@Test func framedRequestsGetFramedRepliesOnAnOwnerOnlySocket() throws {
    let path = tempSocketPath()
    let calls = Calls()
    let server = SaysoModuleSocketServer(path: path) { request in
        calls.add(request)
        return Data("echo:".utf8) + request
    }
    try server.start()
    defer { server.stop(); try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

    #expect(roundTrip(path, Data("hi".utf8)) == Data("echo:hi".utf8))
    #expect(roundTrip(path, Data("again".utf8)) == Data("echo:again".utf8))
    #expect(calls.all.count == 2)

    let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
    #expect((permissions?.intValue ?? 0) & 0o777 == 0o600)
    let directory = (path as NSString).deletingLastPathComponent
    let dirPermissions = try FileManager.default.attributesOfItem(atPath: directory)[.posixPermissions] as? NSNumber
    #expect((dirPermissions?.intValue ?? 0) & 0o777 == 0o700)
}

@Test func oversizedFramesAreRejectedWithoutCallingTheHandler() throws {
    let path = tempSocketPath()
    let calls = Calls()
    let server = SaysoModuleSocketServer(path: path, maxFrameBytes: 16) { calls.add($0); return Data() }
    try server.start()
    defer { server.stop() }

    #expect(roundTrip(path, Data(repeating: 65, count: 17)) == nil)
    #expect(calls.all.isEmpty)
    #expect(roundTrip(path, Data("ok".utf8)) != nil)
}

@Test func stoppingRemovesTheSocketAndRefusesNewConnections() throws {
    let path = tempSocketPath()
    let server = SaysoModuleSocketServer(path: path) { $0 }
    try server.start()
    server.stop()

    #expect(!FileManager.default.fileExists(atPath: path))
    #expect(connectClient(path) == nil)
}

@Test func theExternalApiServesFramedJsonEndToEnd() throws {
    let path = tempSocketPath()
    let external = ExternalActivitiesModule()
    let host = SaysoModuleHost(modules: [external])
    host.enable("external")
    let api = SaysoExternalAPI(host: host, external: external)
    let server = SaysoModuleSocketServer(path: path) { api.handle($0) }
    try server.start()
    defer { server.stop() }

    let reply = roundTrip(path, Data(#"{"v":1,"op":"publish","stackID":"b","kind":"activeTask","title":"Building"}"#.utf8))
    #expect(reply.flatMap { String(data: $0, encoding: .utf8) } == #"{"ok":true}"#)
    #expect(host.engine.stack.map(\.title) == ["Building"])
}
