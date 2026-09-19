import Darwin
import Foundation

/// Blocking connection to the daemon's Unix socket.
public final class Client {
    public let fd: Int32
    private var lines = LineBuffer()
    private var pending: [Message] = []

    private init(fd: Int32) {
        self.fd = fd
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close(fd) }

    public static func connect(socketPath: String) -> Client? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(fd); return nil }
        return Client(fd: fd)
    }

    @discardableResult
    public func send(_ message: Message) -> Bool {
        let data = message.encoded()
        return data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }

    public enum ReadResult {
        case message(Message)
        case timeout
        case closed
    }

    /// Next message, waiting up to `timeout` seconds (nil waits forever).
    public func read(timeout: Double? = nil) -> ReadResult {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            if !pending.isEmpty { return .message(pending.removeFirst()) }
            var remaining: Int32 = -1
            if let deadline {
                remaining = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
            }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, remaining)
            if ready < 0 {
                if errno == EINTR { if let deadline, deadline.timeIntervalSinceNow <= 0 { return .timeout }; continue }
                return .closed
            }
            if ready == 0 { return .timeout }
            guard ingest() else { return pending.isEmpty ? .closed : .message(pending.removeFirst()) }
        }
    }

    /// Reads what's available into the queue. False once the daemon hangs up.
    public func ingest() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(fd, &chunk, chunk.count)
        if count < 0 && errno == EINTR { return true }
        guard count > 0 else { return false }
        for line in lines.append(Data(chunk[0..<count])) {
            if let message = Message.decode(line) { pending.append(message) }
        }
        return true
    }

    public func takePending() -> [Message] {
        defer { pending.removeAll() }
        return pending
    }

    /// Sends a request and waits for one reply.
    public func roundTrip(_ message: Message, timeout: Double = 5) -> Message? {
        guard send(message) else { return nil }
        if case let .message(reply) = read(timeout: timeout) { return reply }
        return nil
    }
}
