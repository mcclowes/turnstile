import Darwin
import Foundation
@testable import turnstile
@testable import TurnstileCore

/// One end of a socketpair the daemon writes to, as a shim's connection would be.
final class FakeClient {
    let connection: Daemon.Connection
    let peer: Int32
    private var lines = LineBuffer()

    init() {
        var fds: [Int32] = [-1, -1]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        connection = Daemon.Connection(fd: fds[0])
        peer = fds[1]
        _ = fcntl(peer, F_SETFL, fcntl(peer, F_GETFL) | O_NONBLOCK)
    }

    deinit {
        close(connection.fd)
        close(peer)
    }

    /// Everything the daemon sent since the last call.
    func received() -> [Message] {
        var chunk = [UInt8](repeating: 0, count: 65536)
        var messages: [Message] = []
        while true {
            let count = read(peer, &chunk, chunk.count)
            guard count > 0 else { break }
            messages += lines.append(Data(chunk[0..<count])).compactMap(Message.decode)
        }
        return messages
    }

    func types() -> [String] { received().map(\.type) }
}

/// A daemon in a throwaway home, driven through its message handler rather than a socket.
final class DaemonHarness {
    let home: String
    let daemon: Daemon
    private var processes: [Process] = []

    init(config: String = #"{"concurrency": {"compile": 2, "test": 1, "browser": 1}}"#, memoryLevel: Int = 100) throws {
        home = NSTemporaryDirectory() + "turnstile-daemon-" + UUID().uuidString.prefix(8)
        daemon = try Daemon(paths: Paths(home: home), idleExit: 3600)
        daemon.config = try ConfigFile.decode(Data(config.utf8))
        daemon.memoryLevel = memoryLevel
    }

    deinit {
        for process in processes where process.isRunning {
            kill(process.processIdentifier, SIGCONT)
            process.terminate()
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(atPath: home)
    }

    var physical: UInt64 { daemon.physical }

    @discardableResult
    func request(
        _ client: FakeClient, key: String = "swift build", resourceClass: ResourceClass = .compile,
        memory: UInt64? = Bytes.gb, agent: Bool = true, fingerprint: String? = nil, captures: Bool = true,
        root: String = "/repo", home: String? = nil, cwd: String? = nil, argv: [String]? = nil, pid: Int32? = nil, pausable: Bool? = nil,
        maxMemory: UInt64? = nil
    ) -> Int64? {
        var message = Message(type: "request")
        message.key = key
        message.tool = key.split(separator: " ").first.map(String.init)
        message.argv = argv ?? key.split(separator: " ").map(String.init)
        message.resourceClass = resourceClass
        message.memory = memory
        message.agent = agent
        message.fingerprint = fingerprint
        message.captures = captures
        message.interactive = false
        message.root = root
        message.home = home
        message.cwd = cwd ?? root
        message.pid = pid
        message.pausable = pausable
        message.maxMemory = maxMemory
        daemon.handle(message, from: client.connection)
        return client.connection.job
    }

    func started(_ client: FakeClient, childPid: Int32, log: String? = nil) {
        var message = Message(type: "started")
        message.childPid = childPid
        message.log = log
        daemon.handle(message, from: client.connection)
    }

    func finished(_ client: FakeClient, exitCode: Int32? = 0, signal: Int32? = nil) {
        var message = Message(type: "finished")
        message.exitCode = exitCode
        message.signal = signal
        daemon.handle(message, from: client.connection)
    }

    func control(_ action: String, _ target: String) -> Message {
        let client = FakeClient()
        var message = Message(type: action)
        message.target = target
        daemon.handle(message, from: client.connection)
        return client.received().last ?? Message(type: "none")
    }

    func job(_ id: Int64?) -> Daemon.Job? { id.flatMap { daemon.jobs[$0] } }

    /// A real process to stand in for a job's tool, so signals and liveness checks behave.
    func sleeper(_ command: String = "sleep 30; true") throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try process.run()
        processes.append(process)
        usleep(100_000)
        return process
    }

    /// The process state letter from ps, such as "S" or "T" for stopped.
    static func state(_ pid: pid_t) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "state=", "-p", "\(pid)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
