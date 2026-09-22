// Derived from JustSpeakToIt AutomationServer, MIT License. See LICENSES.md.
import AppKit
import Darwin
import Foundation
import OSLog
import SaysoCore
import SpeakUpstreamBridge

private let automationLog = Logger(subsystem: "ai.sayso.notch", category: "automation")

final class SaysoAutomationServer {
    static let defaultSocketPath = SaysoAutomationEndpoint.socketPath

    private let socketPath: String
    private let queue = DispatchQueue(label: "ai.sayso.notch.automation", qos: .userInitiated, attributes: .concurrent)
    private var source: DispatchSourceRead?

    init(socketPath: String = SaysoAutomationServer.defaultSocketPath) {
        self.socketPath = socketPath
    }

    func start(handler: @escaping @MainActor (AutomationRequest) async -> AutomationResponse) throws {
        guard source == nil else { return }
        let descriptor = try Self.makeSocket(at: socketPath)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection(descriptor, handler: handler)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        automationLog.info("owner-only automation socket started")
    }

    private func acceptConnection(
        _ descriptor: Int32,
        handler: @escaping @MainActor (AutomationRequest) async -> AutomationResponse
    ) {
        let client = accept(descriptor, nil, nil)
        guard client >= 0 else { return }
        Self.configure(client)
        serve(client, handler: handler)
    }

    func stop() {
        source?.cancel()
        source = nil
        try? FileManager.default.removeItem(atPath: socketPath)
        automationLog.info("owner-only automation socket stopped")
    }

    private func serve(
        _ client: Int32,
        handler: @escaping @MainActor (AutomationRequest) async -> AutomationResponse
    ) {
        let responseQueue = queue
        responseQueue.async {
            do {
                automationLog.debug("automation connection accepted")
                let prefix = try Self.read(client, count: AutomationFraming.prefixLength)
                let body = try Self.read(client, count: AutomationFraming.payloadLength(from: prefix))
                let request = try AutomationCoding.decoder().decode(AutomationRequest.self, from: body).validated()
                Task { @MainActor in
                    let response = await handler(request)
                    automationLog.debug("automation command completed")
                    responseQueue.async {
                        Self.send(response, client: client)
                        close(client)
                    }
                }
            } catch {
                automationLog.error("automation request rejected")
                let response = AutomationResponse.failure(
                    id: "unknown", command: .status,
                    error: .init(code: .invalidArgument, message: "Malformed Sayso automation request.")
                )
                Self.send(response, client: client)
                close(client)
            }
        }
    }

    private static func makeSocket(at path: String) throws -> Int32 {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
        try? FileManager.default.removeItem(atPath: path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SaysoError.unavailable("Automation socket") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { close(descriptor); throw SaysoError.invalidAction("Automation socket path is too long") }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for index in bytes.indices { destination[index] = CChar(bitPattern: bytes[index]) }
                destination[bytes.count] = 0
            }
        }
        let oldMask = umask(0o177)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(oldMask)
        guard result == 0, chmod(path, 0o600) == 0, listen(descriptor, 8) == 0 else {
            close(descriptor)
            throw SaysoError.unavailable("Automation socket")
        }
        return descriptor
    }

    private static func configure(_ descriptor: Int32) {
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 16, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func read(_ descriptor: Int32, count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            let result = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!.advanced(by: received), count - received) }
            if result > 0 { received += result; continue }
            if result < 0, errno == EINTR { continue }
            throw SaysoError.invalidAction("Automation connection closed early")
        }
        return Data(bytes)
    }

    private static func send(_ response: AutomationResponse, client: Int32) {
        guard let body = try? AutomationCoding.encoder().encode(response), let frame = try? AutomationFraming.frame(body) else { return }
        _ = frame.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return -1 }
            var sent = 0
            while sent < frame.count {
                let result = Darwin.write(client, base.advanced(by: sent), frame.count - sent)
                if result > 0 { sent += result; continue }
                if result < 0, errno == EINTR { continue }
                return -1
            }
            return sent
        }
    }
}
