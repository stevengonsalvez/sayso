import Darwin
import Foundation

/// Owner-only Unix socket carrying 4-byte big-endian length-framed requests. The handler is pure bytes in, bytes out.
public final class SaysoModuleSocketServer: @unchecked Sendable {
    public static let defaultMaxFrameBytes = 64 * 1024

    private let path: String
    private let maxFrameBytes: Int
    private let handler: @Sendable (Data) -> Data
    private let queue = DispatchQueue(label: "ai.sayso.module-socket", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var source: DispatchSourceRead?

    public init(
        path: String,
        maxFrameBytes: Int = SaysoModuleSocketServer.defaultMaxFrameBytes,
        handler: @escaping @Sendable (Data) -> Data
    ) {
        self.path = path
        self.maxFrameBytes = maxFrameBytes
        self.handler = handler
    }

    public func start() throws {
        try lock.withLock {
            guard source == nil else { return }
            let descriptor = try Self.makeSocket(at: path)
            let made = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            made.setEventHandler { [weak self] in self?.accept(descriptor) }
            made.setCancelHandler { close(descriptor) }
            made.resume()
            source = made
        }
    }

    public func stop() {
        let made = lock.withLock { () -> DispatchSourceRead? in
            defer { source = nil }
            return source
        }
        made?.cancel()
        try? FileManager.default.removeItem(atPath: path)
    }

    private func accept(_ listener: Int32) {
        let client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else { return }
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        queue.async { [handler, maxFrameBytes] in
            defer { close(client) }
            guard let prefix = Self.read(client, count: 4) else { return }
            let length = Int(prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
            guard length <= maxFrameBytes, let body = Self.read(client, count: length) else { return }
            let reply = handler(body)
            var replyLength = UInt32(reply.count).bigEndian
            Self.write(client, withUnsafeBytes(of: &replyLength) { Data($0) } + reply)
        }
    }

    private static func makeSocket(at path: String) throws -> Int32 {
        let directory = (path as NSString).deletingLastPathComponent
        // The private 0700 directory is what keeps other users out; umask is process-wide, so it is never touched.
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
        try? FileManager.default.removeItem(atPath: path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SaysoError.unavailable("Module socket") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { close(descriptor); throw SaysoError.invalidAction("Module socket path is too long") }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for index in bytes.indices { destination[index] = CChar(bitPattern: bytes[index]) }
                destination[bytes.count] = 0
            }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 8) == 0 else {
            close(descriptor)
            throw SaysoError.unavailable("Module socket")
        }
        return descriptor
    }

    private static func read(_ descriptor: Int32, count: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            let result = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!.advanced(by: received), count - received) }
            if result > 0 { received += result; continue }
            if result < 0, errno == EINTR { continue }
            return nil
        }
        return Data(bytes)
    }

    private static func write(_ descriptor: Int32, _ data: Data) {
        data.withUnsafeBytes { buffer in
            var sent = 0
            while sent < data.count, let base = buffer.baseAddress {
                let result = Darwin.write(descriptor, base.advanced(by: sent), data.count - sent)
                if result > 0 { sent += result; continue }
                if result < 0, errno == EINTR { continue }
                return
            }
        }
    }
}
