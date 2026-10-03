import Darwin
import Foundation

public enum LocalPortProbe {
    /// Fast non-blocking check whether a local TCP port is accepting connections.
    /// Returns in < 0.2ms if the port is closed, avoiding multi-second connection hangs.
    public static func isLocalPortOpen(port: UInt16, host: String = "127.0.0.1", timeoutMs: Int = 50) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)

        let res = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if res == 0 {
            return true
        }

        if errno != EINPROGRESS {
            return false
        }

        var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        let pollRes = poll(&pfd, 1, Int32(timeoutMs))
        if pollRes > 0 && (pfd.revents & Int16(POLLOUT)) != 0 {
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            if getsockopt(sock, SOL_SOCKET, SO_ERROR, &err, &len) == 0 && err == 0 {
                return true
            }
        }
        return false
    }
}
