import Darwin
import Foundation
import TurnstileCore

/// Blocking connection to the daemon's Unix socket.
final class Client {
    let fd: Int32
    private var lines = LineBuffer()
    private var pending: [Message] = []

    private init(fd: Int32) {
        self.fd = fd
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close(fd) }

    static func connect(socketPath: String) -> Client? {
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

    /// Connects, starting the daemon if it isn't running.
    static func connectOrStart(paths: Paths) -> Client? {
        if let client = connect(socketPath: paths.socket) { return client }
        guard startDaemon(paths: paths) else { return nil }
        // Generous, because this runs when the machine is busiest.
        for _ in 0..<125 {
            usleep(40_000)
            if let client = connect(socketPath: paths.socket) { return client }
        }
        return nil
    }

    static func startDaemon(paths: Paths) -> Bool {
        guard let me = executablePath() else { return false }
        try? paths.ensure()
        rotate(paths.daemonLog, above: 1 << 20)
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TURNSTILE_TOKEN")
        let pid = spawn(
            path: me,
            argv: ["turnstile", "daemon"],
            environment: environment,
            stdin: "/dev/null",
            output: paths.daemonLog,
            newSession: true
        )
        return pid != nil
    }

    /// Keeps one previous generation, so the log never grows without bound.
    static func rotate(_ path: String, above limit: UInt64) {
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64 ?? 0
        guard size > limit else { return }
        _ = Darwin.rename(path, path + ".1")
    }

    @discardableResult
    func send(_ message: Message) -> Bool {
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

    enum ReadResult {
        case message(Message)
        case timeout
        case closed
    }

    /// Next message, waiting up to `timeout` seconds (nil waits forever).
    func read(timeout: Double? = nil) -> ReadResult {
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
    func ingest() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(fd, &chunk, chunk.count)
        if count < 0 && errno == EINTR { return true }
        guard count > 0 else { return false }
        for line in lines.append(Data(chunk[0..<count])) {
            if let message = Message.decode(line) { pending.append(message) }
        }
        return true
    }

    func takePending() -> [Message] {
        defer { pending.removeAll() }
        return pending
    }

    /// Sends a request and waits for one reply.
    func roundTrip(_ message: Message, timeout: Double = 5) -> Message? {
        guard send(message) else { return nil }
        if case let .message(reply) = read(timeout: timeout) { return reply }
        return nil
    }
}

func executablePath() -> String? {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size) + 1)
    guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
    return Resolver.canonical(String(cString: buffer))
}

/// posix_spawn with default signal handling restored in the child.
/// `closeOthers` closes every descriptor except stdio; otherwise the child inherits non-CLOEXEC fds.
/// `passing` hands the child extra descriptors, as (ours, theirs).
func spawn(path: String, argv: [String], environment: [String: String], stdin: String? = nil, output: String? = nil, stdoutFD: Int32? = nil, stderrFD: Int32? = nil, passing: [(Int32, Int32)] = [], newSession: Bool = false, closeOthers: Bool = true) -> pid_t? {
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    if let stdin { posix_spawn_file_actions_addopen(&actions, 0, stdin, O_RDONLY, 0) }
    if let output {
        posix_spawn_file_actions_addopen(&actions, 1, output, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
    }
    if let stdoutFD { posix_spawn_file_actions_adddup2(&actions, stdoutFD, 1) }
    if let stderrFD { posix_spawn_file_actions_adddup2(&actions, stderrFD, 2) }
    for (ours, theirs) in passing { posix_spawn_file_actions_adddup2(&actions, ours, theirs) }

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    var defaults = sigset_t()
    sigemptyset(&defaults)
    for sig in [SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGPIPE, SIGCHLD, SIGTSTP, SIGTTIN, SIGTTOU, SIGUSR1, SIGUSR2] {
        sigaddset(&defaults, sig)
    }
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    var empty = sigset_t()
    sigemptyset(&empty)
    posix_spawnattr_setsigmask(&attributes, &empty)
    var flags = Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
    if closeOthers { flags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT) }
    if newSession { flags |= Int16(POSIX_SPAWN_SETSID) }
    posix_spawnattr_setflags(&attributes, flags)

    // CLOEXEC_DEFAULT closes everything not named in the file actions, so keep stdio explicitly.
    for fd: Int32 in 0...2 where closeOthers && !(fd == 0 && stdin != nil) && !(fd >= 1 && output != nil) {
        let isRedirected = (fd == 1 && stdoutFD != nil) || (fd == 2 && stderrFD != nil)
        if !isRedirected { posix_spawn_file_actions_addinherit_np(&actions, fd) }
    }

    let cArgs = argv.map { strdup($0) } + [nil]
    let cEnv = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
        cArgs.forEach { free($0) }
        cEnv.forEach { free($0) }
    }
    var pid: pid_t = 0
    let result = posix_spawn(&pid, path, &actions, &attributes, cArgs, cEnv)
    return result == 0 ? pid : nil
}

/// Replaces this process with the real tool.
func execReal(_ path: String, _ args: [String], environment: [String: String]? = nil) -> Never {
    let cArgs = ([path] + args).map { strdup($0) } + [nil]
    if let environment {
        let cEnv = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        execve(path, cArgs, cEnv)
    } else {
        execv(path, cArgs)
    }
    let error = String(cString: strerror(errno))
    FileHandle.standardError.write("turnstile: can't run \(path): \(error)\n")
    exit(126)
}

extension FileHandle {
    func write(_ text: String) {
        write(Data(text.utf8))
    }
}

func warn(_ text: String) {
    FileHandle.standardError.write("turnstile: \(text)\n")
}
